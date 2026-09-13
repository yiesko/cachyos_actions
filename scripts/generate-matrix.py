#!/usr/bin/env python3
"""
Build the GitHub Actions build matrix (kernel variant x ISA level)
from config/variants.yml and config/isa-levels.yml.

Every enabled variant is crossed with every ISA level it supports
(respecting each variant's optional `min_isa` floor). The Arch job and
the kbuild job consume DIFFERENT matrices from the same cells: Arch
builds each cell once (makepkg pins LTO per PKGBUILD, no per-cell
override possible), while kbuild additionally gets ThinLTO+FullLTO
duplicate cells for --lto-variants (default: the 6 desktop variants:
cachyos, bore, eevdf, rt-bore, deckify, rc), each with a
name suffix so packages never collide (`-thin` / `-full`).

This also resolves, PER VARIANT, the exact source tag each folder's live
PKGBUILD is pinned to (variants track different series: lts -> 6.18.x,
hardened -> 7.1.x, rc -> cachyos-X.Y-rcN-R). The tag travels inside each
matrix cell so every packaging path builds that variant's true base.

Usage:
  generate-matrix.py [--variants id,id,...] [--isa v1,v2,...]
                     [--skip-version-resolution] [--version-only]
                     [--force] [--repo owner/repo]
                     [--lto-variants id,id,...] [--build-lto]

Writes `matrix={...}`, `kernel_version=<x.y.z>` and `src_tag=<cachyos-tag>`
to $GITHUB_OUTPUT (or stdout, for local testing).

Freshness gate: after resolving every enabled variant's live source tag,
the script fetches versions.json from the repo's latest stable release
and compares. Outputs `changed=true/false` (+ `changed_variants`,
`prev_release`) so the workflow can skip the ~13h matrix when upstream
did not move. The lookup is best-effort and fails OPEN (builds) — a
missing manifest, a new variant, or any network error means changed.
`--force` bypasses the comparison (manual rebuilds).
"""
import argparse
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

import yaml  # PyYAML - installed by the workflow step before this runs

ROOT = Path(__file__).resolve().parent.parent
RANK = {"v1": 0, "v2": 1, "v3": 2, "v4": 3}

PKGBUILD_URL = (
    "https://raw.githubusercontent.com/CachyOS/linux-cachyos/"
    "master/linux-cachyos-bore/PKGBUILD"
)


def load(name):
    with open(ROOT / "config" / name) as f:
        return yaml.safe_load(f)


def pkgbuild_url(pkgbuild_dir: str) -> str:
    return (
        "https://raw.githubusercontent.com/CachyOS/linux-cachyos/"
        f"master/{pkgbuild_dir}/PKGBUILD"
    )


def resolve_kernel_version(pkgbuild_dir: str = "linux-cachyos-bore") -> tuple[str, str]:
    """Return (kernel_version, src_tag) parsed from a variant's live PKGBUILD.

    Verified naming schemes (Aug 2026):
      stable: _srcname="cachyos-${_major}.${_minor}-${_tagrel}"  -> cachyos-7.2.0-1
      rc:     _srctag ="cachyos-${_major}-${_rcver}-${_tagrel}"   -> cachyos-7.2-rc7-1

    Some variants deliberately track different series (linux-cachyos-lts
    -> 6.18.x, linux-cachyos-hardened -> 7.1.x), so every variant must
    resolve its OWN tag instead of inheriting the flagship's.
    """
    with urllib.request.urlopen(pkgbuild_url(pkgbuild_dir), timeout=30) as resp:
        text = resp.read().decode("utf-8", errors="replace")

    def grab(var, allow_dots=True):
        # Anchored at line start so commented-out lines (#_foo=...) are
        # ignored - the rc PKGBUILD carries several of those.
        pattern = r"^_" + var + r"=([0-9.]+)\s*$" if allow_dots else rf"^_{var}=(\S+)\s*$"
        m = re.search(pattern, text, re.MULTILINE)
        if not m:
            raise ValueError(f"could not parse _{var} from {pkgbuild_url(pkgbuild_dir)}")
        return m.group(1)

    major = grab("major")          # e.g. "7.2" (or "6.18"/"7.1" on lts/hardened)
    tagrel = grab("tagrel")        # e.g. "1"

    m_rc = re.search(r"^_rcver=(\S+)\s*$", text, re.MULTILINE)
    if m_rc:
        rcver = m_rc.group(1)      # e.g. "rc7"
        return f"{major}.{rcver}", f"cachyos-{major}-{rcver}-{tagrel}"

    minor = grab("minor")          # e.g. "0" (".42" on lts)
    return f"{major}.{minor}", f"cachyos-{major}.{minor}-{tagrel}"


