#!/usr/bin/env bash
# One (variant, ISA) kbuild cell producing BOTH .deb and .rpm from a
# SINGLE compiled tree.
#
# Why merged: bindeb-pkg and binrpm-pkg only *package* an already-built
# tree - running them back-to-back costs one full compile plus two fast
# packaging passes, versus two full compiles when they were separate
# matrix jobs. Both formats are distro-generic kbuild outputs; the RPM
# side uses Ubuntu's own rpmbuild (apt package 'rpm'), which handles the
# kernel's generated spec fine.
#
# Required env: VARIANT, PKGBUILD_DIR, SCHEDULER, ISA_NUM, MARCH
# Optional env: SRC_TAG, USE_LTO, CACHY_CONFIG, PREEMPT_MODE, HZ_TICKS,
#               KCONFIG_MODE, ISA_LABEL, PKG_FORMAT, EXTRA_PATCHES,
#               CCACHE_DIR, CCACHE_MAXSIZE
#   ISA_NUM stays the Kconfig selector (1..4, passed to prepare/configure).
#   ISA_LABEL is the human/package label (default "v<ISA_NUM>", custom e.g.
#     "v2-ivybridge"): it drives LOCALVERSION/ISA passed to package-*.sh so
#     tuned builds never collide with generic ones. Lowercase, dpkg-safe.
#   PKG_FORMAT=all|deb|rpm (default all): custom single builds may want
#     only one family; weekly matrix always builds both.
set -euo pipefail

: "${VARIANT:?}"; : "${PKGBUILD_DIR:?}"; : "${SCHEDULER:?}"
: "${ISA_NUM:?}"; : "${MARCH:?}"

# Fail fast on package-name-illegal characters: bindeb-pkg only surfaces
# dpkg's lowercase rule AFTER the full compile (~1h wasted per cell).
# Reconstruct the effective LOCALVERSION with the same rules as
# package-deb.sh/package-rpm.sh and refuse uppercase up front (dpkg
# requires [a-z0-9][-+.:a-z0-9]+). RPM would tolerate more, but every
# kbuild cell builds BOTH formats from one tree.
case "${USE_LTO:-none}" in
  none) _lto_suffix="" ;;
  thin|thin-dist|full) _lto_suffix="-${USE_LTO}" ;;
  *) echo "error: unknown USE_LTO value: ${USE_LTO:-}" >&2; exit 1 ;;
esac
# Builder tag auto-normalization: bare `yieskow` -> `-yieskow` so uname -r
# always carries it after the config suffixes; empty stays empty (opt-out).
# NOTE: ${VAR-default} (no colon) so BUILDER_SUFFIX="" truly disables.
BUILDER_SUFFIX="${BUILDER_SUFFIX--yieskow}"
if [[ -n "$BUILDER_SUFFIX" && "$BUILDER_SUFFIX" != [-+._]* ]]; then
  BUILDER_SUFFIX="-$BUILDER_SUFFIX"
fi
export BUILDER_SUFFIX
_effective_localversion="-${VARIANT}-${ISA_LABEL:-${ISA_NUM:+v}${ISA_NUM:-}}${_lto_suffix}${BUILDER_SUFFIX}"
if [[ "$_effective_localversion" == *[A-Z]* ]]; then
  echo "error: LOCALVERSION '$_effective_localversion' contains uppercase - dpkg package names must be lowercase." >&2
  exit 1
fi
if [[ "${_effective_localversion}" == *" "* ]]; then
  echo "error: LOCALVERSION '$_effective_localversion' contains spaces." >&2
  exit 1
fi
# ISA label for the packaging passes: weekly "vN", custom "vN-tuning".
ISA_LABEL="${ISA_LABEL:-v${ISA_NUM}}"

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPTS_DIR")"

# Base toolchain + kbuild's declared debian build-deps (kernel 7.x
# hard-fails bindeb-pkg without them - observed in CI) + rpm tooling for
# the second packaging pass. LTO cells additionally need LLVM.
PKGS=(build-essential debhelper libdw-dev bc bison cpio dwarves flex
      libelf-dev libssl-dev perl python3 zstd dpkg-dev ccache
      ca-certificates curl git gpg rpm elfutils)
if [[ "${USE_LTO:-none}" != "none" ]]; then
  PKGS+=(clang lld llvm)
fi

export DEBIAN_FRONTEND=noninteractive
if [[ "$(id -u)" -eq 0 ]]; then
  APT=(apt-get)
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  # GitHub Actions runners: non-root user with passwordless sudo.
  APT=(sudo apt-get)
else
  echo "warning: no root/sudo available - assuming deps are preinstalled." >&2
  APT=()
