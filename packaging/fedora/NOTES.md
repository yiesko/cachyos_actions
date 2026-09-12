# Fedora packaging notes

`scripts/package-rpm.sh` uses kbuild's built-in `binrpm-pkg` target, which
is enough to get a working, installable `.rpm` but skips everything a
"real" Fedora kernel package does beyond that: `%post`/`%postun`
scriptlets that call `kernel-install`, weak-updates module symlinks,
proper `Provides:`/`Obsoletes:` for kernel-devel style subpackages, etc.

If you want to go further than "it boots", the best reference is the spec
file actually used to build CachyOS kernels for Fedora today:
[CachyOS/copr-linux-cachyos](https://github.com/CachyOS/copr-linux-cachyos),
maintained by packager `bieszczaders` and published via COPR as
`bieszczaders/kernel-cachyos` (GCC builds) and
`bieszczaders/kernel-cachyos-lto` (LLVM ThinLTO builds). That repo already
solves the packaging-metadata problem this pipeline doesn't attempt to —
worth diffing your spec against theirs rather than writing one from
scratch.

Note their COPR docs are explicit about a hardware floor: **x86-64-v3
minimum for all kernels except `kernel-cachyos-lts` and
`kernel-cachyos-server`, which only need x86-64-v2** — the same
`min_isa` idea `config/variants.yml` uses in this repo, just enforced at
install time via `Requires:` there instead of at build-matrix time here.

## Toolchain facts (verified Aug 2026)

- CachyOS's shipped per-variant `config` sets `CONFIG_RUST=y`; inside the
  fedora container this is satisfied with distro packages
  (`dnf install rust cargo clang rust-bindgen`) — see
  `scripts/ensure-rust-bindgen.sh`.
- The ISA level is selected with the same knobs CachyOS's PKGBUILD uses:
  `-e GENERIC_CPU --set-val X86_64_VERSION N`. Those options exist only
  in CachyOS-patched sources (their own Kconfig patch), which is exactly
  what this pipeline builds.
- The weekly pipeline can optionally publish the produced `.rpm`s as a
  browsable DNF repository on GitHub Pages (enable `publish_repo` on a
  manual dispatch). Metadata is signed when the project GPG key secrets
  are configured; otherwise the repo ships with `gpgcheck=0` and
  consumers should verify `SHA256SUMS` instead. A real Fedora kernel
  package (weak-updates, kernel-install scriptlets, Secure Boot-friendly
  layout) remains future work — diff against the COPR spec first.

## Secure Boot

Out of scope by design: kernels and modules produced here ship unsigned.
Whether/how to sign them is entirely up to each user — if you boot with
Secure Boot enabled, handle signing and MOK enrollment yourself using
whatever workflow you prefer (mokutil, sbctl, pesign, ...). This repo
deliberately does not prescribe, automate, or ship keys for that.

