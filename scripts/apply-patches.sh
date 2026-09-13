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

# Provenance record: one TSV line per patch (path, sha256, url, result).
# PROVENANCE_RECORD may point elsewhere (cell WORKDIR); default is the
# parent of the source tree (prepare-kernel-source.sh WORKDIR layout).
# Best-effort: recording must never fail the build.
PROVENANCE_RECORD="${PROVENANCE_RECORD:-$(pwd)/../applied-patches.tsv}"
: > "$PROVENANCE_RECORD" 2>/dev/null || true

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
  # Same storm-proof retry policy as fetch-cachyos-source.sh: kernel-patches
  # raw hosting throttles bursts from 70+ parallel cells. Fail with the
  # URL, not a bare curl error.
  if ! curl -fsSL --retry 8 --retry-delay 10 --retry-max-time 300 --retry-all-errors "${PATCHSRC}/${p}" -o "$tmp_patch"; then
    echo "FAIL: $fname (download failed: ${PATCHSRC}/${p})" >&2
    printf '%s\t%s\t%s\t%s\n' "$p" "unknown" "${PATCHSRC}/${p}" "download-failed" >> "$PROVENANCE_RECORD" 2>/dev/null || true
    failed=1
    continue
  fi
  patch_sha="unknown"
  if command -v sha256sum >/dev/null 2>&1; then
    patch_sha="$(sha256sum "$tmp_patch" | awk '{print $1}')"
  fi
  if patch "${FLAGS[@]}" < "$tmp_patch"; then
    echo "OK: $fname"
    printf '%s\t%s\t%s\t%s\n' "$p" "$patch_sha" "${PATCHSRC}/${p}" "applied" >> "$PROVENANCE_RECORD" 2>/dev/null || true
  else
    echo "FAIL: $fname (patch rejected - upstream drift? check kernel-patches ${MAJOR} series)" >&2
    printf '%s\t%s\t%s\t%s\n' "$p" "$patch_sha" "${PATCHSRC}/${p}" "rejected" >> "$PROVENANCE_RECORD" 2>/dev/null || true
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
