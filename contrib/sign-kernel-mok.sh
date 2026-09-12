#!/usr/bin/env bash
#
# sign-kernel-mok.sh — sign an installed kernel (vmlinuz + modules) with
# your own Machine Owner Key (MOK) so it boots under Secure Boot.
#
# Companion example for the UNSIGNED kernels published by this repo's
# releases (see README, "Secure Boot" section). Contributed from a real
# Fedora 44 + Secure Boot + TPM2 (PCR 7) + LUKS setup.
#
# Fedora-focused (dnf package names, /boot + /lib/modules layout, sbsigntools
# + mokutil + openssl); other distros need small adaptations — community
# PRs welcome.
#
# Besides signing, it detects your CPU's highest x86-64 level (v1..v4) and
# refuses a kernel built above it (e.g. a -v4 kernel on a v2 CPU would fault
# on boot) — the release's -vN suffix is compared automatically.
#
# Usage:
#   sudo bash contrib/sign-kernel-mok.sh [options] <kernel-version>
#
#   <kernel-version>   e.g. 7.2.4-cachyos-bore-v2  (see /lib/modules)
#
# Options:
#   --mok-dir DIR      where MOK.priv/MOK.pem/MOK.der live
#                      (default: /etc/pki/cachyos-mok; generated if missing)
#   --sign-file PATH   kernel scripts/sign-file binary
#                      (default: autodetect from installed kernel-devel,
#                      else <moddir>/build/scripts/sign-file)
#   --jobs N           parallel signing jobs (default: nproc, capped at 8)
#   --check            audit only: report signature status, change nothing
#                      (does not need root, only readable vmlinuz/modules)
#   --enroll           also run `mokutil --import` at the end; you still
#                      confirm in the blue MOK Manager screen on next boot
#   --force            re-sign even if this key already signed this kernel
#   -h, --help         show this help
#
# Typical first run (one password prompt for the whole script):
#   sudo bash contrib/sign-kernel-mok.sh --enroll 7.2.4-cachyos-bore-v2
#   sudo systemctl reboot   # Enroll MOK in MOK Manager, then boot the kernel
#
# If your LUKS unlock is sealed in TPM2 against PCR 7, the new MOK changes
# PCR 7: re-enroll the TPM2 token AFTER the MOK enrollment, e.g.:
#   sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/XXX
#   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7:sha1 /dev/XXX
# (keep a LUKS passphrase in a slot as fallback before touching TPM2.)
#
set -euo pipefail

MOKDIR="/etc/pki/cachyos-mok"
SIGN_FILE=""
JOBS=0
CHECK=0
ENROLL=0
FORCE=0
KVER=""

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while (($#)); do
  case "$1" in
    --mok-dir)   MOKDIR="${2:?}"; shift 2 ;;
    --sign-file) SIGN_FILE="${2:?}"; shift 2 ;;
    --jobs)      JOBS="${2:?}"; shift 2 ;;
    --check)     CHECK=1; shift ;;
    --enroll)    ENROLL=1; shift ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   usage 0 ;;
    --*)         echo "error: unknown option $1" >&2; usage 1 ;;
    *)           KVER="$1"; shift ;;
  esac
done
[ -n "$KVER" ] || { echo "error: missing <kernel-version> (see /lib/modules)" >&2; usage 1; }

MODDIR="${MODDIR_OVERRIDE:-/lib/modules/$KVER}"
VMLINUZ="${VMLINUZ_OVERRIDE:-/boot/vmlinuz-$KVER}"
[ -d "$MODDIR" ] || { echo "error: $MODDIR not found - is kernel $KVER installed?" >&2; exit 1; }
[ -f "$VMLINUZ" ] || { echo "error: $VMLINUZ not found" >&2; exit 1; }
# (MODDIR_OVERRIDE/VMLINUZ_OVERRIDE exist only to test the ISA guard below.)

