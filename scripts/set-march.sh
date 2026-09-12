#!/usr/bin/env bash
# Preflight check: fail fast (before a multi-hour kernel build starts)
# if the active GCC doesn't actually understand the requested -march
# level. Cheap insurance against a runner/container image that's
# quietly older than config/isa-levels.yml assumes.
#
# Usage: set-march.sh <x86-64|x86-64-v2|x86-64-v3|x86-64-v4>
set -euo pipefail

MARCH="${1:?usage: set-march.sh <x86-64|x86-64-v2|x86-64-v3|x86-64-v4>}"

echo 'int main(void){return 0;}' > /tmp/march-check.c

if ! gcc -march="$MARCH" -c /tmp/march-check.c -o /tmp/march-check.o 2>/tmp/march-check.err; then
  echo "::error::This toolchain's gcc does not support -march=${MARCH}."
  echo "See config/isa-levels.yml compiler_requirements for the minimum GCC/Clang versions."
  cat /tmp/march-check.err
  exit 1
fi

echo "OK: gcc on this runner supports -march=${MARCH}"
