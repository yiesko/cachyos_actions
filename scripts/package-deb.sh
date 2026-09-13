#!/usr/bin/env bash
# Package one already-configured kernel tree as a .deb, using
# kbuild's own bindeb-pkg target (ships in every kernel source tree -
# no separate debian/ packaging directory to maintain by hand). This
# is the honest reality of Debian/Ubuntu here: CachyOS doesn't
# publish .debs themselves, so this is us building straight from the
# same patched+configured source the Arch job uses, via Debian's own
# native kernel-packaging path rather than trying to repackage an
# Arch build artifact (which would fight both toolchains' conventions
# for module locations, initramfs hooks, postinst scripts, etc).
#
# Expects configure-kernel.sh to have already run against $SRCDIR.
#
# Required env: VARIANT, SCHEDULER, MARCH, ISA, SRCDIR
set -euo pipefail

: "${VARIANT:?}"; : "${SCHEDULER:?}"; : "${MARCH:?}"; : "${ISA:?}"; : "${SRCDIR:?}"
: "${GITHUB_WORKSPACE:?}"

cd "$SRCDIR"

KVER="$(make -s kernelversion)"
# LTO flavor suffix: keeps ThinLTO/Full .debs unambiguous next to the
# default-compiler ones in the same release (same rule the CI matrix uses
# for status filenames: "" for none, "-<lto>" otherwise).
case "${USE_LTO:-none}" in
  none) LTO_SUFFIX="" ;;
  thin|thin-dist|full) LTO_SUFFIX="-${USE_LTO}" ;;
  *) echo "unknown USE_LTO value: ${USE_LTO:-}" >&2; exit 1 ;;
esac
# Builder tag: brands uname -r / package versions as this project's builds
# (e.g. 7.2.4-cachyos-bore-v2-yieskow). MUST stay lowercase: dpkg rejects
# uppercase in package names ([a-z0-9][-+.:a-z0-9]+) and only tells you
# after the full compile. Override with BUILDER_SUFFIX="" or your own
# (lowercase) tag; empty disables. NOTE: Arch packages cannot carry this
# (makepkg uses the upstream PKGBUILD unmodified by design).
# NOTE: ${VAR-default} (no colon) so that BUILDER_SUFFIX="" truly
# disables instead of falling back to the default. Bare `yieskow`
# auto-becomes `-yieskow` (shared rule with run-kbuild-build.sh and
# resolve-custom-build.py, weekly comme custom); empty stays empty.
BUILDER_SUFFIX="${BUILDER_SUFFIX--yieskow}"
if [[ -n "$BUILDER_SUFFIX" && "$BUILDER_SUFFIX" != [-+._]* ]]; then
  BUILDER_SUFFIX="-$BUILDER_SUFFIX"
fi
export LOCALVERSION="-${VARIANT}-${ISA}${LTO_SUFFIX}${BUILDER_SUFFIX}"
export KDEB_PKGVERSION="${KVER}${LOCALVERSION}-1"
export KCFLAGS="-march=${MARCH}"
export KCPPFLAGS="-march=${MARCH}"
export KBUILD_BUILD_HOST="cachyos-ci"
export KBUILD_BUILD_USER="${VARIANT}"

# USE_LTO=thin|thin-dist|full -> build with the LLVM toolchain so the
# LTO_CLANG_* config options selected by configure-kernel.sh actually
# apply (kbuild needs clang/lld, not just the .config bits).
MAKE_ARGS=(-j"$(nproc)")
if [[ "${USE_LTO:-none}" != "none" ]]; then
  MAKE_ARGS+=(LLVM=1)
fi

echo "Building .deb for ${VARIANT} (${ISA}, ${MARCH}), kernel ${KVER}, lto=${USE_LTO:-none} ..."
make "${MAKE_ARGS[@]}" bindeb-pkg

mkdir -p "${GITHUB_WORKSPACE}/out"
# bindeb-pkg drops the .deb files one directory above the source tree
# (older kbuild) or inside it. Collect deterministically with nullglob
# so a no-match expands to nothing instead of the literal "*.deb",
# and fail loudly when nothing was produced.
shopt -s nullglob
deb_candidates=(../*.deb ./*.deb)
shopt -u nullglob
if (( ${#deb_candidates[@]} == 0 )); then
  echo "error: bindeb-pkg produced no .deb files (checked ../*.deb and ./*.deb from ${SRCDIR})." >&2
  exit 1
fi
mv -v "${deb_candidates[@]}" "${GITHUB_WORKSPACE}/out/"

shopt -s nullglob
staged=("${GITHUB_WORKSPACE}"/out/*.deb)
shopt -u nullglob
if (( ${#staged[@]} == 0 )); then
  echo "error: no .deb files staged in ${GITHUB_WORKSPACE}/out after bindeb-pkg." >&2
  exit 1
fi
echo "package-deb: staged ${#staged[@]} .deb file(s)."
