#!/usr/bin/env bash
# Collect one build cell's provenance fragment for the release manifest.
#
# Reads everything the prepare/build hooks recorded (fetch env, patch TSV,
# config env, upstream HEAD) plus live toolchain versions, and writes a
# single JSON file. Best-effort by design: every unknown becomes the
# string "unknown", and this script NEVER fails the build (callers add
# `|| true` as well).
#
# Usage: collect-cell-provenance.sh --out <fragment.json>
# Env (all optional except VARIANT):
#   VARIANT, PKGBUILD_DIR, SCHEDULER, ISA_NUM, ISA_LABEL, MARCH,
#   USE_LTO, SRC_TAG, KCONFIG_MODE, CACHY_CONFIG, PREEMPT_MODE, HZ_TICKS,
#   BUILDER_SUFFIX, LOCALVERSION, EXTRA_PATCHES, PKGBUILD_SHA,
#   LINUX_COMMIT, PATCHES_SHA, CELL_KIND (kbuild|arch), JOB_NAME,
#   SRCDIR (kbuild tree), UPSTREAM_DIR (arch clone), WORKDIR (fetch/patch
#   records), ARTIFACT_DIR (built packages), CELL_START_EPOCH.
set -uo pipefail

OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$OUT" ]] || { echo "usage: $0 --out <fragment.json>" >&2; exit 2; }

ver_of() {  # ver_of <cmd>... -> first line or unknown, never fails
  if command -v "$1" >/dev/null 2>&1; then
    ("$@" 2>/dev/null | head -n1) || echo "unknown"
  else
    echo "unknown"
  fi
}

env_val() {  # env_val <file> <key> -> value or "unknown", never fails
  # Reads KEY=value records without sourcing them (sourcing trips
  # SC1091, and sourcing inside $(...) trips SC2031 for every
  # variable used later; these files are written by our own hooks, and
  # /etc/os-release is data). One pair of surrounding double quotes is
  # stripped (os-release quotes its values; our own records never do).
  local file="$1" key="$2" line
  line="$(sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n1 || true)"
  line="${line%\"}"
  line="${line#\"}"
  if [[ -n "$line" ]]; then printf '%s' "$line"; else printf 'unknown'; fi
}

BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
NOW_EPOCH="$(date +%s 2>/dev/null || echo 0)"
DURATION_S="unknown"
if [[ "${CELL_START_EPOCH:-0}" =~ ^[0-9]+$ ]] && (( ${CELL_START_EPOCH:-0} > 0 )) && (( NOW_EPOCH > ${CELL_START_EPOCH:-0} )); then
  DURATION_S="$((NOW_EPOCH - ${CELL_START_EPOCH:-0}))"
fi

OS_PRETTY="unknown"
if [[ -f /etc/os-release ]]; then
  OS_PRETTY="$(env_val /etc/os-release PRETTY_NAME)"
fi
RUNNER_INFO="$(uname -srm 2>/dev/null || echo unknown)"
NPROC_VAL="$(nproc 2>/dev/null || echo unknown)"

GCC_VER="$(ver_of gcc --version)"
CLANG_VER="$(ver_of clang --version)"
RUSTC_VER="$(ver_of rustc --version)"
BINDGEN_VER="$(ver_of bindgen --version)"
MAKEPKG_VER="unknown"
if command -v makepkg >/dev/null 2>&1; then
  MAKEPKG_VER="$(makepkg --version 2>/dev/null | head -n1 || echo unknown)"
fi

KERNELRELEASE="unknown"
FINAL_CONFIG_SHA="unknown"
BASE_CONFIG_SHA="unknown"
if [[ -n "${SRCDIR:-}" && -d "${SRCDIR}" ]]; then
  if [[ -f "${SRCDIR}/.provenance-config.env" ]]; then
    KERNELRELEASE="$(env_val "${SRCDIR}/.provenance-config.env" KERNELRELEASE)"
    FINAL_CONFIG_SHA="$(env_val "${SRCDIR}/.provenance-config.env" FINAL_CONFIG_SHA256)"
    BASE_CONFIG_SHA="$(env_val "${SRCDIR}/.provenance-config.env" BASE_CONFIG_SHA256)"
  fi
  if [[ "$KERNELRELEASE" == "unknown" && -f "${SRCDIR}/Makefile" ]]; then
    KERNELRELEASE="$(make -C "${SRCDIR}" -s kernelrelease 2>/dev/null || echo unknown)"
  fi
  if [[ "$FINAL_CONFIG_SHA" == "unknown" && -f "${SRCDIR}/.config" ]] && command -v sha256sum >/dev/null 2>&1; then
    FINAL_CONFIG_SHA="$(sha256sum "${SRCDIR}/.config" | awk '{print $1}')"
  fi