fi
if (( ${#APT[@]} )); then
  # One transient mirror failure must not kill a 2h cell: retry the update.
  for attempt in 1 2 3; do
    if "${APT[@]}" update -qq; then
      break
    elif (( attempt == 3 )); then
      echo "error: apt-get update failed 3 times - aborting before the build." >&2
      exit 1
    fi
    sleep 15
  done
  "${APT[@]}" install -y -qq "${PKGS[@]}"
fi

# Fail fast on a full disk: a kernel tree + 2 packaging passes needs
# ~25 GB; GitHub runners only have ~14 GB free AFTER the cleanup step.
echo "--- disk preflight ---"
df -h / /tmp
avail_kb="$(df -k / --output=avail | tail -n1 | tr -d ' ')"
if (( avail_kb < 12 * 1024 * 1024 )); then
  echo "error: less than 12 GB free on / - kernel build will hit ENOSPC." >&2
  exit 1
fi

export PATH="/usr/lib/ccache:${PATH}"
export CCACHE_DIR="${CCACHE_DIR:-${ROOT_DIR}/ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-3G}"
mkdir -p "$CCACHE_DIR"
ccache -M "$CCACHE_MAXSIZE" >/dev/null || echo "warning: ccache unavailable - building without cache." >&2
# Stats discipline: zero counters now so the end-of-cell readout below is
# THIS cell's hit rate (not lifetime), answering whether ccache earns its
# ~10GB repo quota across weekly version bumps.
ccache -z >/dev/null 2>&1 || true
echo "--- ccache baseline ---"
ccache -s 2>&1 | head -n 12 || true

bash "${SCRIPTS_DIR}/set-march.sh" "$MARCH"

WORKDIR="${ROOT_DIR}/kernel-src" \
SRC_TAG="${SRC_TAG:-}" \
PKGBUILD_DIR="$PKGBUILD_DIR" \
SCHEDULER="$SCHEDULER" \
ISA_NUM="$ISA_NUM" \
KCONFIG_MODE="${KCONFIG_MODE:-generic}" \
bash "${SCRIPTS_DIR}/prepare-kernel-source.sh"

SRCDIR="$(find "${ROOT_DIR}/kernel-src" -maxdepth 1 -mindepth 1 -type d -name 'cachyos-*' -print -quit)"
if [[ -z "${SRCDIR:-}" ]]; then
  echo "error: no cachyos-* source tree under ${ROOT_DIR}/kernel-src after prepare." >&2
  exit 1
fi
if [[ "$(find "${ROOT_DIR}/kernel-src" -maxdepth 1 -mindepth 1 -type d -name 'cachyos-*' | wc -l)" -gt 1 ]]; then
  echo "error: multiple cachyos-* trees under ${ROOT_DIR}/kernel-src - refusing to guess." >&2
  find "${ROOT_DIR}/kernel-src" -maxdepth 1 -mindepth 1 -type d -name 'cachyos-*' >&2
  exit 1
fi

CELL_ENV=(
  VARIANT="$VARIANT"
  SCHEDULER="$SCHEDULER"
  MARCH="$MARCH"
  SRCDIR="$SRCDIR"
  GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$ROOT_DIR}"
)

echo "=== Packaging (.deb/.rpm from one compile; PKG_FORMAT=${PKG_FORMAT:-all}) ==="
case "${PKG_FORMAT:-all}" in
  all|deb)
    echo "=== Packaging pass: .deb ==="
    env "${CELL_ENV[@]}" ISA="$ISA_LABEL" \
      bash "${SCRIPTS_DIR}/package-deb.sh"
    ;;
esac
case "${PKG_FORMAT:-all}" in
  all|rpm)
    echo "=== Packaging pass: .rpm (tree already built - fast) ==="
    env "${CELL_ENV[@]}" ISA="$ISA_LABEL" \
      bash "${SCRIPTS_DIR}/package-rpm.sh"
    ;;
esac
case "${PKG_FORMAT:-all}" in
  all|deb|rpm) : ;;
  *) echo "error: unknown PKG_FORMAT: ${PKG_FORMAT:-}" >&2; exit 1 ;;
esac

OUT_DIR="${GITHUB_WORKSPACE:-$ROOT_DIR}/out"
shopt -s nullglob
staged_pkgs=("$OUT_DIR"/*.deb "$OUT_DIR"/*.rpm)
shopt -u nullglob
if (( ${#staged_pkgs[@]} == 0 )); then
  echo "error: kbuild cell finished with zero packages staged in ${OUT_DIR}." >&2
  exit 1
fi
echo "kbuild cell complete: ${#staged_pkgs[@]} package(s) staged."
echo "--- ccache final (this cell) ---"
ccache -s 2>&1 | head -n 12 || true