def major_minor_of_tag(tag: str) -> str:
    """Derive the kernel-patches series (major.minor) from a source tag.

    Handles stable (cachyos-7.2.0-1 -> 7.2) and RC (cachyos-7.2-rc7-1 -> 7.2).
    Returns "" when the tag shape is unrecognized.
    """
    base = (tag or "").removeprefix("cachyos-")
    base = base.split("-")[0] if "-" in base else base  # 7.2.0 / 7.2
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", base):
        return base.rsplit(".", 1)[0]
    if re.fullmatch(r"[0-9]+\.[0-9]+", base):
        return base
    return ""


def gh_api_get_json(url: str, timeout: int = 15):
    """GET a GitHub API URL, returning parsed JSON or None on ANY failure.

    Uses GITHUB_TOKEN/GT_TOKEN when present (raises the rate limit from
    60 to 5000 req/h); unauthenticated runners share the small quota, so
    every caller must treat None as "unknown", never fatal.
    """
    try:
        headers = {"User-Agent": "cachyos-matrix-script",
                   "Accept": "application/vnd.github+json"}
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except Exception:  # noqa: BLE001 - best effort by design
        return None


def resolve_provenance(pkgbuild_dir: str, src_tag: str) -> dict:
    """Best-effort upstream commit SHAs for one variant's sources.

    Never raises: any lookup failure yields "unknown" for that field so a
    flaky API or rate limit degrades provenance detail without failing
    the build. Fields:
      pkgbuild_sha   commit that last touched <dir>/PKGBUILD (or HEAD)
      linux_commit   commit the CachyOS/linux <src_tag> points at
      patches_sha    HEAD of cachyos/kernel-patches for the tag's series
    plus the browsable URLs needed to verify each one.
    """
    prov = {
        "pkgbuild_dir": pkgbuild_dir,
        "pkgbuild_sha": "unknown",
        "pkgbuild_url": (f"https://github.com/CachyOS/linux-cachyos/tree/master/{pkgbuild_dir}"),
        "src_tag": src_tag,
        "linux_commit": "unknown",
        "linux_release_url": (f"https://github.com/CachyOS/linux/releases/tag/{src_tag}" if src_tag else ""),
        "series": major_minor_of_tag(src_tag),
        "patches_sha": "unknown",
        "patches_url": "",
    }
    if prov["series"]:
        prov["patches_url"] = (f"https://github.com/cachyos/kernel-patches/tree/master/{prov['series']}")
    if not src_tag:
        return prov  # offline mode: URLs only

    commits = gh_api_get_json(
        f"https://api.github.com/repos/CachyOS/linux-cachyos/commits"
        f"?path={pkgbuild_dir}/PKGBUILD&per_page=1&sha=master")
    if isinstance(commits, list) and commits and isinstance(commits[0], dict):
        prov["pkgbuild_sha"] = commits[0].get("sha", "unknown") or "unknown"
    if prov["pkgbuild_sha"] == "unknown":
        head = gh_api_get_json("https://api.github.com/repos/CachyOS/linux-cachyos/commits/master")
        if isinstance(head, dict) and head.get("sha"):
            prov["pkgbuild_sha"] = head["sha"]

    ref = gh_api_get_json(f"https://api.github.com/repos/CachyOS/linux/git/ref/tags/{src_tag}")
    if isinstance(ref, dict) and isinstance(ref.get("object"), dict):
        obj = ref["object"]
        if obj.get("type") == "tag" and obj.get("sha"):
            tag_obj = gh_api_get_json(
                f"https://api.github.com/repos/CachyOS/linux/git/tags/{obj['sha']}")
            if isinstance(tag_obj, dict) and isinstance(tag_obj.get("object"), dict):
                prov["linux_commit"] = tag_obj["object"].get("sha", "unknown") or "unknown"
            else:
                prov["linux_commit"] = obj["sha"]
        elif obj.get("sha"):
            prov["linux_commit"] = obj["sha"]

    if prov["series"]:
        pcommits = gh_api_get_json(
            f"https://api.github.com/repos/cachyos/kernel-patches/commits"
            f"?path={prov['series']}&per_page=1&sha=master")
        if isinstance(pcommits, list) and pcommits and isinstance(pcommits[0], dict):
            prov["patches_sha"] = pcommits[0].get("sha", "unknown") or "unknown"
    return prov


