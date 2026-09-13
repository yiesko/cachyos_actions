#!/usr/bin/env bash
# Re-apply the same `scripts/config` toggles CachyOS's PKGBUILDs set in
# their prepare() step, for the Debian/Fedora build paths that don't go
# through makepkg. Starts from the actual per-variant `config` file
# CachyOS ships next to each PKGBUILD so we're tuning the same base
# config they do, not a generic defconfig.
#
# The prepare() config-toggle block is identical across every PKGBUILD
# (verified Aug 2026), including its quirks - e.g. 'cachyos' maps to
# `-e SCHED_BORE` even for variants that don't apply the BORE patch,
# where olddefconfig silently drops the toggle. We reproduce that
# behavior faithfully rather than second-guessing it.
#
# SOURCE OF TRUTH: any linux-cachyos*/PKGBUILD prepare().
#
# Usage: configure-kernel.sh <srcdir> <pkgbuild_dir> <scheduler> <isa_num 1-4>
# Env:   CACHY_CONFIG=yes|no   (default yes; per-variant `_cachy_config`)
#        PREEMPT_MODE=full|lazy (default full; rt schedulers ignore it)
#        HZ_TICKS=100|250|300|500|600|750|1000 (default 1000; per-variant
#                 `_HZ_ticks` — the server folder ships 300)
#        KCONFIG_MODE=generic|native|zen4 (default generic).
#                 generic: GENERIC_CPU + X86_64_VERSION=ISA_NUM (weekly matrix
#                   + most custom tunings: tuning is `-march=` only, since
#                   upstream dropped per-uarch CONFIG_M* in 6.15).
#                 native:  X86_NATIVE_CPU (custom `native` tuning).
#                 zen4:    MZEN4 (custom `zen4` tuning, like upstream
#                   `_processor_opt=zen4`). ISA_NUM is ignored there.
set -euo pipefail

SRCDIR="${1:?}"; PKGBUILD_DIR="${2:?}"; SCHEDULER="${3:?}"; ISA_NUM="${4:?}"

CONFIG_URL="https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/${PKGBUILD_DIR}/config"
echo "Fetching base config from ${CONFIG_URL} ..."
curl -fL --retry 3 --retry-delay 5 "$CONFIG_URL" -o "${SRCDIR}/.config"
if [[ ! -s "${SRCDIR}/.config" ]]; then
  echo "error: downloaded base config is missing or empty (${CONFIG_URL})." >&2
  exit 1
fi
# Provenance: hash of the upstream base config before our toggles.
BASE_CONFIG_SHA256="unknown"
if command -v sha256sum >/dev/null 2>&1; then
  BASE_CONFIG_SHA256="$(sha256sum "${SRCDIR}/.config" | awk '{print $1}')"
fi

cd "$SRCDIR"

# Wrapper: ./scripts/config exits non-zero when a symbol was renamed or
# removed upstream (e.g. HZ_300, TRANSPARENT_HUGEPAGE_*). Fail with the
# toggle context instead of a bare `set -e` abort mid-prepare.
cfg() {
  if ! ./scripts/config "$@"; then
    echo "error: './scripts/config $*' failed - symbol likely renamed/removed upstream." >&2
    echo "Check the live ${PKGBUILD_DIR}/config and PKGBUILD prepare() for drift." >&2
    exit 1
  fi
}

# CachyOS config knob - mirrors each variant's `_cachy_config` default
# (the server variant ships with it OFF upstream).
case "${CACHY_CONFIG:-yes}" in
  yes) cfg -e CACHY ;;
  no)  cfg -d CACHY ;;
  *) echo "unknown CACHY_CONFIG: ${CACHY_CONFIG:-}" >&2; exit 1 ;;
esac
echo "CONFIG_CACHY: ${CACHY_CONFIG:-yes}"

# CPU scheduler - mirrors the `case "$_cpusched" in` block in prepare()
case "$SCHEDULER" in
  cachyos|bore|hardened) cfg -e SCHED_BORE ;;
  bmq)                   cfg -e SCHED_ALT -e SCHED_BMQ ;;
  eevdf)                 : ;;
  rt)                    cfg -e PREEMPT_RT ;;
  rt-bore)               cfg -e SCHED_BORE -e PREEMPT_RT ;;
  *) echo "unknown scheduler: $SCHEDULER" >&2; exit 1 ;;
esac
echo "Selected ${SCHEDULER^^} scheduler."

