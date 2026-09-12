#!/usr/bin/env bash
# Package one already-configured kernel tree as an .rpm, using
# kbuild's binrpm-pkg target (binary rpm only, via `rpmbuild -bb`;
# use the slower `rpm-pkg` target instead if you also want a
# redistributable src.rpm).
#
# NOTE: CachyOS-flavoured kernels DO already exist for Fedora, just
# not from this pipeline - Fedora packager bieszczaders maintains
# COPR repos (bieszczaders/kernel-cachyos and -lto) built from
# CachyOS-PKGBUILDS via a dedicated spec file. That's a more polished
# reference than kbuild's generic binrpm-pkg target if you want to
# take this further (proper %post scriptlets, kernel-install
# integration, weak-updates symlinks, etc.) - worth reading before
# you rely on this script's output as more than "it boots".
#
# Expects configure-kernel.sh to have already run against $SRCDIR.
#
# Required env: VARIANT, SCHEDULER, MARCH, ISA, SRCDIR
set -euo pipefail

: "${VARIANT:?}"; : "${SCHEDULER:?}"; : "${MARCH:?}"; : "${ISA:?}"; : "${SRCDIR:?}"
: "${GITHUB_WORKSPACE:?}"

cd "$SRCDIR"

# Same LTO flavor suffix rule as package-deb.sh (kbuild's binrpm-pkg turns
# dashes into underscores, so -thin/-full survive into the .rpm names).
case "${USE_LTO:-none}" in
  none) LTO_SUFFIX="" ;;
  thin|thin-dist|full) LTO_SUFFIX="-${USE_LTO}" ;;
  *) echo "unknown USE_LTO value: ${USE_LTO:-}" >&2; exit 1 ;;
esac
# Same builder tag as package-deb.sh (shows in uname -r; kbuild turns the
# dashes into underscores in .rpm names). Lowercase to match the .deb
# constraint even though RPM would tolerate uppercase. Arch path cannot
# carry it.
# NOTE: ${VAR-default} (no colon) so that BUILDER_SUFFIX="" truly
# disables instead of falling back to the default.
BUILDER_SUFFIX="${BUILDER_SUFFIX--yieskow}"
export LOCALVERSION="-${VARIANT}-${ISA}${LTO_SUFFIX}${BUILDER_SUFFIX}"
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

echo "Building .rpm for ${VARIANT} (${ISA}, ${MARCH}), lto=${USE_LTO:-none} ..."
make "${MAKE_ARGS[@]}" binrpm-pkg

mkdir -p "${GITHUB_WORKSPACE}/out"
# Where the RPMs land depends on how kbuild invoked rpmbuild: recent
# kernels define _topdir INSIDE the source tree (<SRCDIR>/rpmbuild),
# older setups use the user default ($HOME/rpmbuild). Collect from both.
# NOTE: only search roots that actually exist - passing a missing dir to
# find makes it exit non-zero and, under `set -e`, kills an otherwise
# successful build (observed: 38/38 kbuild cells failed AFTER binrpm-pkg
# wrote all 3 RPMs, on run 34116624066).
RPM_ROOTS=()
for candidate in "$SRCDIR/rpmbuild/RPMS" "$HOME/rpmbuild/RPMS"; do
  if [[ -d "$candidate" ]]; then
    RPM_ROOTS+=("$candidate")
  else
    echo "package-rpm: skipping missing RPM root: $candidate" >&2
  fi
done
if (( ${#RPM_ROOTS[@]} == 0 )); then
  echo "error: no RPM output directory exists (checked ${SRCDIR}/rpmbuild/RPMS and \$HOME/rpmbuild/RPMS)." >&2
  echo "binrpm-pkg either failed silently or changed its _topdir layout." >&2
  exit 1
fi
find "${RPM_ROOTS[@]}" -name '*.rpm' -exec cp -v {} "${GITHUB_WORKSPACE}/out/" \;

shopt -s nullglob
staged=("${GITHUB_WORKSPACE}"/out/*.rpm)
shopt -u nullglob
if (( ${#staged[@]} == 0 )); then
  echo "error: binrpm-pkg produced no .rpm files (searched: ${RPM_ROOTS[*]})." >&2
  exit 1
fi
echo "package-rpm: staged ${#staged[@]} .rpm file(s)."
ls -lh "${GITHUB_WORKSPACE}/out/"