cpu_max_isa() {
  # Highest x86-64 microarchitecture level this CPU can execute (1..4).
  local ld lvl
  for ld in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2; do
    if [ -x "$ld" ]; then
      # NOTE: match "(supported" right after the version — a bare
      # "x86-64-v4" line means UNSUPPORTED, and the 4 in "x86-64" itself
      # must not leak into the result (hence sed, not grep -o '[234]').
      lvl="$("$ld" --help 2>/dev/null | sed -n 's/^ *x86-64-v\([234]\) (supported.*$/\1/p' | sort -n | tail -n 1)"
      if [ -n "$lvl" ]; then echo "$lvl"; return 0; fi
    fi
  done
  # Fallback: parse CPU flags directly.
  local flags
  flags="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)" || { echo 1; return 0; }
  has() { grep -qw "$1" <<<"$flags"; }
  if has avx512f && has avx512bw && has avx512cd && has avx512dq && has avx512vl; then echo 4; return 0; fi
  if has avx && has avx2 && has bmi1 && has bmi2 && has fma && has osxsave \
    && has movbe && { has abm || has lzcnt; }; then echo 3; return 0; fi
  if has cx16 && has lahf_lm && has popcnt && has sse4_1 && has sse4_2 && has ssse3; then echo 2; return 0; fi
  echo 1
}

KVER_ISA=1
if [[ "$KVER" =~ -v([1-4])$ ]]; then
  KVER_ISA="${BASH_REMATCH[1]}"
fi
CPU_ISA="$(cpu_max_isa)"
echo "--- CPU executes up to x86-64-v$CPU_ISA; kernel targets x86-64-v$KVER_ISA ---"
if (( KVER_ISA > CPU_ISA )); then
  echo "error: kernel $KVER needs x86-64-v$KVER_ISA but this CPU stops at v$CPU_ISA - it would fault on boot. Pick a -v$CPU_ISA (or lower) build." >&2
  exit 1
fi

if (( JOBS <= 0 )); then
  JOBS="$(nproc 2>/dev/null || echo 4)"
  (( JOBS > 8 )) && JOBS=8
fi

MOKPRIV="$MOKDIR/MOK.priv"
MOKPEM="$MOKDIR/MOK.pem"
MOKDER="$MOKDIR/MOK.der"

count_sigs() {
  # Number of appended module-signature trailers in a module file.
  if [ "$1" != "${1%.zst}" ]; then
    zstd -dc -- "$1" 2>/dev/null | grep -ac "Module signature appended" || true
  elif [ "$1" != "${1%.xz}" ]; then
    xz -dc -- "$1" 2>/dev/null | grep -ac "Module signature appended" || true
  elif [ "$1" != "${1%.gz}" ]; then
    gzip -dc -- "$1" 2>/dev/null | grep -ac "Module signature appended" || true
  else
    grep -ac "Module signature appended" -- "$1" 2>/dev/null || echo 0
  fi
}
export -f count_sigs

audit_tree() {
  # Prints: total unsigned single doubleplus (space-separated counts)
  local total=0 unsigned=0 single=0 multi=0 n
  while IFS= read -r -d '' m; do
    total=$((total + 1))
    n="$(count_sigs "$m")"
    if (( n == 0 )); then unsigned=$((unsigned + 1));
    elif (( n == 1 )); then single=$((single + 1));
    else multi=$((multi + 1)); fi
  done < <(find "$MODDIR" \( -name '*.ko' -o -name '*.ko.zst' -o -name '*.ko.xz' -o -name '*.ko.gz' \) -print0)
  echo "$total $unsigned $single $multi"
}

audit_vmlinuz() {
  # Exit 0 + print status word: SIGNED / UNSIGNED / UNKNOWN(no cert/tool)
  if [ -r "$MOKPEM" ] && command -v sbverify >/dev/null 2>&1; then
    if sbverify --cert "$MOKPEM" "$VMLINUZ" >/dev/null 2>&1; then
      echo "SIGNED"; return 0
    fi
    echo "UNSIGNED"; return 1
  fi
  echo "UNKNOWN"; return 2
}

if (( CHECK )); then
  echo "--- audit (read-only) for kernel $KVER ---"
  read -r total unsigned single multi < <(audit_tree)
  echo "modules: total=$total unsigned=$unsigned single-sig=$single double-sig+=$multi"
  echo "vmlinuz: $(audit_vmlinuz || true)"
  echo "(single-sig usually = factory/build-time key; double-sig+ = factory + your MOK)"
  exit 0
