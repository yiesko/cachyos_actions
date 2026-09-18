#!/usr/bin/env bash
# One (variant, ISA) Arch build cell. Runs INSIDE the archlinux:base-devel
# container (workspace mounted at /work, ccache cache dir at /ccache).
#
# makepkg refuses to run as root, so this creates a throwaway `builder`
# user with passwordless sudo (makepkg -s uses it to install missing
# makedepends) and hands the actual build to scripts/package-arch.sh,
# which drives CachyOS's own PKGBUILD unmodified.
#
# Required env: VARIANT, PKGBUILD_DIR, SCHEDULER, ISA_NUM, MARCH
set -euo pipefail

: "${VARIANT:?}"; : "${PKGBUILD_DIR:?}"; : "${SCHEDULER:?}"
: "${ISA_NUM:?}"; : "${MARCH:?}"

CELL_START_EPOCH="$(date +%s 2>/dev/null || echo 0)"
export CELL_START_EPOCH

pacman-key --init >/dev/null 2>&1 || true
pacman -Syu --needed --noconfirm base-devel git ccache sudo

export PATH="/usr/lib/ccache:${PATH}"
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
mkdir -p "$CCACHE_DIR"
# Same stats discipline as the kbuild path: zero now, report at the end,
# so each cell's log shows whether ccache actually engaged here.
ccache -z >/dev/null 2>&1 || true
echo "--- ccache baseline ---"
ccache -s 2>&1 | head -n 12 || true

bash /work/scripts/set-march.sh "$MARCH"

id builder >/dev/null 2>&1 || useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-builder
chmod 0440 /etc/sudoers.d/99-builder
chown -R builder:builder /work "$CCACHE_DIR"

# GITHUB_WORKSPACE is not exported into `su` shells; pass everything
# explicitly through `env`.
set +e
runuser -u builder -- env \
  VARIANT="$VARIANT" \
  PKGBUILD_DIR="$PKGBUILD_DIR" \
  SCHEDULER="$SCHEDULER" \
  ISA_NUM="$ISA_NUM" \
  MARCH="$MARCH" \
  PKG_SUFFIX="${PKG_SUFFIX:-}" \
  USE_LTO="${USE_LTO:-none}" \
  CACHY_CONFIG="${CACHY_CONFIG:-yes}" \
  PREEMPT_MODE="${PREEMPT_MODE:-full}" \
  HZ_TICKS="${HZ_TICKS:-1000}" \
  SRC_TAG="${SRC_TAG:-}" \
  EXTRA_PATCHES="${EXTRA_PATCHES:-}" \
  PKGBUILD_SHA="${PKGBUILD_SHA:-unknown}" \
  LINUX_COMMIT="${LINUX_COMMIT:-unknown}" \
  PATCHES_SHA="${PATCHES_SHA:-unknown}" \
  CELL_START_EPOCH="${CELL_START_EPOCH:-0}" \
  GITHUB_JOB="${GITHUB_JOB:-arch}" \
  CCACHE_DIR="$CCACHE_DIR" \
  PATH="$PATH" \
  HOME=/home/builder \
  GITHUB_WORKSPACE=/work \
  bash /work/scripts/package-arch.sh
_arch_rc=$?
set -e
if (( _arch_rc == 2 )); then
  echo "::warning::Skipping Arch cell $VARIANT/v$ISA_NUM: patch drift (see provenance skipped_reason)" >&2
  mkdir -p /work/cell-status 2>/dev/null || true
  echo "skipped:drift: patch vs $SRC_TAG" > "/work/cell-status/${VARIANT}-v${ISA_NUM}-arch.txt" 2>/dev/null || true
  {
    _frag="/work/cell-status/provenance-${VARIANT}-v${ISA_NUM}-arch.json"
    _sk_tag_a="${SRC_TAG:-unknown}"
    _sk_reason_a="drift: patch vs src_tag $_sk_tag_a (arch $VARIANT)"
    SKIPPED_REASON="$_sk_reason_a" \
    CELL_KIND=arch JOB_NAME="${GITHUB_JOB:-arch}" \
    SRCDIR="" WORKDIR="" ARTIFACT_DIR="/work/out" \
    UPSTREAM_DIR="/work/upstream" ISA_LABEL="v${ISA_NUM}" SRC_TAG="$_sk_tag_a" \
    LOCALVERSION="unknown" MARCH="${MARCH:-unknown}" KCONFIG_MODE="generic" \
    EXTRA_PATCHES="${EXTRA_PATCHES:-}" \
    bash /work/scripts/collect-cell-provenance.sh --out "$_frag" || true
  } || true
  chown -R builder:builder /work 2>/dev/null || true
  chown -R "$(id -u):$(id -g)" /work 2>/dev/null || true
  echo "--- ccache final (this cell) ---"
  ccache -s 2>&1 | head -n 12 || true
  echo "Arch cell skipped (drift) — not a failure"
  exit 0
elif (( _arch_rc != 0 )); then
  exit $_arch_rc
fi

echo "--- ccache final (this cell) ---"
ccache -s 2>&1 | head -n 12 || true
