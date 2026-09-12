#!/usr/bin/env bash
# Ensure a working Rust + bindgen toolchain IF the configured kernel
# actually needs it.
#
# VERIFIED FACT (Aug 2026): the per-variant `config` file CachyOS ships
# next to every PKGBUILD sets CONFIG_RUST=y. kbuild therefore needs
# rustc, cargo, bindgen and the Rust core sources on the deb/rpm build
# paths - the Arch/makepkg path doesn't need this script because the
# PKGBUILD's own makedepends pull them in.
#
# Strategy per distro family:
#   - Fedora: distro packages (dnf install rust cargo clang rust-bindgen)
#     - coherent, prebuilt, fast.
#   - Debian/Ubuntu: rustup (stable) + `cargo install --locked bindgen-cli`
#     - apt's rustc/bindgen are too old for current kernels; rustup is
#       what the kernel docs themselves recommend for development builds.
#
# Usage: ensure-rust-bindgen.sh <srcdir>
set -euo pipefail

SRCDIR="${1:?usage: ensure-rust-bindgen.sh <srcdir>}"

if [[ ! -f "${SRCDIR}/.config" ]]; then
  echo "error: ${SRCDIR}/.config not found - run configure-kernel.sh first." >&2
  exit 1
fi
if ! grep -q '^CONFIG_RUST=y' "${SRCDIR}/.config"; then
  echo "CONFIG_RUST is not enabled - no Rust toolchain needed."
  exit 0
fi

echo "CONFIG_RUST=y detected - ensuring rustc/cargo/bindgen/core sources ..."

have() { command -v "$1" >/dev/null 2>&1; }

# Persist a PATH entry for the CALLER too: `export` below dies with this
# script, so append to $GITHUB_PATH when running under Actions (observed
# bug: "Rust toolchain ready" printed, then `make` failed to find rustc).
persist_path() {
  local dir="$1"
  case ":${PATH}:" in
    *":${dir}:"*) : ;;
    *) export PATH="${dir}:${PATH}" ;;
  esac
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$dir" >> "$GITHUB_PATH"
    echo "Persisted ${dir} to \$GITHUB_PATH for later steps."
  else
    echo "NOTE: export RUSTUP_HOME/CARGO path manually in the parent shell:" >&2
    echo "      export PATH=\"${dir}:\$PATH\"" >&2
  fi
}

if have dnf; then
  dnf install -y rust cargo clang rust-bindgen
elif have apt-get; then
  if ! have rustc || ! have cargo; then
    curl -fsSL --retry 3 --retry-delay 5 https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
    persist_path "${HOME}/.cargo/bin"
  fi
  if have rustup; then
    rustup component add rust-src
  else
    echo "warning: rustup not found - cannot install rust-src component; hoping distro rustc ships it." >&2
  fi
  # bindgen must match what the kernel expects; a current release built
  # from crates.io is the safest bet against moving kernel requirements.
  if ! have bindgen; then
    cargo install --locked bindgen-cli
    persist_path "${HOME}/.cargo/bin"
  fi
else
  cat >&2 <<'EOF'
error: CONFIG_RUST=y but this is neither a dnf nor apt system and no
Rust toolchain detection exists here. Install rustc, cargo, bindgen
and the rust core sources manually before building.
EOF
  exit 1
fi

# Fail now with a clear message instead of 40 minutes into the compile.
for tool in rustc cargo bindgen; do
  have "$tool" || { echo "error: '$tool' still missing after setup." >&2; exit 1; }
done

echo "Rust toolchain ready:"
rustc --version || true
bindgen --version || true

# Kernel-sanctioned check: verifies rustc/bindgen versions AND rust-src.
if ! make -C "$SRCDIR" rustavailable; then
  echo "error: 'make rustavailable' failed - Rust toolchain unusable for this tree." >&2
  exit 1
fi
echo "make rustavailable: OK"
