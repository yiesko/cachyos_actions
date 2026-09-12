# Debian/Ubuntu packaging notes

`scripts/package-deb.sh` uses kbuild's built-in `bindeb-pkg` target. It
produces a genuinely installable `linux-image-*` / `linux-headers-*` pair
(`dpkg -i` works), but it's a generic kernel.org-style package, not a
Debian-Kernel-Team-style one: no `initramfs-tools` trigger integration
beyond what `bindeb-pkg` already wires up, no `linux-image-cachyos`
metapackage that tracks the latest build, no separate `-dbg` package
split out.

There is no official CachyOS `.deb` anywhere to use as a reference the way
Fedora's `copr-linux-cachyos` spec exists for RPM — Debian/Ubuntu support
is genuinely DIY here. A few concrete next steps if `bindeb-pkg` output
isn't enough:

- Wrap the output in a small metapackage (`equivs` or a hand-rolled
  `control` file) named e.g. `linux-image-cachyos-bore-v3`, so `apt`
  has something stable to track across weekly version bumps instead of a
  new package name every run.
- Look at how Ubuntu's own `linux-generic`/`linux-generic-hwe-*`
  metapackages are structured for the naming/versioning convention users
  will find familiar.
- If you want this installable from a real `apt` repository (not just
  `dpkg -i` on a downloaded release asset), `reprepro` is the standard
  tool for turning a folder of `.deb` files into a signed APT repo — that
  wiring isn't set up in this pipeline yet (see the README's
  "Known limitations" section).

## Toolchain facts (verified Aug 2026)

- CachyOS's shipped per-variant `config` sets `CONFIG_RUST=y`, so the
  build needs `rustc`, `cargo`, `bindgen` and the Rust core sources.
  `scripts/run-deb-build.sh` handles this via `scripts/ensure-rust-bindgen.sh`
  (rustup stable + `cargo install --locked bindgen-cli`; apt's packaged
  rustc/bindgen are too old for current kernels).
- The ISA level is selected with the same knobs CachyOS's PKGBUILD uses:
  `-e GENERIC_CPU --set-val X86_64_VERSION N`. Those options exist only
  in CachyOS-patched sources (their own Kconfig patch), which is exactly
  what this pipeline builds.

## Secure Boot

Out of scope by design: kernels and modules produced here ship unsigned.
Whether/how to sign them is entirely up to each user — if you boot with
Secure Boot enabled, handle signing and MOK enrollment yourself using
whatever workflow you prefer. This repo deliberately does not prescribe,
automate, or ship keys for that.

