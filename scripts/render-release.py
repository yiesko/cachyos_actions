#!/usr/bin/env python3
"""Render release provenance manifest + notes from cell fragments.

Merges per-cell provenance fragments (scripts/collect-cell-provenance.sh),
matrix/resolve outputs and workflow run context into:
  <out>/provenance.json   machine-readable manifest (published as asset)
  <notes>                 full release-notes.md (published as release body)

Also appends provenance.json's own hashes to <out>/SHA256SUMS+MD5SUMS when
those files already exist (the release jobs generate checksums first).

Never fails hard on missing fragments: unknown cells render as "unknown"
so a lost fragment degrades detail without blocking the release.

Usage (called from weekly-build.yml / custom-kernel.yml release jobs):
  render-release.py --mode weekly --cells cells --out out --notes release-notes.md ...
  render-release.py --mode custom --cells cells --out cells --notes release-notes.md ...
"""
import argparse
import glob
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

GPG_KEYS = [
    ("E18447AC260021D31F3FF6C4C8A2A4774B8B63C4", "Eric Naim <dnaim@cachyos.org>"),
    ("E8B9AA39F054E30E8290D492C3C4820857F654FE", "Peter Jung <admin@ptr1337.dev>"),
]
TARBALL_BASE = "https://github.com/CachyOS/linux/releases/download"


def short(sha, n=12):
    if not sha or sha == "unknown":
        return "unknown"
    return sha[:n]


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def load_fragments(cells):
    frags = []
    seen = set()
    # Recursive: depending on upload/download layout, fragments may sit at
    # the top level or nested under per-artifact directories.
    for pat in ("provenance-*.json", os.path.join("**", "provenance-*.json")):
        for path in sorted(glob.glob(os.path.join(cells, pat), recursive=True)):
            if path in seen:
                continue
            seen.add(path)
            try:
                with open(path) as f:
                    doc = json.load(f)
                if isinstance(doc, dict):
                    doc["_fragment_file"] = os.path.basename(path)
                    frags.append(doc)
            except (OSError, ValueError):
                continue
    return frags


def load_statuses(cells):
    statuses = {}
    for pat in ("*-arch.txt", "*-kbuild*.txt",
                os.path.join("**", "*-arch.txt"),
                os.path.join("**", "*-kbuild*.txt")):
        for path in sorted(glob.glob(os.path.join(cells, pat), recursive=True)):
            try:
                with open(path) as f:
                    statuses[os.path.basename(path)] = f.read().strip()
            except OSError:
                continue
    return statuses


def scan_artifacts(outdir):
    arts = []
    for pat in ("*.rpm", "*.deb", "*.pkg.tar.zst"):
        for path in sorted(glob.glob(os.path.join(outdir, pat))):
            try:
                arts.append({
                    "file": os.path.basename(path),
                    "sha256": sha256_of(path),
                    "size": os.path.getsize(path),
                })
            except OSError:
                continue
    return arts


def append_sums(outdir, filename):
    """Append filename's hashes to SHA256SUMS/MD5SUMS when they exist."""
    import hashlib as hl
    prov_path = os.path.join(outdir, filename)
    try:
        with open(prov_path, "rb") as f:
            digest = f.read()
        s256 = hl.sha256(digest).hexdigest()
        m5 = hl.md5(digest).hexdigest()
    except OSError:
        return
    for sums, val in (("SHA256SUMS", s256), ("MD5SUMS", m5)):
        p = os.path.join(outdir, sums)
        if not os.path.isfile(p):
            continue
        try:
            with open(p) as f:
                content = f.read()
            if filename in content:
                continue
            with open(p, "a") as f:
                f.write(f"{val}  ./{filename}\n")
        except OSError:
            continue


def gpg_key_lines():
    return "; ".join(f"{kid} ({uid})" for kid, uid in GPG_KEYS)