fi

# Fetch record (written by fetch-cachyos-source.sh into WORKDIR).
TARBALL_SHA="unknown"; TARBALL_SIZE="unknown"; GPG_VERIFY="unknown"
ALLOW_UNVERIFIED="unknown"; TARBALL_URL="unknown"
if [[ -n "${WORKDIR:-}" && -f "${WORKDIR}/provenance-fetch.env" ]]; then
  TARBALL_SHA="$(env_val "${WORKDIR}/provenance-fetch.env" TARBALL_SHA256)"
  TARBALL_SIZE="$(env_val "${WORKDIR}/provenance-fetch.env" TARBALL_SIZE)"
  GPG_VERIFY="$(env_val "${WORKDIR}/provenance-fetch.env" GPG_VERIFY)"
  ALLOW_UNVERIFIED="$(env_val "${WORKDIR}/provenance-fetch.env" ALLOW_UNVERIFIED)"
  TARBALL_URL="$(env_val "${WORKDIR}/provenance-fetch.env" TARBALL_URL)"
fi

UPSTREAM_HEAD="unknown"
if [[ -n "${UPSTREAM_DIR:-}" && -d "${UPSTREAM_DIR}" ]]; then
  UPSTREAM_HEAD="$(git -C "${UPSTREAM_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
elif [[ -d upstream ]]; then
  UPSTREAM_HEAD="$(git -C upstream rev-parse HEAD 2>/dev/null || echo unknown)"
fi

ISA_LABEL_EFF="${ISA_LABEL:-}"
if [[ -z "$ISA_LABEL_EFF" ]]; then
  if [[ -n "${ISA_NUM:-}" ]]; then ISA_LABEL_EFF="v${ISA_NUM}"; else ISA_LABEL_EFF="unknown"; fi
fi

export PROV_OUT="$OUT" PROV_VARIANT="${VARIANT:-unknown}"
export PROV_PKGBUILD_DIR="${PKGBUILD_DIR:-unknown}" PROV_SCHEDULER="${SCHEDULER:-unknown}"
export PROV_ISA_NUM="${ISA_NUM:-unknown}" PROV_ISA_LABEL="$ISA_LABEL_EFF"
export PROV_MARCH="${MARCH:-unknown}" PROV_USE_LTO="${USE_LTO:-none}"
export PROV_SRC_TAG="${SRC_TAG:-unknown}" PROV_KCONFIG="${KCONFIG_MODE:-generic}"
export PROV_CACHY="${CACHY_CONFIG:-yes}" PROV_PREEMPT="${PREEMPT_MODE:-full}"
export PROV_HZ="${HZ_TICKS:-1000}" PROV_BUILDER="${BUILDER_SUFFIX:--yieskow}"
export PROV_LOCALVERSION="${LOCALVERSION:-unknown}"
export PROV_EXTRA_PATCHES="${EXTRA_PATCHES:-}"
export PROV_PKGBUILD_SHA="${PKGBUILD_SHA:-unknown}" PROV_LINUX_COMMIT="${LINUX_COMMIT:-unknown}"
export PROV_PATCHES_SHA="${PATCHES_SHA:-unknown}"
export PROV_CELL_KIND="${CELL_KIND:-kbuild}" PROV_JOB="${JOB_NAME:-unknown}"
export PROV_BUILT_AT="$BUILT_AT" PROV_DURATION="$DURATION_S"
export PROV_OS="$OS_PRETTY" PROV_RUNNER="$RUNNER_INFO" PROV_NPROC="$NPROC_VAL"
export PROV_GCC="$GCC_VER" PROV_CLANG="$CLANG_VER" PROV_RUSTC="$RUSTC_VER"
export PROV_BINDGEN="$BINDGEN_VER" PROV_MAKEPKG="$MAKEPKG_VER"
export PROV_KREL="$KERNELRELEASE" PROV_FINAL_CFG="$FINAL_CONFIG_SHA" PROV_BASE_CFG="$BASE_CONFIG_SHA"
export PROV_TARBALL_SHA="$TARBALL_SHA" PROV_TARBALL_SIZE="$TARBALL_SIZE"
export PROV_GPG_VERIFY="$GPG_VERIFY" PROV_ALLOW_UNVER="$ALLOW_UNVERIFIED"
export PROV_TARBALL_URL="$TARBALL_URL" PROV_UPSTREAM_HEAD="$UPSTREAM_HEAD"
export PROV_WORKDIR="${WORKDIR:-}" PROV_SRCDIR="${SRCDIR:-}" PROV_ARTDIR="${ARTIFACT_DIR:-}"
export PROV_SKIPPED="${SKIPPED_REASON:-}"

python3 - "$OUT" <<'PY' 2>/dev/null || true
import json, os, glob

def g(n, *args):
    # g(key) -> unknown or value; g(key, default) -> default when unset
    d = args[0] if args else "unknown"
    v = os.environ.get(n, d)
    return v if v != "" else d

patches = []
tsv = ""
wd = g("PROV_WORKDIR")
cands = []
if wd and wd != "unknown":
    cands.append(os.path.join(wd, "applied-patches.tsv"))
cands.append("applied-patches.tsv")
for c in cands:
    if c and os.path.isfile(c):
        tsv = c
        break
if tsv:
    try:
        with open(tsv) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 4 and parts[0]:
                    patches.append({"path": parts[0], "sha256": parts[1],
                                    "url": parts[2], "result": parts[3]})
    except OSError:
        pass
if not patches:
    raw = g("PROV_EXTRA_PATCHES", "")
    for p in raw.split():
        patches.append({"path": p, "sha256": "unknown", "url": "", "result": "unknown"})

artifacts = []
ad = g("PROV_ARTDIR")
if ad and ad != "unknown":
    for pat in ("*.rpm", "*.deb", "*.pkg.tar.zst"):
        try:
            for f in sorted(glob.glob(os.path.join(ad, pat))):
                try:
                    artifacts.append({"file": os.path.basename(f),
                                      "size": os.path.getsize(f)})
                except OSError:
                    artifacts.append({"file": os.path.basename(f), "size": -1})
        except Exception:
            pass

frag = {
    "variant": g("PROV_VARIANT"),
    "isa_label": g("PROV_ISA_LABEL"),
    "isa_num": g("PROV_ISA_NUM"),
    "cell_kind": g("PROV_CELL_KIND"),
    "job": g("PROV_JOB"),
    "src_tag": g("PROV_SRC_TAG"),
    "pkgbuild_dir": g("PROV_PKGBUILD_DIR"),
    "scheduler": g("PROV_SCHEDULER"),
    "march": g("PROV_MARCH"),
    "lto": g("PROV_USE_LTO"),
    "kconfig_mode": g("PROV_KCONFIG"),
    "cachy_config": g("PROV_CACHY"),
    "preempt": g("PROV_PREEMPT"),
    "hz": g("PROV_HZ"),
    "builder_suffix": g("PROV_BUILDER"),
    "localversion": g("PROV_LOCALVERSION"),
    "skipped_reason": g("PROV_SKIPPED", ""),
    "upstream": {
        "pkgbuild_sha": g("PROV_PKGBUILD_SHA"),
        "linux_commit": g("PROV_LINUX_COMMIT"),
        "patches_sha": g("PROV_PATCHES_SHA"),
        "upstream_head": g("PROV_UPSTREAM_HEAD"),
    },
    "source": {
        "tarball_sha256": g("PROV_TARBALL_SHA"),
        "tarball_size": g("PROV_TARBALL_SIZE"),
        "tarball_url": g("PROV_TARBALL_URL"),
        "gpg_verify": g("PROV_GPG_VERIFY"),
        "allow_unverified": g("PROV_ALLOW_UNVER"),
    },
    "patches": patches,
    "config": {
        "base_sha256": g("PROV_BASE_CFG"),
        "final_sha256": g("PROV_FINAL_CFG"),
        "kernelrelease": g("PROV_KREL"),
    },
    "toolchain": {
        "gcc": g("PROV_GCC"), "clang": g("PROV_CLANG"),
        "rustc": g("PROV_RUSTC"), "bindgen": g("PROV_BINDGEN"),
        "makepkg": g("PROV_MAKEPKG"),
    },
    "runner": {"os": g("PROV_OS"), "uname": g("PROV_RUNNER"), "nproc": g("PROV_NPROC")},
    "built_at_utc": g("PROV_BUILT_AT"),
    "duration_s": g("PROV_DURATION"),
    "artifacts": artifacts,
}
import sys
with open(sys.argv[1], "w") as f:
    json.dump(frag, f, indent=2, sort_keys=True)
    f.write("\n")
PY
[[ -s "$OUT" ]] || echo '{"variant":"'"${VARIANT:-unknown}"'","error":"collector-failed"}' > "$OUT"
echo "provenance fragment: $OUT"
