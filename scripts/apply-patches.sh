#!/usr/bin/env bash
# Fetch and apply a list of cachyos/kernel-patches files against an
# extracted kernel source tree.
#
# The patch LIST comes from config/variants.yml (`patches:` per variant)
# and must mirror exactly what that variant's PKGBUILD source=() array
# adds for its default _cpusched. Upstream's application case block is
# per-PKGBUILD (the flagship applies NO BORE patch for 'cachyos', while
# deckify does), so hardcoding a scheduler->patch map here would be
# wrong - hence this being list-driven.
#
# Usage: apply-patches.sh <srcdir> <major.minor> [patches...]
# Env:   DRY_RUN=1   patch --dry-run only (PR validation), never modify
set -euo pipefail

SRCDIR="${1:?usage: apply-patches.sh <srcdir> <major.minor> [patches...]}"
MAJOR="${2:?}"
shift 2

PATCHSRC="https://raw.githubusercontent.com/cachyos/kernel-patches/master/${MAJOR}"

if [ "$#" -eq 0 ]; then
  echo "No extra patches declared for this variant - base tarball used as-is."
  exit 0
fi

cd "$SRCDIR"

FLAGS=(-Np1)
if [[ "${DRY_RUN:-0}" == "1" || "${DRY_RUN:-}" == "true" ]]; then
  FLAGS+=(--dry-run)
  echo "DRY RUN - tree will not be modified."
fi

failed=0
PATCH_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$PATCH_TMPDIR"' EXIT
for p in "$@"; do
  fname="$(basename "$p")"
  tmp_patch="${PATCH_TMPDIR}/${fname}"
  echo "Fetching ${PATCHSRC}/${p} ..."
  # --retry-delay: kernel-patches raw hosting throttles bursts from
  # 38 parallel cells; fail with the URL, not a bare curl error.
  if ! curl -fsSL --retry 3 --retry-delay 5 "${PATCHSRC}/${p}" -o "$tmp_patch"; then
    echo "FAIL: $fname (download failed: ${PATCHSRC}/${p})" >&2
    failed=1
    continue
  fi
  if patch "${FLAGS[@]}" < "$tmp_patch"; then
    echo "OK: $fname"
  else
    echo "FAIL: $fname (patch rejected - upstream drift? check kernel-patches ${MAJOR} series)" >&2
    failed=1
  fi
done
rm -rf "$PATCH_TMPDIR"
trap - EXIT

if (( failed )); then
  echo "One or more patches failed to apply." >&2
  exit 1
fi
echo "Patch series applied cleanly (${SRCDIR}, series 7.x=${MAJOR}, $# patches)."
