#!/usr/bin/env python3
"""
Build the GitHub Actions build matrix (kernel variant x ISA level)
from config/variants.yml and config/isa-levels.yml.

Every enabled variant is crossed with every ISA level it supports
(respecting each variant's optional `min_isa` floor). The three build
jobs in weekly-build.yml (Arch / Debian / Fedora) all consume the exact
same matrix - packaging format is a job, not a matrix dimension, since
each format needs a genuinely different toolchain (makepkg needs an Arch
container, .deb/.rpm need kbuild's built-in targets on Debian/Fedora
respectively).

This also resolves, PER VARIANT, the exact source tag each folder's live
PKGBUILD is pinned to (variants track different series: lts -> 6.18.x,
hardened -> 7.1.x, rc -> cachyos-X.Y-rcN-R). The tag travels inside each
matrix cell so every packaging path builds that variant's true base.

Usage:
  generate-matrix.py [--variants id,id,...] [--isa v1,v2,...]
                     [--skip-version-resolution] [--version-only]
                     [--force] [--repo owner/repo]

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

    include = []
    skipped_disabled = 0
    # Several variants share a pkgbuild_dir series; resolve each folder's
    # live tag once and cache it (also keeps API calls bounded).
    tag_cache: dict[str, str] = {}
    # variant id -> resolved src_tag, for the freshness gate below.
    variant_tags: dict[str, str] = {}

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

        floor = RANK[variant.get("min_isa", "v1")]

        for isa in isa_cfg["levels"]:
            if wanted_isa and isa["id"] not in wanted_isa:
                continue
            if RANK[isa["id"]] < floor:
                continue

            include.append({
                "variant": variant["id"],
                "pkgbuild_dir": pbd,
                "scheduler": variant["scheduler"],
                # Space-separated so workflows can pass it as a single
                # env var straight into the patch applier.
                "patches": " ".join(variant.get("patches", [])),
                "cachy_config": "yes" if variant.get("cachy_config", True) else "no",
                "preempt": variant.get("preempt", "full"),
                "src_tag": src_tag,
                "isa": isa["id"],
                "isa_num": isa["isa_num"],
                "march": isa["march"],
                "pkg_suffix": isa["pkg_suffix"],
            })

    matrix = {"include": include}

    print(
        f"[generate-matrix] {len(include)} build cells "
        f"({len(variants_cfg['variants']) - skipped_disabled} variants enabled, "
        f"{skipped_disabled} disabled in config). This many cells will be built "
        f"by EACH of the two build jobs (build-arch, build-kbuild).",
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

    lines = [
        f"matrix={json.dumps(matrix)}\n",
        f"kernel_version={kernel_version}\n",
        f"src_tag={src_tag}\n",
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