def render_weekly(a, frags, statuses, artifacts):
    matrix = json.loads(a.matrix or '{"include":[]}')
    pmap = json.loads(a.provenance_map or '{}')
    include = matrix.get("include", [])
    sha7 = (a.sha or "")[:7]
    run_url = f"https://github.com/{a.repo}/actions/runs/{a.run_id}"
    lines = []
    lines.append(f"## CachyOS kernels {a.series} — weekly-{a.run_number}")
    lines.append("")
    lines.append("Automated CachyOS kernel builds, tracked live from upstream PKGBUILDs (nothing vendored) — Arch, Debian/Ubuntu and Fedora packages for x86-64 v1–v4.")
    lines.append("")
    lines.append(f"Built from commit `{sha7}` ([run #{a.run_number}]({run_url})). Full source provenance (tags, commits, GPG, patches, configs, toolchain) is in `provenance.json` in this release — the tables below summarize it.")
    lines.append("")
    lines.append("### Download")
    lines.append("")
    lines.append("**1. Pick your ISA level** — check yours with `/lib64/ld-linux-x86-64.so.2 --help | grep supported`, or match your CPU below:")
    lines.append("")
    lines.append("| ISA | Intel examples | AMD examples | File infix |")
    lines.append("|---|---|---|---|")
    lines.append("| v1 | Core 2 Duo/Quad, 1st-gen Atom 64-bit | Athlon 64 X2, Turion 64 | `-v1` (Arch v1 has no suffix) — runs everywhere |")
    lines.append("| v2 | Core i3/i5/i7 1st–3rd gen, e.g. i7-920 (Nehalem), i7-2600K (Sandy Bridge), i7-3770 (Ivy Bridge) | FX-8350 (Piledriver), A10 APUs — pre-Ryzen | `-v2` — no official CachyOS tier, exclusive to CI like this |")
    lines.append("| v3 | Core iX 4th gen and newer, e.g. i7-4770K (Haswell) through i9-14900K — incl. 12th+ gen (no AVX-512 there) | Ryzen 1000–5000 (Zen–Zen 3), e.g. Ryzen 5 3600 / 5600X | `-v3` — CachyOS's recommended default, fits most PCs |")
    lines.append("| v4 | Xeon Scalable / Ice Lake-SP, i9-11900K (Rocket Lake); most consumer Intel does NOT qualify | Ryzen 7000+ (Zen 4+), e.g. Ryzen 5 7600X, EPYC Genoa | `-v4` — AVX-512 only |")
    lines.append("")
    lines.append("When in doubt, pick the **lower** level: a v2 kernel boots on a v3 CPU (just less optimized), but a v4 kernel will fault on a CPU without AVX-512.")
    lines.append("")
    lines.append("**2. Pick your variant** (scheduler, exact upstream base and source commit built in this release):")
    lines.append("")
    lines.append("| Variant | Scheduler | Base | Source commit | PKGBUILD commit |")
    lines.append("|---|---|---|---|---|")
    seen = []
    for cell in include:
        v = cell.get("variant")
        if v in seen:
            continue
        seen.append(v)
        prov = pmap.get(v, {})
        tag = cell.get("src_tag", "")
        lcommit = prov.get("linux_commit", cell.get("linux_commit", "unknown"))
        psha = prov.get("pkgbuild_sha", cell.get("pkgbuild_sha", "unknown"))
        lines.append(f"| {v} | {cell.get('scheduler','')} | {tag} | {short(lcommit)} | {short(psha)} |")
    lines.append("")
    lines.append("**3. Install** (keep your stock kernel as a fallback boot entry):")
    lines.append("")
    lines.append("- **Fedora:** `sudo dnf install ./kernel-*-<isa>.rpm` (kernel + devel + headers)")
    lines.append("- **Debian/Ubuntu:** `sudo dpkg -i ./linux-image-*.deb ./linux-headers-*.deb`")
    lines.append("- **Arch:** `sudo pacman -U ./linux-cachyos-*.pkg.tar.zst`")
    lines.append("- No clone needed — or automate it: `contrib/fetch-kernel.sh` in this repo.")
    lines.append("")
    lines.append("### Build matrix")
    lines.append("")
    lines.append("Flavor `gcc` = default compiler, `thin`/`full` = Clang LTO extras (kbuild only — Arch ships each PKGBUILD's authentic default, flagship/rc ThinLTO).")
    lines.append("")
    lines.append("| Variant | ISA | Flavor | Arch | Kbuild (.deb/.rpm) |")
    lines.append("|---|---|---|---|---|")
    for cell in include:
        v, isa, lto, suf = cell.get("variant"), cell.get("isa"), cell.get("lto", "none"), cell.get("suffix", "")
        flavor = "gcc" if lto == "none" else lto
        if lto == "none":
            s = statuses.get(f"{v}-{isa}-arch.txt", "")
            archcell = " :white_check_mark: |" if s == "ok" else (f" :x: (`{s[5:]}`) |" if s.startswith("fail:") else " :grey_question: |")
        else:
            archcell = " — |"
        s = statuses.get(f"{v}-{isa}-kbuild{suf}.txt", "")
        kcell = " :white_check_mark: |" if s == "ok" else (f" :x: (`{s[5:]}`) |" if s.startswith("fail:") else " :grey_question: |")
        lines.append(f"| {v} | {isa} | {flavor} |{archcell}{kcell}")
    lines.append("")
    lines.append("### Provenance (veracity · trust · origin)")
    lines.append("")
    lines.append(f"- Pipeline: `{a.repo}` workflow `{a.workflow}` commit `{a.sha}` ([run #{a.run_number}]({run_url})).")
    lines.append(f"- Upstream `CachyOS/linux-cachyos` (PKGBUILDs + base configs) and `CachyOS/linux` (source tarballs) — per-variant commits in the table above and in full in `provenance.json` (`upstream.pkgbuild_sha`, `upstream.linux_commit`).")
    lines.append(f"- Source tarballs: `{TARBALL_BASE}/<tag>/<tag>.tar.gz` + `.asc`, GPG-verified at build time against CachyOS's published keys ({gpg_key_lines()}); per-cell outcome in `provenance.json` (`source.gpg_verify`, strict mode aborts the cell on failure).")
    lines.append("- Scheduler patches: fetched per variant from `cachyos/kernel-patches` at build time (exact paths + SHA256 in `provenance.json` → `patches[]`); served over TLS, not GPG-signed upstream.")
    lines.append("- Kernel configs: per-variant upstream `config` file plus the prepare() toggles (scheduler, ISA via `_processor_opt`, HZ, preempt, LTO); base/final `.config` SHA256 and `kernelrelease` per cell in `provenance.json`.")
    lines.append("- Toolchains and runner (gcc/clang/rustc/bindgen, container digest, timestamps) per cell in `provenance.json`.")
    lines.append("- Arch path honesty: Arch cells run `makepkg --skippgpcheck` against the upstream PKGBUILD (recorded `upstream_head`); the GPG tarball guarantee applies to the kbuild (`.deb`/`.rpm`) path.")
    lines.append("")
    lines.append("### Integrity")
    lines.append("")
    lines.append("- `SHA256SUMS` + `MD5SUMS` cover every asset in this release (including `provenance.json` and `versions.json`):")
    lines.append("  `sha256sum -c SHA256SUMS --ignore-missing` (missing = not downloaded, not corrupt).")
    lines.append("  `md5sum -c MD5SUMS --ignore-missing`")
    lines.append("- `versions.json` records the exact upstream source tag built per variant — it feeds the CI freshness gate, so weeks without upstream changes publish nothing.")
    lines.append("- `provenance.json` records tags AND immutable commit SHAs, tarball hashes, patch hashes, config hashes and toolchain versions — verify any claim in this text against it.")
    lines.append("")
    lines.append("### Notes")
    lines.append("")
    lines.append("- Variants disabled in this cycle are documented in the README (not built, not listed above).")
    lines.append("- Kernels/modules ship **unsigned**; Secure Boot users must sign them")
    lines.append("  and enroll their own key (see README + `contrib/sign-kernel-mok.sh`).")
    lines.append("- Install at your own risk; keep a stock kernel as a fallback boot entry.")
    lines.append("")
    return "\n".join(lines)