fi

(( EUID == 0 )) || { echo "error: run as root (sudo bash $0 ...)" >&2; exit 1; }
for cmd in openssl sbsign sbverify depmod; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: missing tool: $cmd" >&2; exit 1; }
done
if (( ENROLL )); then
  command -v mokutil >/dev/null 2>&1 || { echo "error: missing tool: mokutil" >&2; exit 1; }
fi

# --- MOK keypair (generate once, reuse forever) ---
if [ ! -f "$MOKPRIV" ] || [ ! -f "$MOKDER" ]; then
  echo "--- generating new MOK in $MOKDIR ( protect MOK.priv! ) ---"
  mkdir -p "$MOKDIR"
  chmod 700 "$MOKDIR"
  openssl req -new -x509 -newkey rsa:2048 \
    -keyout "$MOKPRIV" -out "$MOKPEM" \
    -nodes -days 3650 -subj "/CN=$(hostname) kernel signing/"
  openssl x509 -in "$MOKPEM" -outform DER -out "$MOKDER"
else
  echo "--- reusing existing MOK in $MOKDIR ---"
  [ -f "$MOKPEM" ] || openssl x509 -in "$MOKDER" -inform DER -out "$MOKPEM"
fi
# Private key must never be group/world-readable, however it got there.
chmod 700 "$MOKDIR"
chmod 600 "$MOKPRIV"
FPRINT="$(openssl x509 -in "$MOKDER" -inform DER -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | cut -c1-16)"
openssl x509 -in "$MOKDER" -inform DER -noout -subject
MARKER="$MODDIR/.mok-signed-$FPRINT"

# --- sign-file discovery ---
# NOTE: installing kernel-devel via dnf is NOT recommended on Fedora — it
# upgrades (replaces) the stock -devel packages instead of coexisting.
# Extract it once to your own durable dir (plain user commands, no sudo
# needed; NOT /tmp — tmpfs, wiped on reboot) and this autodetect finds it
# (root reads user homes fine):
#   mkdir -p ~/.local/share/cachyos-kernels
#   cd ~/.local/share/cachyos-kernels
#   rpm2cpio <kernel-devel-$KVER...rpm> | cpio -idmv ./usr/src/kernels/$KVER/scripts/sign-file
# Invoking user's home (under sudo, $HOME is /root — resolve the real user).
INVOKER_HOME="${HOME:-/root}"
if [ -n "${SUDO_USER:-}" ]; then
  _invoker="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  if [ -n "$_invoker" ] && [ -d "$_invoker" ]; then INVOKER_HOME="$_invoker"; fi
fi
USER_SIGN_DIR="$INVOKER_HOME/.local/share/cachyos-kernels"
if [ -z "$SIGN_FILE" ]; then
  for cand in "/usr/src/kernels/$KVER/scripts/sign-file" "$MODDIR/build/scripts/sign-file" "$USER_SIGN_DIR/usr/src/kernels/$KVER/scripts/sign-file" "/root/cachyos-sign/usr/src/kernels/$KVER/scripts/sign-file"; do
    if [ -x "$cand" ]; then SIGN_FILE="$cand"; break; fi
  done
fi
[ -n "$SIGN_FILE" ] && [ -x "$SIGN_FILE" ] || {
  echo "error: scripts/sign-file not found." >&2
  echo "  Either install the matching kernel-devel/headers package, or extract" >&2
  echo "  it once (as your user, durable path) and re-run (or pass --sign-file):" >&2
  echo "    mkdir -p ~/.local/share/cachyos-kernels && cd ~/.local/share/cachyos-kernels" >&2
  echo "    rpm2cpio <kernel-devel-$KVER...rpm> | cpio -idmv ./usr/src/kernels/$KVER/scripts/sign-file" >&2
  exit 1
}
echo "--- sign-file: $SIGN_FILE ---"

# --- vmlinuz (keep the pristine copy on first run) ---
# NOTE: guarded by the same key marker as the modules below — without it,
# every re-run would APPEND another signature to an already-signed vmlinuz.
SIGNED_ALREADY=0
if [ -f "$MARKER" ] && (( ! FORCE )); then
  echo "--- marker $MARKER exists: already signed with this key, verifying only (use --force to redo) ---"
  sbverify --cert "$MOKPEM" "$VMLINUZ" && echo "VMLINUZ-OK"
  SIGNED_ALREADY=1
