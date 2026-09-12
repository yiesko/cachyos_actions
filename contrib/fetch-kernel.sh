#!/usr/bin/env bash
#
# fetch-kernel.sh — download kernel packages from this repo's releases
# WITHOUT the gh CLI: public GitHub API + curl only (no login needed).
#
# Fedora-focused (default format autodetected from /etc/os-release);
# picking --format by hand works anywhere curl + python3 exist.
#
# Usage:
#   bash contrib/fetch-kernel.sh [options] <variant> [isa]
#
#   variant: cachyos | cachyos-bore | cachyos-eevdf | cachyos-rt-bore |
#            cachyos-lts | cachyos-hardened | cachyos-server |
#            cachyos-deckify | cachyos-rc
#   isa: v1..v4 (default: highest your CPU supports; asking above it
#        is refused — the build would fault on boot)
#
# Options:
#   --format rpm|deb|arch   package family (default: autodetect distro)
#   --release TAG           release tag (default: latest stable release)
#   --repo OWNER/REPO       (default: yiesko/cachyos_actions)
#   --dir DIR               target dir (default: ./cachyos-<variant>-<isa>)
#   --list                  only print URLs + checksums, download nothing
#   --no-verify             skip SHA256/MD5 verification
#   -h, --help
#
# Examples:
#   bash contrib/fetch-kernel.sh cachyos-bore        # rpm v2 on a v2 CPU
#   bash contrib/fetch-kernel.sh --format deb cachyos-eevdf v3
#   bash contrib/fetch-kernel.sh --list cachyos-lts v4
#
# What you get (rpm example): kernel / kernel-devel / kernel-headers
# + SHA256SUMS + MD5SUMS, all hash-verified. Pair with
# contrib/sign-kernel-mok.sh if you boot with Secure Boot.
#
set -euo pipefail

REPO="yiesko/cachyos_actions"
RELEASE_TAG=""
FORMAT=""
TARGET_DIR=""
LIST_ONLY=0
VERIFY=1
VARIANT=""
ISA=""

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }

while (($#)); do
  case "$1" in
    --format)  FORMAT="${2:?}"; shift 2 ;;
    --release) RELEASE_TAG="${2:?}"; shift 2 ;;
    --repo)    REPO="${2:?}"; shift 2 ;;
    --dir)     TARGET_DIR="${2:?}"; shift 2 ;;
    --list)    LIST_ONLY=1; shift ;;
    --no-verify) VERIFY=0; shift ;;
    -h|--help) usage 0 ;;
    --*)       echo "error: unknown option $1" >&2; usage 1 ;;
    *)         if [ -z "$VARIANT" ]; then VARIANT="$1"; else ISA="$1"; fi; shift ;;
  esac
done

case "$VARIANT" in
  cachyos|cachyos-bore|cachyos-eevdf|cachyos-rt-bore|cachyos-lts|cachyos-hardened|cachyos-server|cachyos-deckify|cachyos-rc) : ;;
  *) echo "error: unknown variant '$VARIANT' (see --help)" >&2; exit 1 ;;
esac

for cmd in curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: missing tool: $cmd" >&2; exit 1; }
done
if (( VERIFY && ! LIST_ONLY )); then
  for cmd in sha256sum md5sum; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "error: missing tool: $cmd (or pass --no-verify)" >&2; exit 1; }
  done
fi

cpu_max_isa() {
  # Same detection as contrib/sign-kernel-mok.sh (ld.so first, flags fallback).
  local ld lvl
  for ld in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2; do
    if [ -x "$ld" ]; then
      lvl="$("$ld" --help 2>/dev/null | sed -n 's/^ *x86-64-v\([234]\) (supported.*$/\1/p' | sort -n | tail -n 1)"
      if [ -n "$lvl" ]; then echo "$lvl"; return 0; fi
    fi
  done
  local flags
  flags="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)" || { echo 1; return 0; }
  has() { grep -qw "$1" <<<"$flags"; }
  if has avx512f && has avx512bw && has avx512cd && has avx512dq && has avx512vl; then echo 4; return 0; fi
  if has avx && has avx2 && has bmi1 && has bmi2 && has fma && has osxsave \
    && has movbe && { has abm || has lzcnt; }; then echo 3; return 0; fi
  if has cx16 && has lahf_lm && has popcnt && has sse4_1 && has sse4_2 && has ssse3; then echo 2; return 0; fi
  echo 1
}

CPU_ISA="$(cpu_max_isa)"
if [ -z "$ISA" ]; then
  ISA="v$CPU_ISA"
  echo "--- no ISA given: using highest this CPU supports ($ISA) ---"
fi
[[ "$ISA" =~ ^v[1-4]$ ]] || { echo "error: isa must be v1..v4 (got '$ISA')" >&2; exit 1; }
ISA_NUM="${ISA#v}"
if (( ISA_NUM > CPU_ISA )); then
  echo "error: $ISA needs x86-64-$ISA but this CPU stops at v$CPU_ISA - it would fault on boot." >&2
  exit 1
fi

