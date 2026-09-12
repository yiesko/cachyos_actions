#!/usr/bin/env bash
# Sign every *.rpm under a directory with the project's dedicated GPG
# key, provided through GitHub Secrets. Designed to be a no-op fallback:
# if no key is configured the caller just ships SHA256SUMS instead.
#
# WHY A DEDICATED PROJECT KEY (not your personal one):
#   The private key must live in GitHub Secrets for CI to sign; a leaked
#   personal key lets someone impersonate *you* everywhere, while a
#   leaked project key only compromises this pipeline's packages.
#
# Env:
#   GPG_PRIVATE_KEY   armored private key (required to actually sign)
#   GPG_PASSPHRASE    optional; omit for a passphrase-less CI key
#                     (recommended: it lives in Secrets either way)
# Usage: sign-rpm.sh [dir-with-rpms]     default: ./out
set -euo pipefail

SIGN_DIR="${1:-out}"

if [[ -z "${GPG_PRIVATE_KEY:-}" ]]; then
  echo "sign-rpm: GPG_PRIVATE_KEY not set - skipping signing."
  echo "sign-rpm: Consumers should verify SHA256SUMS instead."
  exit 0
fi

command -v rpmsign >/dev/null 2>&1 || {
  # Release job hosts are ubuntu images without rpm tooling; install it.
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq rpm
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y rpm-build
  fi
}
command -v rpmsign >/dev/null 2>&1 || {
  echo "error: rpmsign not found even after install attempt." >&2
  exit 1
}

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "$GNUPGHOME"

gpg --batch --import <<< "$GPG_PRIVATE_KEY"
KEYID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^sec/{print $5; exit}')"
[[ -n "$KEYID" ]] || { echo "error: no secret key after import." >&2; exit 1; }
echo "sign-rpm: signing with key $KEYID"

SIGN_ARGS=(--addsign --define "_gpg_name $KEYID")
if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
  PWFILE="$GNUPGHOME/.passphrase"
  printf '%s' "$GPG_PASSPHRASE" > "$PWFILE"
  chmod 600 "$PWFILE"
  SIGN_ARGS+=(
    --define "__gpg /usr/bin/gpg"
    --define "_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file ${PWFILE}"
  )
fi

shopt -s nullglob
rpms=("$SIGN_DIR"/*.rpm)
shopt -u nullglob
(( ${#rpms[@]} )) || { echo "sign-rpm: no .rpm files in $SIGN_DIR." >&2; exit 1; }

for r in "${rpms[@]}"; do
  echo "sign-rpm: signing $(basename "$r") ..."
  rpmsign "${SIGN_ARGS[@]}" "$r"
done

gpg --armor --export "$KEYID" > "$SIGN_DIR/RPM-GPG-KEY-cachyos-ci.asc"

echo "sign-rpm: verifying signatures ..."
fail=0
for r in "${rpms[@]}"; do
  if rpm -qpi "$r" | grep -qi 'Signature.*Key ID'; then
    echo "OK: $(basename "$r")"
  else
    echo "FAIL: $(basename "$r") has no signature." >&2
    fail=1
  fi
done
exit "$fail"
