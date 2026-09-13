#!/usr/bin/env bash
# Download the exact kernel source tarball CachyOS's own PKGBUILDs build
# from - an upstream-stable base plus CachyOS's own topic branches
# (amd-pstate, bbr3, cachy, cgroup-vram, drm-fair, fixes, hdmi, mglru,
# preempt-ipi, sched-cluster, snd-codecs, t2, vesa-dsc-bpp, ...) -
# released as a signed tag on https://github.com/CachyOS/linux. This is
# the same tarball the source=() array of every linux-cachyos*/PKGBUILD
# points at, so using it keeps the Debian/Fedora builds on the same base
# as the Arch build instead of drifting onto plain kernel.org sources.
#
# VERIFIED FACTS (checked against CachyOS's repos, Aug 2026):
# - Release tags look like  cachyos-7.2.0-1   (stable, full x.y.z-rel)
#   or                      cachyos-7.2-rc7-1  (release candidates).
#   This matters: an earlier revision of this script assumed
#   "cachyos-<maj.min>-<rel>" (e.g. cachyos-7.2-1), which does NOT exist
#   and 404s. The PKGBUILDs build the name as
#   _srcname="cachyos-${_major}.${_minor}-${_tagrel}".
# - Every release ships two assets: <tag>.tar.gz and <tag>.tar.gz.asc.
# - Signing keys are declared in validpgpkeys=() of
#   linux-cachyos*/PKGBUILD (both listed below).
#
# Only used by the kbuild (.deb+.rpm) job (and CI patch dry-runs).
# The build-arch job doesn't need this - makepkg resolves its own
# source=() array.
#
# Usage:
#   fetch-cachyos-source.sh              resolve + fetch latest stable
#   fetch-cachyos-source.sh <tag>        explicit tag, e.g. cachyos-7.2.0-1
#
# Environment:
#   ALLOW_UNVERIFIED=1   downgrade a failed/missing GPG verification to a
#                        warning instead of aborting. NOT recommended;
#                        keyservers are flaky, but so is trusting an
#                        unverified 250 MB blob.
#   GITHUB_TOKEN         optional; used for API pagination auth to avoid
#                        unauthenticated rate limits on busy runners.
set -euo pipefail

API="https://api.github.com/repos/CachyOS/linux"
BASE="https://github.com/CachyOS/linux/releases/download"
STABLE_TAG_RE='^cachyos-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$'

# CDN 500-storms under 70+ parallel cells are real (observed Sep 2026):
# curl's default tiny backoff gives up in seconds. Retry longer with
# capped total time instead. --retry-all-errors needs curl >= 7.71
# (2020); every runner/container here is far newer.
FETCH_RETRY=(--retry 8 --retry-delay 10 --retry-max-time 300 --retry-all-errors)

gh_curl() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL "${FETCH_RETRY[@]}" -H "Authorization: Bearer ${GITHUB_TOKEN}" "$@"
  else
    curl -fsSL "${FETCH_RETRY[@]}" "$@"
  fi
}

