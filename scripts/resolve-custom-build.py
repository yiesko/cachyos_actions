#!/usr/bin/env python3
"""
Resolve one manual custom-kernel build (variant x base ISA x CPU tuning x LTO)
into concrete env for scripts/run-kbuild-build.sh.

Inputs (env or CLI, CLI wins):
  VARIANT, BASE_ISA (v1..v4), CPU_TUNING (id in config/cpu-tunings.yml),
  USE_LTO (none|thin|thin-dist|full), PKG_FORMAT (all|deb|rpm),
  SRC_TAG (blank = resolve live per variant), BUILDER_SUFFIX,
  NATIVE_ACK (yes required when tuning id == native).

Validates:
  - variant exists + enabled in config/variants.yml
  - tuning exists in config/cpu-tunings.yml, march lowercase-safe
  - tuning.base_isa == BASE_ISA (tuning implies its psABI floor; passing a
    different base would lie in Kconfig vs -march=)
  - RANK[BASE_ISA] >= RANK[variant.min_isa] (e.g. no v1 lts/server)
  - USE_LTO / PKG_FORMAT / BUILDER_SUFFIX (lowercase, dpkg-safe)

Resolves SRC_TAG live per variant via generate-matrix.resolve_kernel_version
unless --skip-version-resolution or SRC_TAG given.

Writes KEY=VALUE lines to $GITHUB_OUTPUT (or stdout): pkgbuild_dir,
scheduler, patches (space-separated), cachy_config (yes/no), preempt, hz,
isa_num, march, kconfig_mode, isa_label (e.g. v2-ivybridge), src_tag,
localversion (e.g. -cachyos-bore-v2-ivybridge-thin-yieskow).
"""
import argparse
import os
import sys
from pathlib import Path

import yaml  # PyYAML - installed by the workflow step before this runs

ROOT = Path(__file__).resolve().parent.parent
RANK = {"v1": 0, "v2": 1, "v3": 2, "v4": 3}


