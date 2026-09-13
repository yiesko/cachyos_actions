#!/usr/bin/env bash
# Preflight check: fail fast (before a multi-hour kernel build starts)
# if the active toolchain doesn't actually understand the requested -march
# level. Cheap insurance against a runner/container image that's
# quietly older than config/isa-levels.yml / config/cpu-tunings.yml assumes.
#
# Usage: set-march.sh <march>
#   Weekly matrix:  x86-64 | x86-64-v2 | x86-64-v3 | x86-64-v4
#   Custom builds:  any GCC-canonical -march= from config/cpu-tunings.yml
#                   (sandybridge, ivybridge, haswell, znver1..4, native, ...)
# Env: USE_LTO=none|thin|thin-dist|full (default none). When LTO is enabled
#      the build uses clang (LLVM=1), so the march is checked with clang too.
set -euo pipefail

MARCH="${1:?usage: set-march.sh <march>}"

echo 'int main(void){return 0;}' > /tmp/march-check.c

if ! gcc -march="$MARCH" -c /tmp/march-check.c -o /tmp/march-check.o 2>/tmp/march-check.err; then
  echo "::error::This toolchain's gcc does not support -march=${MARCH}."
  echo "See config/isa-levels.yml compiler_requirements and config/cpu-tunings.yml for supported values."
  cat /tmp/march-check.err
  exit 1
fi

echo "OK: gcc on this runner supports -march=${MARCH}"

# LTO builds compile with clang (LLVM=1): a march gcc accepts is usually
# fine for clang too, but fail fast here instead of 40min into the build
# (notably `native` resolves per-host, and brand-new CPUs like znver5 need
# a recent clang).
if [[ "${USE_LTO:-none}" != "none" ]]; then
  if command -v clang >/dev/null 2>&1; then
    if ! clang -march="$MARCH" -c /tmp/march-check.c -o /tmp/march-check.o 2>/tmp/march-check-clang.err; then
      echo "::error::This toolchain's clang does not support -march=${MARCH} (USE_LTO=${USE_LTO})."
      cat /tmp/march-check-clang.err
      exit 1
    fi
    echo "OK: clang on this runner supports -march=${MARCH}"
  else
    echo "warning: USE_LTO=${USE_LTO} needs clang, but clang not found yet (cell installs it later) - gcc check only." >&2
  fi
fi
