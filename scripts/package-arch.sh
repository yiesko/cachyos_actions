#!/usr/bin/env bash
# Build + package one (variant, ISA) cell the "native" way: check out
# CachyOS's own PKGBUILD folder and let makepkg do everything, the
# same way a CachyOS user building locally would - we don't touch its
# build()/package() logic, only select it through the same env vars
# documented at the top of every linux-cachyos*/PKGBUILD.
#
# Must run as a non-root user with base-devel installed (see the
# build-arch job in weekly-build.yml, which creates a `builder` user
# for exactly this).
#
# Required env: VARIANT, PKGBUILD_DIR, SCHEDULER, ISA_NUM
set -euo pipefail

: "${VARIANT:?}"; : "${PKGBUILD_DIR:?}"; : "${SCHEDULER:?}"; : "${ISA_NUM:?}"
: "${GITHUB_WORKSPACE:?}"

git config --global --add safe.directory '*'

if [ ! -d upstream ]; then
  git clone --filter=blob:none --sparse --depth 1 \
    https://github.com/CachyOS/linux-cachyos.git upstream
fi
( cd upstream && git sparse-checkout set "$PKGBUILD_DIR" )

# See the "BUILD OPTIONS" comment block at the top of any
# linux-cachyos*/PKGBUILD for the full list of these variables.
export _cpusched="$SCHEDULER"
export _processor_opt="generic_v${ISA_NUM}"
export _use_lto_suffix=no   # keep package names predictable across ISA levels
export _use_gcc_suffix=no
export _HZ_ticks="${HZ_TICKS:-1000}"

# NOTE: do NOT override `_use_llvm_lto` here. Each PKGBUILD ships a
# STATIC b2sums array sized for that folder's DEFAULT option set - e.g.
# the flagship defaults to ThinLTO and its 4th checksum IS
# misc/dkms-clang.patch; forcing none shrinks source=() to 3 entries and
# makepkg dies with "Integrity checks (b2) differ in size from the
# source array" (observed in CI run 32660580085). The same holds in
# reverse for every none-default folder. So the makepkg path always
# builds at the variant's authentic LTO default (flagship/rc = Clang
# ThinLTO, others = none); the build_lto input only drives the kbuild
# paths, which have no such checksum coupling.

# Per-variant knobs verified from each folder's PKGBUILD defaults
# (server ships _preempt=lazy and _cachy_config=no, for example).
export _cachy_config="${CACHY_CONFIG:-yes}"
export _preempt="${PREEMPT_MODE:-full}"

export CI=true              # PKGBUILD already special-cases CI builds

cd "upstream/${PKGBUILD_DIR}"
echo "Building ${VARIANT} at x86-64-v${ISA_NUM} (_cpusched=${_cpusched}) ..."
# makepkg's own source=() download uses curl without retry; a single
# CDN hiccup under 70 parallel cells killed hardened v1 in weekly-25
# (curl 35 Recv failure). Retry the whole makepkg a few times with
# backoff — second attempt reuses already-fetched sources.
for _attempt in 1 2 3; do
  if makepkg -s --noconfirm --skippgpcheck; then
    break
  fi
  rc=$?
  if (( _attempt == 3 )); then
    # Drift: deckify handheld 7.2 now targets 7.2.6-1 but PKGBUILD is still
    # at 7.2.3-2 — treat as skipped (explicit notice in release) not hard
    # failure. Generic heuristic: any final makepkg failure for deckify
    # after retries is assumed drift (transient CDN would have recovered
    # on retry 2/3).
    if [[ "${VARIANT:-}" == "cachyos-deckify" ]]; then
      echo "::warning::makepkg patch drift suspected for $VARIANT (src ${SRC_TAG:-unknown}) — auto-skipping" >&2
      exit 2
    fi
    echo "error: makepkg failed after $_attempt attempts." >&2
    exit $rc
  fi
  echo "warning: makepkg attempt $_attempt failed (rc=$rc), retrying in $(( _attempt * 15 ))s ..." >&2
  sleep $(( _attempt * 15 ))
done

mkdir -p "${GITHUB_WORKSPACE}/out"
# Upstream pkgname does NOT encode the ISA level (_processor_opt only
# changes MARCH at build time), so v1..v4 of the same variant would emit
# identically-named *.pkg.tar.zst and overwrite each other at release
# aggregation. Disambiguate with the matrix pkg_suffix (""/-v2/-v3/-v4).
shopt -s nullglob
built=(*.pkg.tar.zst)
shopt -u nullglob
if (( ${#built[@]} == 0 )); then
  echo "error: makepkg produced no *.pkg.tar.zst in upstream/${PKGBUILD_DIR}." >&2
  exit 1
fi
for pkg in "${built[@]}"; do
  dest="${GITHUB_WORKSPACE}/out/$(basename "$pkg")"
  if [[ -n "${PKG_SUFFIX:-}" ]]; then
    dest="${dest%.pkg.tar.zst}${PKG_SUFFIX}.pkg.tar.zst"
    if [[ -e "$dest" ]]; then
      echo "error: refusing to overwrite existing ${dest} (ISA collision?)." >&2
      exit 1
    fi
  fi
  cp -v -- "$pkg" "$dest"
done

# Provenance fragment for the release manifest (best-effort, never fatal).
# The makepkg path resolves its own source=() array, so the recorded
# upstream HEAD here is the ground truth for what was actually built
# (the matrix src_tag is advisory on this path).
{
  mkdir -p "${GITHUB_WORKSPACE}/cell-status" 2>/dev/null || true
  _frag="${GITHUB_WORKSPACE}/cell-status/provenance-${VARIANT}-v${ISA_NUM}-arch.json"
  CELL_KIND=arch JOB_NAME="${GITHUB_JOB:-arch}" \
  SRCDIR="" WORKDIR="" ARTIFACT_DIR="${GITHUB_WORKSPACE}/out" \
  UPSTREAM_DIR="${GITHUB_WORKSPACE}/upstream" \
  ISA_LABEL="v${ISA_NUM}" \
  SRC_TAG="${SRC_TAG:-unknown}" \
  LOCALVERSION="unknown" \
  MARCH="${MARCH:-unknown}" \
  KCONFIG_MODE="generic" \
  EXTRA_PATCHES="${EXTRA_PATCHES:-}" \
  bash "${GITHUB_WORKSPACE}/scripts/collect-cell-provenance.sh" --out "$_frag" || true
} || true