else
  if [ ! -f "$VMLINUZ.unsigned" ]; then
    cp -v "$VMLINUZ" "$VMLINUZ.unsigned"
  fi
  echo "--- signing $VMLINUZ ---"
  sbsign --key "$MOKPRIV" --cert "$MOKPEM" --output "$VMLINUZ" "$VMLINUZ.unsigned"
  sbverify --cert "$MOKPEM" "$VMLINUZ" && echo "VMLINUZ-OK"
fi

# --- modules (append our signature wherever it is missing) ---
if (( SIGNED_ALREADY )); then
  echo "--- modules: skipped (marker present, use --force to redo) ---"
else
  for ext in zst xz gz; do
    case "$ext" in
      zst) tool=zstd ;; xz) tool=xz ;; gz) tool=gzip ;;
    esac
    # NOTE: probe the TOOL name (zstd), not the extension (zst).
    command -v "$tool" >/dev/null 2>&1 && continue
    if find "$MODDIR" -name "*.ko.$ext" -print -quit | grep -q .; then
      echo "error: modules compressed with .$ext but '$tool' not installed" >&2
      exit 1
    fi
  done
  do_one() {
    local f="$1" plain="$1" decomp=0
    if [ "$(count_sigs "$f")" -ge 2 ]; then
      return 0
    fi
    case "$f" in
      *.zst) zstd -d --rm -q -- "$f" || return 1; plain="${f%.zst}"; decomp=1 ;;
      *.xz)  xz -d -q -- "$f" || return 1; plain="${f%.xz}"; decomp=1 ;;
      *.gz)  gzip -d -q -- "$f" || return 1; plain="${f%.gz}"; decomp=1 ;;
    esac
    "$SIGN_FILE" sha256 "$MOKPRIV" "$MOKDER" "$plain" || return 1
    if (( decomp )); then
      case "$f" in
        *.zst) zstd -q --rm -- "$plain" || return 1 ;;
        *.xz)  xz -q -- "$plain" || return 1; rm -f -- "$plain" ;;
        *.gz)  gzip -q -- "$plain" || return 1; rm -f -- "$plain" ;;
      esac
    fi
  }
  export -f do_one
  export SIGN_FILE MOKPRIV MOKDER MODDIR
  total=$(find "$MODDIR" \( -name '*.ko' -o -name '*.ko.zst' -o -name '*.ko.xz' -o -name '*.ko.gz' \) | wc -l)
  echo "--- signing $total modules ($JOBS parallel) ---"
  find "$MODDIR" \( -name '*.ko' -o -name '*.ko.zst' -o -name '*.ko.xz' -o -name '*.ko.gz' \) -print0 \
    | xargs -0 -P "$JOBS" -I{} bash -c 'do_one "$1"' _ {}
  echo "sign loop rc=$?"
  left=$(find "$MODDIR" -name '*.ko' | wc -l)
  # NOTE: a loose *.ko remainder is only fatal if such files did not exist
  # before (all stock trees ship compressed). Report, do not guess.
  echo "loose .ko files remaining: $left"
  echo "$FPRINT" > "$MARKER"
  chmod 644 "$MARKER"
fi

# --- final audit: zero unsigned modules allowed ---
read -r total unsigned single multi < <(audit_tree)
echo "--- audit: total=$total unsigned=$unsigned single-sig=$single double-sig+=$multi ---"
(( unsigned == 0 )) || { echo "error: $unsigned module(s) without any signature" >&2; exit 1; }
depmod -a "$KVER" && echo DEPMOD-OK

if (( ENROLL )); then
  echo "--- requesting MOK enrollment (confirm in MOK Manager on next boot) ---"
  mokutil --import "$MOKDER"
  echo "Reboot, choose Enroll MOK in the blue screen, then boot the signed kernel."
  echo "If LUKS is TPM2-sealed to PCR 7, re-enroll it afterwards (PCR 7 changes)."
fi
echo "DONE for kernel $KVER"