def load(name):
    with open(ROOT / "config" / name) as f:
        return yaml.safe_load(f)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--variant", default=os.environ.get("VARIANT", ""))
    p.add_argument("--base-isa", default=os.environ.get("BASE_ISA", ""))
    p.add_argument("--cpu-tuning", default=os.environ.get("CPU_TUNING", ""))
    p.add_argument("--use-lto", default=os.environ.get("USE_LTO", "none"))
    p.add_argument("--pkg-format", default=os.environ.get("PKG_FORMAT", "all"))
    p.add_argument("--src-tag", default=os.environ.get("SRC_TAG", ""))
    p.add_argument("--builder-suffix", default=os.environ.get("BUILDER_SUFFIX", "-yieskow"))
    p.add_argument("--native-ack", default=os.environ.get("NATIVE_ACK", "no"))
    p.add_argument("--skip-version-resolution", action="store_true")
    p.add_argument("--skip-provenance", action="store_true",
                   help="don't query upstream commit SHAs (provenance fields become 'unknown')")
    args = p.parse_args()

    variant_id = args.variant.strip()
    base_isa = args.base_isa.strip()
    tuning_id = args.cpu_tuning.strip()
    lto = args.use_lto.strip()
    pkg_format = args.pkg_format.strip()
    if not variant_id or not base_isa or not tuning_id:
        print("error: --variant, --base-isa and --cpu-tuning are required.", file=sys.stderr)
        sys.exit(2)
    if base_isa not in RANK:
        print(f"error: --base-isa must be one of v1..v4 (got {base_isa!r}).", file=sys.stderr)
        sys.exit(2)
    if lto not in ("none", "thin", "thin-dist", "full"):
        print(f"error: --use-lto must be none|thin|thin-dist|full (got {lto!r}).", file=sys.stderr)
        sys.exit(2)
    if pkg_format not in ("all", "deb", "rpm"):
        print(f"error: --pkg-format must be all|deb|rpm (got {pkg_format!r}).", file=sys.stderr)
        sys.exit(2)

    variants_cfg = load("variants.yml")
    variant = next((v for v in variants_cfg["variants"] if v["id"] == variant_id), None)
    if variant is None:
        print(f"error: unknown variant {variant_id!r}.", file=sys.stderr)
        sys.exit(2)
    if not variant.get("enabled", False):
        print(f"error: variant {variant_id!r} is disabled in config/variants.yml.", file=sys.stderr)
        sys.exit(2)

    tunings_cfg = load("cpu-tunings.yml")
    tuning = next((t for t in tunings_cfg.get("tunings", []) if t["id"] == tuning_id), None)
    if tuning is None:
        print(f"error: unknown cpu-tuning {tuning_id!r} (see config/cpu-tunings.yml).", file=sys.stderr)
        sys.exit(2)

    march = str(tuning["march"])
    if march != march.lower() or " " in march:
        print(f"error: tuning {tuning_id!r} has non-lowercase/spaced march {march!r}.", file=sys.stderr)
        sys.exit(2)
    if tuning.get("base_isa") != base_isa:
        print(f"error: tuning {tuning_id!r} implies base_isa {tuning.get('base_isa')!r}, "
              f"got --base-isa {base_isa!r} (Kconfig must match -march= floor).", file=sys.stderr)
        sys.exit(2)
    floor = RANK[variant.get("min_isa", "v1")]
    if RANK[base_isa] < floor:
        print(f"error: variant {variant_id!r} needs >= {variant.get('min_isa')} "
              f"(got base {base_isa}).", file=sys.stderr)
        sys.exit(2)
    if tuning_id == "native" and args.native_ack.strip().lower() not in ("yes", "true", "1"):
        print("error: tuning `native` is host-dependent (X86_NATIVE_CPU). "
              "Re-run with NATIVE_ACK=yes to confirm you want a non-reproducible build.",
              file=sys.stderr)
        sys.exit(2)

    builder_suffix = args.builder_suffix.strip()
    # Auto-normalize: bare `yieskow` -> `-yieskow` so uname -r always carries
    # the builder tag after the config suffixes; empty stays empty (opt-out).
    if builder_suffix and not builder_suffix.startswith(("-", "+", ".", "_")):
        builder_suffix = f"-{builder_suffix}"
    if builder_suffix != builder_suffix.lower() or " " in builder_suffix:
        print(f"error: --builder-suffix must stay lowercase, no spaces (got {args.builder_suffix!r}).",
              file=sys.stderr)
        sys.exit(2)

    src_tag = args.src_tag.strip()
    if not src_tag and not args.skip_version_resolution:
        sys.path.insert(0, str(ROOT / "scripts"))
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "generate_matrix", str(ROOT / "scripts" / "generate-matrix.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        try:
            _, src_tag = mod.resolve_kernel_version(variant["pkgbuild_dir"])
        except Exception as exc:  # noqa: BLE001 - fail loudly
            print(f"[resolve-custom] ERROR resolving source tag for "
                  f"{variant['pkgbuild_dir']}: {exc}", file=sys.stderr)
            sys.exit(1)
    if not src_tag and not args.skip_version_resolution:
        print("error: could not resolve SRC_TAG (pass --src-tag explicitly).", file=sys.stderr)
        sys.exit(1)

    isa_num = {"v1": 1, "v2": 2, "v3": 3, "v4": 4}[base_isa]
    # Generic tunings keep the plain vN label so names stay identical to the
    # weekly matrix (`v3`); tuned builds get `vN-tuning` (`v2-ivybridge`).
    isa_label = base_isa if tuning_id in ("generic", "x86-64-v2", "x86-64-v3", "x86-64-v4") else f"{base_isa}-{tuning_id}"
    lto_suffix = "" if lto == "none" else f"-{lto}"
    localversion = f"-{variant_id}-{isa_label}{lto_suffix}{builder_suffix}"

    # Best-effort upstream SHAs for the release manifest. Never fatal:
    # failures degrade to "unknown" (see generate-matrix.resolve_provenance).
    pkgbuild_sha = "unknown"
    linux_commit = "unknown"
    patches_sha = "unknown"
    if not args.skip_provenance and src_tag and not args.skip_version_resolution:
        sys.path.insert(0, str(ROOT / "scripts"))
        import importlib.util
        try:
            spec = importlib.util.spec_from_file_location(
                "generate_matrix_prov", str(ROOT / "scripts" / "generate-matrix.py"))
            prov_mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(prov_mod)
            prov = prov_mod.resolve_provenance(variant["pkgbuild_dir"], src_tag)
            pkgbuild_sha = prov.get("pkgbuild_sha", "unknown")
            linux_commit = prov.get("linux_commit", "unknown")
            patches_sha = prov.get("patches_sha", "unknown")
        except Exception as exc:  # noqa: BLE001 - provenance is advisory
            print(f"[resolve-custom] WARNING: provenance lookup failed: {exc}",
                  file=sys.stderr)

    out = {
        "pkgbuild_dir": variant["pkgbuild_dir"],
        "scheduler": variant["scheduler"],
        "patches": " ".join(variant.get("patches", [])),
        "cachy_config": "yes" if variant.get("cachy_config", True) else "no",
        "preempt": variant.get("preempt", "full"),
        "hz": str(variant.get("hz", 1000)),
        "isa_num": str(isa_num),
        "march": march,
        "kconfig_mode": str(tuning.get("kconfig", "generic")),
        "isa_label": isa_label,
        "src_tag": src_tag,
        "localversion": localversion,
        "builder_suffix": builder_suffix,
        "tuning_id": tuning_id,
        "base_isa": base_isa,
        "native_ack": args.native_ack.strip().lower(),
        "pkg_format": pkg_format,
        "pkgbuild_sha": pkgbuild_sha,
        "linux_commit": linux_commit,
        "patches_sha": patches_sha,
    }
    lines = [f"{k}={v}\n" for k, v in out.items()]
    gh_output = os.environ.get("GITHUB_OUTPUT")
    if gh_output:
        with open(gh_output, "a") as f:
            f.writelines(lines)
    else:
        sys.stdout.writelines(lines)
    print(f"[resolve-custom] {variant_id} {isa_label} {march} lto={lto} "
          f"format={pkg_format} src={src_tag or '(offline)'} -> {localversion}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