if [ -z "$FORMAT" ]; then
  # shellcheck disable=SC1091
  OS_ID="$(. /etc/os-release 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}")"
  case "$OS_ID" in
    *fedora*|*rhel*|*centos*|*suse*) FORMAT=rpm ;;
    *debian*|*ubuntu*|*mint*|*pop*)             FORMAT=deb ;;
    *arch*|*endeavouros*|*manjaro*|*garuda*|*cachyos*) FORMAT=arch ;;
    *) echo "error: cannot autodetect distro from '$OS_ID' - pass --format rpm|deb|arch" >&2; exit 1 ;;
  esac
  echo "--- distro suggests format: $FORMAT (override with --format) ---"
fi
case "$FORMAT" in rpm|deb|arch) : ;; *) echo "error: --format must be rpm|deb|arch" >&2; exit 1 ;; esac

[ -z "$TARGET_DIR" ] && TARGET_DIR="./cachyos-$VARIANT-$ISA"

echo "--- resolving release ($([ -n "$RELEASE_TAG" ] && echo "$RELEASE_TAG" || echo "latest stable") in $REPO) ---"
ASSETS="$(python3 - "$REPO" "$RELEASE_TAG" "$VARIANT" "$ISA" "$FORMAT" <<'PYEOF'
import json, re, sys, urllib.error, urllib.request
repo, tag, variant, isa, fmt = sys.argv[1:6]
url = (f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
       if tag else f"https://api.github.com/repos/{repo}/releases/latest")
req = urllib.request.Request(url, headers={"User-Agent": "cachyos-fetch-script",
                                            "Accept": "application/vnd.github+json"})
try:
    rel = json.load(urllib.request.urlopen(req, timeout=30))
except urllib.error.HTTPError as e:
    if e.code == 404:
        sys.exit(f"error: release '{tag or 'latest'}' not found in {repo}")
    if e.code == 403:
        sys.exit("error: GitHub API rate limit hit (60 req/h unauthenticated) - wait a bit or set GITHUB_TOKEN (not used by this script by design)")
    sys.exit(f"error: GitHub API HTTP {e.code} for {url}")
except urllib.error.URLError as e:
    sys.exit(f"error: cannot reach api.github.com ({e.reason}) - check network/DNS")
print(f"# {rel['tag_name']}", file=sys.stderr)
V, I = re.escape(variant), re.escape(isa)
# NOTE: kbuild's binrpm-pkg rewrites dashes to underscores in rpm versions
# (rpm forbids '-'), so cachyos-bore ships as ..._cachyos_bore_v2-...;
# deb/arch names keep the dashes. The optional tail covers flavor/builder
# suffixes (e.g. _thin, _yieskoW) while still matching older suffix-less
# releases.
TAIL_RPM = r"(_[A-Za-z0-9]+)*"
TAIL_DEB = r"(-[A-Za-z0-9]+)?"
Vr = re.escape(variant.replace("-", "_"))
pats = []
if fmt == "rpm":
    pats = [re.compile(rf"^kernel-(devel-|headers-)?[^_]*_{Vr}_{I}{TAIL_RPM}-\d.*\.rpm$")]
elif fmt == "deb":
    pats = [re.compile(rf"^linux-(image|headers|libc-dev)-.*-{V}-{I}{TAIL_DEB}_.*\.deb$")]
else:  # arch: v1 has no -vN suffix, v2+ does
    suf = "" if isa == "v1" else f"-{I}"
    pats = [re.compile(rf"^linux-{V}(-headers)?-\d.*-x86_64{suf}\.pkg\.tar\.zst$")]
wanted = []
for a in rel.get("assets", []):
    if any(p.match(a["name"]) for p in pats):
        wanted.append(f"{a['name']}\t{a['browser_download_url']}")
for s in ("SHA256SUMS", "MD5SUMS"):
    for a in rel.get("assets", []):
        if a["name"] == s:
            wanted.append(f"{a['name']}\t{a['browser_download_url']}")
print("\n".join(wanted))
PYEOF
)"
echo "$ASSETS" | sed 's/\t.*//;s/^/  /' | head -n 20

if (( LIST_ONLY )); then
  echo "--- URLs (nothing downloaded) ---"
  echo "$ASSETS" | cut -f2-
  exit 0
fi

# Sanity: a kernel family is never a single file (kernel+devel+headers, …).
NFILES="$(echo "$ASSETS" | grep -c -v -e SHA256SUMS -e MD5SUMS || true)"
if (( NFILES < 2 )); then
  echo "error: only $NFILES package file(s) matched - refusing (wrong variant/isa/format?)" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
echo "--- downloading $NFILES package(s) + checksums to $TARGET_DIR ---"
while IFS=$'\t' read -r name url; do
  [ -n "$name" ] || continue
  echo "GET $name"
  curl -fsSL --retry 3 --retry-delay 2 --remove-on-error -o "$TARGET_DIR/$name" "$url"
done <<<"$ASSETS"

if (( VERIFY )); then
  echo "--- verifying ---"
  ( cd "$TARGET_DIR" && sha256sum -c SHA256SUMS --ignore-missing )
  ( cd "$TARGET_DIR" && md5sum -c MD5SUMS --ignore-missing )
fi
echo "DONE: files in $TARGET_DIR"