def render_custom(a, frags, statuses, artifacts, resolve, inputs):
    sha7 = (a.sha or "")[:7]
    run_url = f"https://github.com/{a.repo}/actions/runs/{a.run_id}"
    frag = frags[0] if frags else {}
    src = frag.get("source", {}) if isinstance(frag, dict) else {}
    cfg = frag.get("config", {}) if isinstance(frag, dict) else {}
    ups = frag.get("upstream", {}) if isinstance(frag, dict) else {}
    tool = frag.get("toolchain", {}) if isinstance(frag, dict) else {}
    patches = frag.get("patches", []) if isinstance(frag, dict) else []
    rp = resolve or {}
    ri = inputs or {}
    tag = rp.get("src_tag", a.kernel_version) or a.kernel_version
    lines = []
    lines.append(f"## Custom CachyOS kernel {tag}")
    lines.append("")
    lines.append(f"Manual build from commit `{sha7}` ([run #{a.run_number}]({run_url})). Full source provenance is in `provenance.json` in this release.")
    lines.append("")
    lines.append("| Field | Value |")
    lines.append("|---|---|")
    lines.append(f"| Variant | `{ri.get('variant', rp.get('variant',''))}` (`{rp.get('pkgbuild_dir','')}`, scheduler `{rp.get('scheduler','')}`) |")
    lines.append(f"| Tuning | `{rp.get('tuning_id', ri.get('cpu_tuning',''))}` (`-march={rp.get('march','')}`, Kconfig `{rp.get('kconfig_mode','')}` v{rp.get('isa_num','')}, base `{rp.get('base_isa','')}`) |")
    lines.append(f"| Label | `{rp.get('isa_label','')}` (`uname -r` suffix `{rp.get('localversion','')}`) |")
    lines.append(f"| LTO | `{ri.get('lto', rp.get('lto',''))}` |")
    lines.append(f"| Package format | `{rp.get('pkg_format', ri.get('pkg_format',''))}` |")
    lines.append(f"| Preempt / HZ / Cachy | `{rp.get('preempt','')}` / `{rp.get('hz','')}` / `{rp.get('cachy_config','')}` |")
    lines.append(f"| Source | `{tag}` (GPG-verified, key IDs below) |")
    lines.append(f"| Source commit | `{short(rp.get('linux_commit', ups.get('linux_commit','unknown')))}` ([release](https://github.com/CachyOS/linux/releases/tag/{tag})) |")
    lines.append(f"| PKGBUILD commit | `{short(rp.get('pkgbuild_sha', ups.get('pkgbuild_sha','unknown')))}` ([folder](https://github.com/CachyOS/linux-cachyos/tree/master/{rp.get('pkgbuild_dir','')})) |")
    lines.append(f"| Patches HEAD | `{short(rp.get('patches_sha', ups.get('patches_sha','unknown')))}` |")
    lines.append(f"| Tarball | `{short(src.get('tarball_sha256','unknown'),16)}` ({src.get('tarball_size','unknown')} bytes, verify `{src.get('gpg_verify','unknown')}`) |")
    lines.append(f"| Kernel release | `{cfg.get('kernelrelease','unknown')}` |")
    lines.append(f"| Toolchain | `{tool.get('gcc','unknown')}` / `{tool.get('clang','unknown')}` / `{tool.get('rustc','unknown')}` |")
    lines.append("")
    if patches:
        lines.append("Patches applied (`path — sha256`):")
        lines.append("")
        for p in patches:
            lines.append(f"- `{p.get('path','')}` — `{short(p.get('sha256','unknown'),16)}` ({p.get('result','')})")
        lines.append("")
    lines.append("GPG source keys (CachyOS published, as declared in the upstream PKGBUILD `validpgpkeys`):")
    lines.append("")
    for kid, uid in GPG_KEYS:
        lines.append(f"- `{kid}` ({uid})")
    lines.append("")
    lines.append("Verify: `sha256sum -c SHA256SUMS --ignore-missing`.")
    lines.append("Unsigned kernel/modules: Secure Boot users must self-sign (`contrib/sign-kernel-mok.sh`). Keep a stock kernel as fallback.")
    lines.append("")
    return "\n".join(lines)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--mode", required=True, choices=("weekly", "custom"))
    p.add_argument("--cells", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--notes", required=True)
    p.add_argument("--matrix", default="")
    p.add_argument("--provenance-map", default="{}")
    p.add_argument("--resolve", default="{}")
    p.add_argument("--inputs", default="{}")
    p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    p.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", ""))
    p.add_argument("--run-number", default=os.environ.get("GITHUB_RUN_NUMBER", ""))
    p.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
    p.add_argument("--series", default="")
    p.add_argument("--kernel-version", default="")
    p.add_argument("--workflow", default="")
    a = p.parse_args()

    frags = load_fragments(a.cells)
    statuses = load_statuses(a.cells)
    artifacts = scan_artifacts(a.out)
    # Attach release-time hashes to fragments by filename match.
    by_file = {x["file"]: x for x in artifacts}
    for frag in frags:
        for art in frag.get("artifacts", []):
            match = by_file.get(art.get("file", ""))
            if match:
                art["sha256"] = match["sha256"]
                art["size"] = match["size"]

    built_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if a.mode == "weekly":
        pmap = json.loads(a.provenance_map or "{}")
        manifest = {
            "schema": "cachyos-actions-provenance/1",
            "release_kind": "weekly",
            "pipeline": {
                "repo": a.repo, "workflow": a.workflow or "weekly-build.yml",
                "run_id": a.run_id, "run_number": a.run_number,
                "sha": a.sha, "built_at_utc": built_at,
            },
            "series": a.series, "kernel_version": a.kernel_version,
            "variants": pmap,
            "cells": frags,
            "statuses": statuses,
            "artifacts": artifacts,
            "gpg_source_keys": [{"keyid": k, "uid": u} for k, u in GPG_KEYS],
            "notes": ("kbuild .deb/.rpm tarballs GPG-verified (strict); "
                      "arch cells use makepkg --skippgpcheck (see per-cell upstream_head); "
                      "kernel-patches served over TLS, not GPG-signed; kernels ship unsigned."),
        }
        notes = render_weekly(a, frags, statuses, artifacts)
    else:
        try:
            resolve = json.loads(a.resolve or "{}")
        except ValueError:
            resolve = {}
        try:
            inputs = json.loads(a.inputs or "{}")
        except ValueError:
            inputs = {}
        manifest = {
            "schema": "cachyos-actions-provenance/1",
            "release_kind": "custom",
            "pipeline": {
                "repo": a.repo, "workflow": a.workflow or "custom-kernel.yml",
                "run_id": a.run_id, "run_number": a.run_number,
                "sha": a.sha, "built_at_utc": built_at,
            },
            "resolve": resolve,
            "inputs": inputs,
            "cells": frags,
            "statuses": statuses,
            "artifacts": artifacts,
            "gpg_source_keys": [{"keyid": k, "uid": u} for k, u in GPG_KEYS],
        }
        notes = render_custom(a, frags, statuses, artifacts, resolve, inputs)

    os.makedirs(a.out, exist_ok=True)
    prov_path = os.path.join(a.out, "provenance.json")
    with open(prov_path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    with open(a.notes, "w") as f:
        f.write(notes)
    append_sums(a.out, "provenance.json")
    print(f"provenance.json: {len(json.dumps(manifest))} bytes, "
          f"{len(frags)} cell(s), {len(artifacts)} artifact(s)")
    print(f"release notes: {a.notes}")


if __name__ == "__main__":
    main()
