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
runuser -u builder -- env \
  VARIANT="$VARIANT" \
  PKGBUILD_DIR="$PKGBUILD_DIR" \
  SCHEDULER="$SCHEDULER" \
  ISA_NUM="$ISA_NUM" \
  PKG_SUFFIX="${PKG_SUFFIX:-}" \
  USE_LTO="${USE_LTO:-none}" \
  CACHY_CONFIG="${CACHY_CONFIG:-yes}" \
  PREEMPT_MODE="${PREEMPT_MODE:-full}" \
  HZ_TICKS="${HZ_TICKS:-1000}" \
  CCACHE_DIR="$CCACHE_DIR" \
  PATH="$PATH" \
  HOME=/home/builder \
  GITHUB_WORKSPACE=/work \
  bash /work/scripts/package-arch.sh

echo "--- ccache final (this cell) ---"
ccache -s 2>&1 | head -n 12 || true