# CPU tuning Kconfig - CONFIG_GENERIC_CPU + CONFIG_X86_64_VERSION is exactly
# what `_processor_opt=generic_vN` sets in the PKGBUILD. Custom builds decouple
# this from `-march=`: tuning like `haswell`/`znver3` has no CONFIG_M* anymore
# (dropped upstream in 6.15), so Kconfig stays generic at the tuning's base
# ISA while KCFLAGS carries the real tuning. Only `native`/`zen4` use their
# authentic modes (mirroring `_processor_opt=native|zen4`).
case "${KCONFIG_MODE:-generic}" in
  generic)
    cfg -e GENERIC_CPU -d MZEN4 -d X86_NATIVE_CPU \
      --set-val X86_64_VERSION "$ISA_NUM"
    echo "Selected x86-64-v${ISA_NUM} (or generic, for v1)."
    ;;
  native)
    cfg -d GENERIC_CPU -d MZEN4 -e X86_NATIVE_CPU
    echo "Selected native CPU optimization (X86_NATIVE_CPU; build host dependent)."
    ;;
  zen4)
    cfg -d GENERIC_CPU -e MZEN4 -d X86_NATIVE_CPU
    echo "Selected Zen4 CPU optimization (MZEN4)."
    ;;
  *) echo "unknown KCONFIG_MODE: ${KCONFIG_MODE:-}" >&2; exit 1 ;;
esac

# Tick rate: mirrors the `case "$_HZ_ticks" in` block in prepare() -
# per-variant `_HZ_ticks` default (1000 everywhere upstream except the
# server folder at 300), validated the same way (unknown values die here,
# not deep inside olddefconfig).
case "${HZ_TICKS:-1000}" in
  100|250|500|600|750|1000)
    cfg -d HZ_300 -e "HZ_${HZ_TICKS}" --set-val HZ "${HZ_TICKS}" ;;
  300)
    cfg -e HZ_300 --set-val HZ 300 ;;
  *) echo "unknown HZ_TICKS: ${HZ_TICKS:-}" >&2; exit 1 ;;
esac
echo "Tick rate: ${HZ_TICKS:-1000}Hz."

# Preemption model - mirrors each variant's `_preempt` default (server
# ships LAZY upstream). Skipped entirely for rt schedulers, exactly like
# the PKGBUILD does - PREEMPT_RT implies its own preemption model.
case "$SCHEDULER" in
  rt|rt-bore) : ;;
  *)
    case "${PREEMPT_MODE:-full}" in
      full) cfg -e PREEMPT -d PREEMPT_LAZY ;;
      lazy) cfg -d PREEMPT -e PREEMPT_LAZY ;;
      *) echo "unknown PREEMPT_MODE: ${PREEMPT_MODE:-}" >&2; exit 1 ;;
    esac
    echo "Preemption: ${PREEMPT_MODE:-full}"
    ;;
esac

# Transparent hugepages: "always", matching CachyOS's default.
cfg -d TRANSPARENT_HUGEPAGE_MADVISE -e TRANSPARENT_HUGEPAGE_ALWAYS

# Link-time optimization - mirrors the `case "$_use_llvm_lto" in` block
# in the PKGBUILD's prepare() (verified Aug 2026). Requires the LLVM
# toolchain: the cell wrappers export LLVM=1 to make when USE_LTO is
# set, and must have clang/lld/llvm installed. Note AutoFDO/Propeller
# (upstream's other PGO layers) can NOT be replicated in CI at all -
# they need perf profiles collected from real workloads, which only
# exists on upstream's own build infra.
case "${USE_LTO:-none}" in
  thin)      cfg -e LTO_CLANG_THIN ;;
  thin-dist) cfg -e LTO_CLANG_THIN_DIST ;;
  full)      cfg -e LTO_CLANG_FULL ;;
  none)      cfg -e LTO_NONE ;;
  *) echo "unknown USE_LTO value: ${USE_LTO:-}" >&2; exit 1 ;;
esac
echo "Selected LTO mode: ${USE_LTO:-none}."

# CI builds: trade -O3 for smaller/faster-to-build debug info, same
# as the PKGBUILD does when it detects $CI/$GITHUB_RUN_ID.
cfg \
  -d CC_OPTIMIZE_FOR_PERFORMANCE_O3 \
  -e CC_OPTIMIZE_FOR_SIZE \
  -d DEBUG_KERNEL \
  -e DEBUG_INFO_REDUCED

echo "Resolving dependent config options (olddefconfig) ..."
make olddefconfig >/dev/null

KERNELRELEASE="$(make -s kernelrelease 2>/dev/null || echo unknown)"
echo "Kernel config ready: ${KERNELRELEASE}"
# Provenance record for the release manifest (best-effort, never fatal).
{
  echo "CONFIG_URL=${CONFIG_URL}"
  echo "BASE_CONFIG_SHA256=${BASE_CONFIG_SHA256:-unknown}"
  if command -v sha256sum >/dev/null 2>&1 && [[ -f .config ]]; then
    echo "FINAL_CONFIG_SHA256=$(sha256sum .config | awk '{print $1}')"
  else
    echo "FINAL_CONFIG_SHA256=unknown"
  fi
  echo "KERNELRELEASE=${KERNELRELEASE:-unknown}"
  echo "SCHEDULER=${SCHEDULER} ISA_NUM=${ISA_NUM} KCONFIG_MODE=${KCONFIG_MODE:-generic}"
  echo "CACHY_CONFIG=${CACHY_CONFIG:-yes} PREEMPT_MODE=${PREEMPT_MODE:-full} HZ_TICKS=${HZ_TICKS:-1000} USE_LTO=${USE_LTO:-none}"
} > .provenance-config.env 2>/dev/null || true
