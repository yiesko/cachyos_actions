#!/usr/bin/env bash
# Shared prepare chain for the kbuild (deb/rpm) build cells:
#   fetch signed tarball -> apply scheduler patches -> configure kernel
# -> make sure optional toolchains demanded by the config exist.
#
# Used by run-kbuild-build.sh and by the PR-time patch
# dry-run workflow. The Arch cell doesn't use this - makepkg resolves
# its own source=() array.
#
# Required env:
#   SRC_TAG        exact CachyOS/linux release tag (e.g. cachyos-7.2.0-1);
#                  empty = let fetch-cachyos-source.sh auto-resolve
#   PKGBUILD_DIR   upstream folder whose shipped base config we start from
#   SCHEDULER      _cpusched value (see config/variants.yml header)
#   ISA_NUM        1..4
#   WORKDIR        where the tarball lands / tree is extracted
# Optional env:
#   KCONFIG_MODE   generic|native|zen4 (default generic; custom `native`/`zen4`
#                  tunings use their authentic mode, see configure-kernel.sh)
set -euo pipefail

: "${PKGBUILD_DIR:?}"; : "${SCHEDULER:?}"; : "${ISA_NUM:?}"; : "${WORKDIR:?}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="${GITHUB_OUTPUT:-/dev/null}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Only reuse a present tree when it matches the requested SRC_TAG.
# A stale/corrupt tree from a failed run must never be silently reused:
# it makes patch/config failures non-reproducible across retries.
EXISTING="$(find . -maxdepth 1 -mindepth 1 -type d -name 'cachyos-*' -print -quit)"
if [[ -n "${SRC_TAG:-}" && -n "$EXISTING" && "$EXISTING" != "./${SRC_TAG}" && "$EXISTING" != "${SRC_TAG}" ]]; then
  echo "Existing tree ${EXISTING} does not match requested SRC_TAG=${SRC_TAG} - removing." >&2
  rm -rf "$EXISTING"
  EXISTING=""
fi
if [[ -z "$EXISTING" ]]; then
  FETCH_OUT="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$FETCH_OUT'" EXIT
  GITHUB_OUTPUT="$FETCH_OUT" bash "${SCRIPTS_DIR}/fetch-cachyos-source.sh" ${SRC_TAG:+"$SRC_TAG"}
  SRCDIR="$(sed -n 's/^srcdir=//p' "$FETCH_OUT" | head -n1)"
  trap - EXIT
  rm -f "$FETCH_OUT"
  if [[ -z "${SRCDIR:-}" ]]; then
    echo "error: fetch-cachyos-source.sh did not report srcdir." >&2
    exit 1
  fi
else
  SRCDIR="$EXISTING"
  echo "Source tree already present at ${SRCDIR} - skipping download."
fi

SRCDIR="${SRCDIR#./}"

# Derive major.minor for the kernel-patches series path.
# Handles stable (cachyos-7.2.0-1 -> 7.2) and RC (cachyos-7.2-rc7-1 -> 7.2).
BASE="${SRCDIR#cachyos-}"   # 7.2.0-1 / 7.2-rc7-1 / 6.18.42-1
BASE="${BASE%%-*}"           # 7.2.0 / 7.2 / 6.18.42
if [[ "$SRCDIR" == *"-rc"* ]]; then
  if [[ "$BASE" == *.*.* ]]; then
    MAJOR_MINOR="${BASE%.*}"
  else
    MAJOR_MINOR="$BASE"
  fi
else
  MAJOR_MINOR="${BASE%.*}"
fi
case "$MAJOR_MINOR" in
  [0-9]*.[0-9]*) : ;;
  *) echo "error: could not derive major.minor from '${SRCDIR}'." >&2; exit 1 ;;
esac
echo "series: ${MAJOR_MINOR} (from ${SRCDIR})"

# EXTRA_PATCHES: space-separated kernel-patches paths declared for this
# variant in config/variants.yml (mirrors its PKGBUILD source=() array).
# Exit 2 from apply-patches means drift (patch vs src_tag mismatch) and
# is propagated as a skipped cell, not a hard failure (see run-* wrappers
# and validate-patches.yml). The collector still writes provenance with
# skipped_reason.
# shellcheck disable=SC2086
if ! bash "${SCRIPTS_DIR}/apply-patches.sh" "$SRCDIR" "$MAJOR_MINOR" ${EXTRA_PATCHES:-}; then
  rc=$?
  if (( rc == 2 )); then
    echo "::warning::Skipping $SRCDIR: patch drift (series $MAJOR_MINOR vs $SRCDIR) — see provenance skipped_reason." >&2
    # Leave a marker for the cell wrapper to turn into a skipped fragment
    printf 'skipped_reason=drift: patch %s vs src %s (series %s)\n' "${EXTRA_PATCHES:-}" "$SRCDIR" "$MAJOR_MINOR" > "${WORKDIR}/skipped-reason.env" 2>/dev/null || true
    exit 2
  fi
  exit $rc
fi
KCONFIG_MODE="${KCONFIG_MODE:-generic}" \
bash "${SCRIPTS_DIR}/configure-kernel.sh" "$SRCDIR" "$PKGBUILD_DIR" "$SCHEDULER" "$ISA_NUM"
bash "${SCRIPTS_DIR}/ensure-rust-bindgen.sh" "$SRCDIR"

printf 'srcdir=%s\nmajor_minor=%s\n' "$SRCDIR" "$MAJOR_MINOR" >> "$OUT_FILE"