resolve_latest_stable() {
  local json tag=""
  echo "Resolving latest stable CachyOS/linux release ..." >&2
  # Releases are listed newest-first; pick the first whose tag matches
  # the stable naming scheme (this inherently skips -rcN tags).
  json="$(gh_curl "${API}/releases?per_page=100")" || return 1
  tag="$(printf '%s' "$json" \
    | grep -o '"tag_name": *"[^"]*"' \
    | cut -d '"' -f4 \
    | grep -E "$STABLE_TAG_RE" \
    | head -n1 || true)"
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "$tag"
}

if [[ $# -ge 1 && -n "${1:-}" ]]; then
  TAG="$1"
else
  if ! TAG="$(resolve_latest_stable)"; then
    echo "error: could not resolve the latest stable release tag." >&2
    echo "       Pass one explicitly, e.g.: $0 cachyos-7.2.0-1" >&2
    exit 1
  fi
fi

SRCNAME="$TAG"
echo "Fetching ${SRCNAME}.tar.gz ..."
curl -fL "${FETCH_RETRY[@]}" -o "${SRCNAME}.tar.gz"     "${BASE}/${SRCNAME}/${SRCNAME}.tar.gz"
curl -fL "${FETCH_RETRY[@]}" -o "${SRCNAME}.tar.gz.asc" "${BASE}/${SRCNAME}/${SRCNAME}.tar.gz.asc"

# Signing keys exactly as declared in validpgpkeys=() in
# linux-cachyos-bore/PKGBUILD (verified Aug 2026). If verification fails
# because these rotated, check the current PKGBUILD on GitHub for the
# up-to-date key list before assuming the tarball itself is bad.
KEYS=(
  E18447AC260021D31F3FF6C4C8A2A4774B8B63C4  # Eric Naim <dnaim@cachyos.org>
  E8B9AA39F054E30E8290D492C3C4820857F654FE  # Peter Jung <admin@ptr1337.dev>
)
keys_ok=1
for KEY in "${KEYS[@]}"; do
  # Storm-proof: keyservers hiccup under CI bursts and strict mode aborts
  # the whole cell on a missing key — retry both servers before giving up.
  fetched=0
  for attempt in 1 2 3; do
    # --batch + timeout: without them gpg can hang until the runner
    # timeout on filtered HKP networks, with diagnostics suppressed.
    if gpg --batch --keyserver-options timeout=15 \
        --keyserver keyserver.ubuntu.com --recv-keys "$KEY" 2>&1 \
      || gpg --batch --keyserver-options timeout=15 \
        --keyserver keys.openpgp.org --recv-keys "$KEY" 2>&1; then
      fetched=1
      break
    fi
    if (( attempt < 3 )); then
      echo "warning: key $KEY fetch failed (attempt $attempt/3), retrying ..." >&2
      sleep $((attempt * 10))
    fi
  done
  if (( fetched )); then
    echo "fetched key $KEY"
  else
    echo "warning: could not fetch key $KEY from either keyserver" >&2
    keys_ok=0
  fi
done

unverified_msg=(
  "GPG verification FAILED for ${SRCNAME}.tar.gz."
  "A signature that cannot be checked is not a trusted signature."
)
allow="${ALLOW_UNVERIFIED:-0}"
if [[ "$allow" == "1" || "$allow" == "true" || "$allow" == "yes" ]]; then
  VERIFY_STRICT=0
elif [[ -z "$allow" || "$allow" == "0" ]]; then
  VERIFY_STRICT=1
else
  echo "error: ALLOW_UNVERIFIED='$allow' is invalid (use 1/true/yes or unset)." >&2
  exit 2
fi

verify_failed=0
if (( keys_ok == 0 )); then
  verify_failed=1
  unverified_msg+=("Root cause: none of the signing keys could be fetched.")
fi
if ! gpg --verify "${SRCNAME}.tar.gz.asc" "${SRCNAME}.tar.gz" 2>gpg-verify.log; then
  verify_failed=1
  unverified_msg+=("gpg output:")
  unverified_msg+=("$(cat gpg-verify.log)")
fi
rm -f gpg-verify.log

if (( verify_failed )); then
  if (( VERIFY_STRICT )); then
    printf '%s\n' "${unverified_msg[@]}" >&2
    echo "Aborting. Set ALLOW_UNVERIFIED=1 only if you understand what you are skipping." >&2
    exit 1
  fi
  printf '::warning::%s\n' "${unverified_msg[@]}" >&2
  echo "::warning::Proceeding UNVERIFIED because ALLOW_UNVERIFIED=1 - don't ship these" \
       "artifacts anywhere you wouldn't ship an unverified random kernel." >&2
  GPG_VERIFY="UNVERIFIED"
else
  echo "GPG signature verified OK."
  GPG_VERIFY="OK"
fi

# Provenance record for the release manifest (best-effort, never fatal):
# tarball identity + verification outcome. Written next to the tarball
# (the cell WORKDIR) so prepare-kernel-source.sh and the cell collector
# can pick it up later.
{
  echo "SRC_TAG=${SRCNAME}"
  if command -v sha256sum >/dev/null 2>&1 && [[ -f "${SRCNAME}.tar.gz" ]]; then
    echo "TARBALL_SHA256=$(sha256sum "${SRCNAME}.tar.gz" | awk '{print $1}')"
  else
    echo "TARBALL_SHA256=unknown"
  fi
  if [[ -f "${SRCNAME}.tar.gz" ]]; then
    # stat -c works on GNU coreutils (ubuntu runners + containers).
    echo "TARBALL_SIZE=$(stat -c %s "${SRCNAME}.tar.gz" 2>/dev/null || echo unknown)"
  else
    echo "TARBALL_SIZE=unknown"
  fi
  echo "GPG_VERIFY=${GPG_VERIFY:-UNKNOWN}"
  echo "ALLOW_UNVERIFIED=${allow}"
  echo "GPG_KEYS=E18447AC260021D31F3FF6C4C8A2A4774B8B63C4,E8B9AA39F054E30E8290D492C3C4820857F654FE"
  echo "TARBALL_URL=${BASE}/${SRCNAME}/${SRCNAME}.tar.gz"
} > "provenance-fetch.env" 2>/dev/null || true

echo "Extracting ..."
tar xf "${SRCNAME}.tar.gz"

echo "srcdir=${SRCNAME}" >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "Source ready at: ${SRCNAME}/"