def fetch_last_manifest(repo: str) -> tuple[str, dict | None]:
    """Fetch versions.json from the repo's latest stable release.

    Returns (release_tag, manifest) or (None, None)/(tag, None) on ANY
    failure — the freshness check is best-effort and fails OPEN (build).
    No auth needed: public repo reads allow 60 req/h unauthenticated,
    and this costs exactly 2 calls when a manifest exists.
    """
    if not repo or "/" not in repo:
        return None, None
    try:
        url = f"https://api.github.com/repos/{repo}/releases/latest"
        req = urllib.request.Request(url, headers={"User-Agent": "cachyos-matrix-script",
                                                   "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            rel = json.load(resp)
        tag = (rel.get("tag_name") or "").strip()
        asset_url = ""
        for asset in rel.get("assets", []):
            if asset.get("name") == "versions.json":
                asset_url = asset.get("browser_download_url", "")
                break
        if not asset_url:
            return tag or None, None
        areq = urllib.request.Request(asset_url, headers={"User-Agent": "cachyos-matrix-script"})
        with urllib.request.urlopen(areq, timeout=30) as aresp:
            manifest = json.load(aresp)
        if not isinstance(manifest, dict) or not isinstance(manifest.get("variants"), dict):
            return tag or None, None
        return tag or None, manifest
    except Exception:  # noqa: BLE001 - best effort by design, fail open
        return None, None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--variants", default="",
                        help="comma-separated variant ids; blank = all enabled")
    parser.add_argument("--isa", default="",
                        help="comma-separated ISA ids (v1,v2,v3,v4); blank = all")
    parser.add_argument("--skip-version-resolution", action="store_true",
                        help="don't hit CachyOS's live PKGBUILD (offline testing)")
    parser.add_argument("--version-only", action="store_true",
                        help="only resolve kernel_version/src_tag, skip matrix")
    parser.add_argument("--force", action="store_true",
                        help="bypass the freshness gate (rebuild even if unchanged)")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""),
                        help="owner/repo for the last-release manifest lookup")
    parser.add_argument("--lto-variants",
                        default="cachyos,cachyos-bore,cachyos-eevdf,cachyos-rt-bore,cachyos-deckify,cachyos-rc",
                        help="comma-separated variant ids gaining extra ThinLTO+Full "
                             "kbuild cells (Arch excluded: makepkg pins LTO per PKGBUILD)")
    parser.add_argument("--build-lto", action="store_true",
                        help="whole-run ThinLTO for kbuild cells (legacy input mode; "
                             "disables the per-variant LTO duplicates)")
    parser.add_argument("--skip-provenance", action="store_true",
                        help="don't query upstream commit SHAs (offline testing or "
                             "tight API quota; provenance fields become 'unknown')")
    args = parser.parse_args()

    if args.version_only:
        try:
            kernel_version, src_tag = resolve_kernel_version()
        except Exception as exc:  # noqa: BLE001 - fail loudly, CI must stop here
            print(f"[generate-matrix] ERROR resolving kernel version "
                  f"from {PKGBUILD_URL}: {exc}", file=sys.stderr)
            sys.exit(1)
        gh_output = os.environ.get("GITHUB_OUTPUT")
        lines = [
            f"kernel_version={kernel_version}\n",
            f"src_tag={src_tag}\n",
        ]
        if gh_output:
            with open(gh_output, "a") as f:
                f.writelines(lines)
        else:
            sys.stdout.writelines(lines)
        print(f"[generate-matrix] CachyOS is currently building kernel "
              f"{kernel_version} (source tag: {src_tag}).", file=sys.stderr)
        return

    variants_cfg = load("variants.yml")
    isa_cfg = load("isa-levels.yml")

    wanted_variants = {v for v in args.variants.split(",") if v}
    wanted_isa = {i for i in args.isa.split(",") if i}
    lto_wanted = {v for v in args.lto_variants.split(",") if v}

    include = []
    skipped_disabled = 0
    # Several variants share a pkgbuild_dir series; resolve each folder's
    # live tag once and cache it (also keeps API calls bounded).
    tag_cache: dict[str, str] = {}
    # variant id -> resolved src_tag, for the freshness gate below.
    variant_tags: dict[str, str] = {}
    # pkgbuild_dir -> best-effort upstream SHAs (see resolve_provenance).
    prov_cache: dict[str, dict] = {}

    for variant in variants_cfg["variants"]:
        if not variant.get("enabled", False):
            skipped_disabled += 1
            continue
        if wanted_variants and variant["id"] not in wanted_variants:
            continue

        pbd = variant["pkgbuild_dir"]
        if not args.skip_version_resolution:
            if pbd not in tag_cache:
                try:
                    _, src_tag = resolve_kernel_version(pbd)
                except Exception as exc:  # noqa: BLE001 - fail loudly
                    print(f"[generate-matrix] ERROR resolving source tag "
                          f"for {pbd}: {exc}", file=sys.stderr)
                    sys.exit(1)
                tag_cache[pbd] = src_tag
            src_tag = tag_cache[pbd]
        else:
            src_tag = ""
        variant_tags[variant["id"]] = src_tag

        if args.skip_version_resolution or args.skip_provenance:
            prov = resolve_provenance(pbd, "")
            prov["src_tag"] = src_tag
        else:
            if pbd not in prov_cache:
                prov_cache[pbd] = resolve_provenance(pbd, src_tag)
            prov = prov_cache[pbd]

        floor = RANK[variant.get("min_isa", "v1")]

        for isa in isa_cfg["levels"]:
            if wanted_isa and isa["id"] not in wanted_isa:
                continue
            if RANK[isa["id"]] < floor:
                continue

            # lto selects the kbuild toolchain (USE_LTO); suffix keeps
            # every artifact/status filename unique per flavor. Base cells
            # follow --build-lto (legacy whole-run mode); otherwise the
            # --lto-variants gain extra thin+full kbuild duplicates.
            base_lto = "thin" if args.build_lto else "none"
            include.append({
                "variant": variant["id"],
                "pkgbuild_dir": pbd,
                "scheduler": variant["scheduler"],
                # Space-separated so workflows can pass it as a single
                # env var straight into the patch applier.
                "patches": " ".join(variant.get("patches", [])),
                "cachy_config": "yes" if variant.get("cachy_config", True) else "no",
                "preempt": variant.get("preempt", "full"),
                "hz": variant.get("hz", 1000),
                "lto": base_lto,
                "suffix": "" if base_lto == "none" else f"-{base_lto}",
                "src_tag": src_tag,
                "pkgbuild_sha": prov.get("pkgbuild_sha", "unknown"),
                "linux_commit": prov.get("linux_commit", "unknown"),
                "patches_sha": prov.get("patches_sha", "unknown"),
                "isa": isa["id"],
                "isa_num": isa["isa_num"],
                "march": isa["march"],
                "pkg_suffix": isa["pkg_suffix"],
            })
            if (not args.build_lto and variant["id"] in lto_wanted):
                for flavor in ("thin", "full"):
                    dup = dict(include[-1])
                    dup.update({"lto": flavor, "suffix": f"-{flavor}",
                                "lto_dup": True})
                    include.append(dup)

    unknown_lto = lto_wanted - {v["id"] for v in variants_cfg["variants"]}
    if unknown_lto:
        print(f"[generate-matrix] WARNING: --lto-variants ids not found in "
              f"config/variants.yml (ignored): {sorted(unknown_lto)}",
              file=sys.stderr)

    # Arch cannot take per-cell LTO (makepkg pins it per PKGBUILD), so it
    # consumes only base cells; kbuild consumes everything.
    arch_cells = [c for c in include if not c.get("lto_dup")]
    matrix_arch = {"include": arch_cells}
    matrix_kbuild = {"include": include}

    print(
        f"[generate-matrix] {len(arch_cells)} Arch cells + {len(include)} kbuild cells "
        f"({len(variants_cfg['variants']) - skipped_disabled} variants enabled, "
        f"{skipped_disabled} disabled in config; "
        f"LTO duplicates: {len(include) - len(arch_cells)}).",
        file=sys.stderr,
    )

    if not include:
        print("[generate-matrix] ERROR: matrix is empty - check your "
              "--variants/--isa filters and config/variants.yml `enabled` flags.",
              file=sys.stderr)
        sys.exit(1)

    if args.skip_version_resolution:
        kernel_version = ""
        src_tag = ""
        print("[generate-matrix] Skipping live kernel-version resolution "
              "(--skip-version-resolution).", file=sys.stderr)
    else:
        try:
            kernel_version, src_tag = resolve_kernel_version()
            print(f"[generate-matrix] CachyOS is currently building "
                  f"kernel {kernel_version} (source tag: {src_tag}).",
                  file=sys.stderr)
        except Exception as exc:  # noqa: BLE001 - fail loudly, CI must stop here
            print(f"[generate-matrix] ERROR resolving kernel version "
                  f"from {PKGBUILD_URL}: {exc}", file=sys.stderr)
            print("[generate-matrix] The deb/rpm jobs need the source tag to "
                  "fetch the tarball; fix connectivity or pass an explicit tag.",
                  file=sys.stderr)
            sys.exit(1)

    # --- freshness gate: skip the ~13h matrix when upstream did not move.
    # Compares the just-resolved tags against versions.json from the latest
    # stable release. New variants (absent from the manifest) count as
    # changed; disabled ones are ignored. Fails OPEN (build) on any doubt.
    changed = True
    changed_ids: list[str] = sorted(variant_tags)
    prev_release = ""
    if args.force:
        reason = "forced rebuild (--force)"
    elif args.skip_version_resolution:
        reason = "version resolution skipped (offline mode)"
    else:
        prev_release, manifest = fetch_last_manifest(args.repo)
        prev_release = prev_release or ""
        if manifest is None:
            if prev_release:
                reason = f"no versions.json asset in last release ({prev_release})"
            else:
                reason = "could not read last release manifest"
        else:
            prev_vars = manifest.get("variants", {})
            diffs = [vid for vid, tag in sorted(variant_tags.items())
                     if prev_vars.get(vid) != tag]
            if diffs:
                changed_ids = diffs
                moves = ", ".join(f"{vid} {prev_vars.get(vid, '?')}->{variant_tags[vid]}"
                                  for vid in diffs)
                reason = f"upstream moved: {moves}"
            else:
                changed = False
                changed_ids = []
                reason = (f"all {len(variant_tags)} variant(s) unchanged "
                          f"since {prev_release}")
    print(f"[generate-matrix] freshness: changed={changed} ({reason}).",
          file=sys.stderr)
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a") as f:
            if changed:
                f.write(f"### Freshness gate: BUILD\n\n{reason}\n")
            else:
                f.write(f"### Freshness gate: SKIP\n\nNo upstream changes "
                        f"({reason}) — build jobs will skip.\n")

    # Distinct upstream bases in this release, config order (flagship
    # first): e.g. "7.2.4, 6.18.50, 7.1.8, 7.3-rc2". Release titles carry
    # every series instead of only the flagship's, so LTS/Hardened/RC
    # users see theirs at a glance (the per-variant table has the rest).
    # A lagging folder (deckify on 7.2.3 while others are 7.2.4) shows up
    # as its own entry until upstream bumps it — truthful by construction.
    series: list[str] = []
    for _vid, _tag in variant_tags.items():
        _m = re.match(r"^cachyos-(.+)-(\d+)$", _tag or "")
        _base = _m.group(1) if _m else ""
        if _base and _base not in series:
            series.append(_base)
    series_str = ", ".join(series) if series else kernel_version

    # Per-variant upstream provenance (tag -> commit SHAs + browsable URLs)
    # for the release manifest. Keyed by variant id; duplicates (two cells
    # of one variant) collapse to a single entry.
    provenance_map: dict[str, dict] = {}
    for variant in variants_cfg["variants"]:
        if not variant.get("enabled", False):
            continue
        if wanted_variants and variant["id"] not in wanted_variants:
            continue
        if variant["id"] in provenance_map:
            continue
        tag = variant_tags.get(variant["id"], "")
        if args.skip_version_resolution or args.skip_provenance:
            prov = resolve_provenance(variant["pkgbuild_dir"], "")
            prov["src_tag"] = tag
        else:
            prov = prov_cache.get(variant["pkgbuild_dir"]) or resolve_provenance(
                variant["pkgbuild_dir"], tag)
        prov = dict(prov)
        prov["variant"] = variant["id"]
        prov["scheduler"] = variant.get("scheduler", "")
        prov["patches"] = list(variant.get("patches", []))
        provenance_map[variant["id"]] = prov

    lines = [
        f"matrix_arch={json.dumps(matrix_arch)}\n",
        f"matrix_kbuild={json.dumps(matrix_kbuild)}\n",
        f"provenance_map={json.dumps(provenance_map)}\n",
        f"kernel_version={kernel_version}\n",
        f"src_tag={src_tag}\n",
        f"series={series_str}\n",
        f"changed={'true' if changed else 'false'}\n",
        f"changed_variants={json.dumps(changed_ids)}\n",
        f"prev_release={prev_release}\n",
    ]
    gh_output = os.environ.get("GITHUB_OUTPUT")
    if gh_output:
        with open(gh_output, "a") as f:
            f.writelines(lines)
    else:
        sys.stdout.writelines(lines)


if __name__ == "__main__":
    main()
