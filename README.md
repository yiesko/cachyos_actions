# CachyOS kernel build automation for GitHub Actions

[![Weekly build](https://github.com/yiesko/cachyos_actions/actions/workflows/weekly-build.yml/badge.svg)](https://github.com/yiesko/cachyos_actions/actions/workflows/weekly-build.yml)
[![Validate](https://github.com/yiesko/cachyos_actions/actions/workflows/validate-patches.yml/badge.svg)](https://github.com/yiesko/cachyos_actions/actions/workflows/validate-patches.yml)
[![Latest release](https://img.shields.io/github/v/release/yiesko/cachyos_actions?display_name=tag&label=release)](https://github.com/yiesko/cachyos_actions/releases)

Automated weekly builds of [CachyOS-flavoured Linux kernels](https://github.com/CachyOS/linux-cachyos)
across every x86-64 microarchitecture level (v1/v2/v3/v4), packaged for
**Arch**, **Debian/Ubuntu** and **Fedora** — powered by GitHub Actions,
published as installable GitHub Releases.

- **What:** reproducible CI that tracks CachyOS upstream and rebuilds every
  kernel variant from their live sources — **not a kernel fork**, nothing
  vendored here. This repo owns only the build matrix and its glue scripts.
- **For whom:** anyone who wants CachyOS kernels **outside Arch** — Fedora
  (RPM), Debian/Ubuntu (.deb), older CPUs (a real x86-64-v2 tier upstream
  doesn't ship), or full-matrix automation in general.
- **Why not the official options?** CachyOS's [Kernel Manager](https://github.com/CachyOS/wiki/blob/next/src/content/docs/features/kernel_manager.mdx)
  is interactive and Arch-only; the [COPR](https://github.com/CachyOS/copr-linux-cachyos)
  covers Fedora from x86-64-v3 up. This adds unattended weekly rebuilds,
  v1/v2 tiers, Debian packages, and per-variant upstream tracking.
- **Produces:** ready-to-install `kernel` + `devel`/`headers` (RPM),
  `linux-image` + `linux-headers` (.deb) and Arch `pkg.tar.zst` — with
  `SHA256SUMS` + `MD5SUMS` and a per-cell build report in every release.

## What does this actually produce?

```text
CachyOS source → variant definition → patch validation → kernel config
       → kernel build (34 Arch + 82 kbuild cells, incl. ThinLTO/Full extras) → RPM / DEB / Arch
       → checksums + per-cell report in a stable GitHub Release
```

**Just want a kernel?** Pick your ISA below, grab the files from the
[latest release](../../releases/latest), verify, install — no clone needed.
Prefer the terminal? `contrib/fetch-kernel.sh` does download + verify for
you (no `gh` login needed).

---

## Downloading and installing a kernel

Grab artifacts from the [Releases page](../../releases) (weekly stable
releases tagged `weekly-N`). Each release contains packages for every
variant × ISA level × distro combination, plus `SHA256SUMS` + `MD5SUMS`.

### 1. Pick your ISA level

```sh
/lib64/ld-linux-x86-64.so.2 --help | grep supported
```

Lines listing `(supported, searched)` show what your CPU runs. When in
doubt choose **v3** (any CPU from ~2013+). v2 exists because some older
hardware deserves the CachyOS patches too — CachyOS itself doesn't ship
a v2 tier; building it is one of this project's reasons to exist.

### 2. Pick a variant

All nine enabled upstream flavours are built by default
(`cachyos-bmq` is currently disabled — see its row below):

| Variant | Scheduler | Base series | Notes |
|---|---|---|---|
| `cachyos` | pure EEVDF | main (7.2.x) | flagship |
| `cachyos-bore` | BORE | main | classic gaming/latency pick |
| `cachyos-eevdf` | EEVDF | main | explicitly named plain build |
| `cachyos-bmq` | BMQ | main | Project C; no sched-ext — **disabled** (`enabled: false` in `config/variants.yml`): its `sched/0001-prjc-cachy.patch` (7.2 series) stopped applying on `cachyos-7.2.4-1`, and CachyOS's own PKGBUILD fails identically. Re-enable once upstream's patch applies cleanly again. |
| `cachyos-rt-bore` | BORE + PREEMPT_RT | main | low-latency/real-time |
| `cachyos-lts` | pure EEVDF | **LTS (6.18.x)** | needs only v2 |
| `cachyos-hardened` | BORE + hardening | **7.1.x** | its patches live on that series |
| `cachyos-server` | EEVDF, lazy preemption | main | `CONFIG_CACHY` off, 300 Hz tick, like upstream; needs only v2 |
| `cachyos-deckify` | BORE | main | Steam Deck / handheld patches included |
| `cachyos-rc` | pure EEVDF | current `-rcN` cycle | churns weekly by design |

Every variant is reproduced against **its own source series tag**, resolved
live from that folder's PKGBUILD — not from the flagship's. Patch sets are
declared per variant too, mirroring exactly what each upstream PKGBUILD's
`source=()` array adds (they genuinely differ: the flagship applies *no*
scheduler patch for its default, deckify applies BORE for the same
scheduler value, and so on).

That yields 34 ISA-level combinations (38 minus the 4 disabled BMQ
cells) across 2 build jobs — 34 Arch cells + 82 kbuild cells (incl. 48
ThinLTO/Full extras for the 6 desktop variants: cachyos, bore, eevdf,
rt-bore, deckify, rc) ≈ **116 builds per week** — sized for a
public repo's unlimited Linux minutes.

### 3. Install

Verify first: every asset is covered by `SHA256SUMS` (and `MD5SUMS`);
if the repo has GPG signing configured there will also be signed RPMs
and a `RPM-GPG-KEY-cachyos-ci.asc` public key.

```sh
sha256sum -c SHA256SUMS --ignore-missing  # the file covers the whole
                                          # release: missing = not downloaded, not corrupt
```

### Verifying a release (veracity · trust · origin)

Every release (weekly or custom) ships a `provenance.json` manifest next
to the packages — the machine-readable backing for every claim in the
release notes. Verify any sentence there against it:

| Claim in the notes | Where to check it |
|---|---|
| Variant / scheduler / base tag | `variants.<id>.src_tag` + per-cell `pkgbuild_dir`, `scheduler` |
| Exact upstream commits | `variants.<id>.linux_commit` (`CachyOS/linux` tag), `.pkgbuild_sha` (`linux-cachyos` PKGBUILD), `.patches_sha` (`kernel-patches` series); per-cell `upstream.upstream_head` for Arch cells |
| “GPG-verified” source | per-cell `source`: tarball URL + `tarball_sha256` + `gpg_verify` outcome. Keys are CachyOS's published ones, as declared in the upstream PKGBUILD `validpgpkeys`: `E18447AC…B63C4` (Eric Naim) and `E8B9AA39…654FE` (Peter Jung). Verification is strict — a failed check aborts the cell |
| Patches applied | per-cell `patches[]`: exact `kernel-patches` path + SHA256 + result. Note: patches are served over TLS, not GPG-signed upstream |
| Kernel config | per-cell `config`: base/final `.config` SHA256 + `kernelrelease` + toggles (scheduler, ISA, HZ, preempt, LTO) |
| Toolchain / runner | per-cell `toolchain` (gcc/clang/rustc/bindgen) + `runner` + `built_at_utc` |
| Which file came from which cell | per-cell `artifacts[]` + top-level `artifacts[]` (name, SHA256, size) |
| Build outcome per cell | `statuses` (`ok` / `fail:<step>`) + `cells[]` detail |

Honest limits (also stated in each release): Arch cells build via
`makepkg --skippgpcheck`, so the GPG tarball guarantee covers the
kbuild (`.deb`/`.rpm`) path; kernels ship **unsigned** (self-sign for
Secure Boot); `SHA256SUMS` proves integrity only as far as you trust
the release publication itself.

**Fedora**

```sh
sudo dnf install ./kernel-*v3*.rpm   # kernel + devel + headers for your ISA
# SELinux only, needed once so modules can load:
sudo setsebool -P domain_kernel_load_modules on
```
(If you only want the kernel and keep stock `-devel`/`-headers`
untouched, install just `./kernel-...rpm` — see "Updating" below.)

**Debian / Ubuntu**

```sh
sudo dpkg -i ./linux-image-*.deb ./linux-headers-*.deb
```

**Arch**

```sh
sudo pacman -U ./linux-cachyos-*.pkg.tar.zst
```

Then reboot. Keep your stock kernel installed as a fallback boot entry.

> **These kernels are unsupported and UNSIGNED.** Don't use them on
> machines you care about without understanding what you're installing.
> If you boot with **Secure Boot enabled**, the kernel won't start unless
> *you* sign it and enroll your own key (mokutil/sbctl/pesign — your
> choice; this project deliberately stays out of that).

### Secure Boot with your own MOK (contrib example)

`contrib/sign-kernel-mok.sh` is a worked example from a real Fedora 44 +
Secure Boot + TPM2 (PCR 7) + LUKS setup: it generates a MOK (once),
signs the installed `vmlinuz` (`sbsign`) plus every module (`sign-file`,
handling `.ko.zst`/`.xz`/plain), runs `depmod`, and can audit (`--check`)
or request enrollment (`--enroll`, confirmed in MOK Manager on next boot).
It also detects your CPU's x86-64 level and refuses a kernel built above
it. Fedora-focused; other distros are welcome to adapt it.

```sh
sudo bash contrib/sign-kernel-mok.sh --enroll 7.2.4-cachyos-bore-v2
sudo systemctl reboot   # Enroll MOK in the blue screen
```

Two things it won't do for you: re-enroll TPM2-sealed LUKS (next
subsection) and repeat the signing for every new weekly kernel you install
(the MOK itself is reused — see "Updating" below).

#### TPM2-sealed LUKS (PCR 7 survives kernels, not MOK changes)

Enrolling a MOK appends to `MokList`, which Secure Boot measures into
**PCR 7** — so a LUKS token sealed to PCR 7 stops matching and the next
boot asks for your passphrase. This happens **once per MOK enrollment**,
not per kernel: weekly kernel updates don't touch any PCR.

1. Before enrolling, record the baseline and check how you're sealed:
   ```sh
   sudo tpm2_pcrread sha1:7,14 | tee ~/pcr-before.txt
   sudo systemd-cryptenroll /dev/XXX        # look for slot `tpm2`
   sudo cryptsetup luksDump /dev/XXX | grep -A3 systemd-tpm2  # tpm2-hash-pcrs / tpm2-pcr-bank
   ```
   Ours was PCRs `7`, bank `sha1`. **Match your existing bank** when
   re-enrolling — newer systemd versions default to `sha256`, which would
   silently change your policy. (`--tpm2-pcrs` syntax varies by version;
   `7:sha1` worked on systemd 257/Fedora 44 — check
   `man systemd-cryptenroll` if yours differs.)
2. Enroll the MOK, reboot, type the passphrase if asked (expected, once).
3. Compare: `diff <(cat ~/pcr-before.txt) <(sudo tpm2_pcrread sha1:7,14)`.
   If PCR 7 changed, re-enroll each sealed disk:
   ```sh
   sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/XXX
   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7:sha1 /dev/XXX
   sudo systemd-cryptenroll /dev/XXX   # slot tpm2 must be back
   ```
4. The following boot should unlock automatically again. Keep a passphrase
   slot forever — it's the recovery path whenever a PCR policy breaks
   (firmware update, key enrollment, toggling Secure Boot).

### Downloading without the `gh` CLI (contrib example)

`contrib/fetch-kernel.sh` downloads a variant × ISA from the releases using
only the public GitHub API + `curl` (no login needed). It autodetects your
distro's format (`rpm`/`deb`/`arch`) and your CPU's x86-64 level, verifies
SHA256 + MD5, and refuses an ISA above what your CPU executes:

```sh
bash contrib/fetch-kernel.sh cachyos-bore          # auto ISA + format
bash contrib/fetch-kernel.sh --format deb cachyos-eevdf v3
bash contrib/fetch-kernel.sh --list cachyos-lts v4  # only print URLs
```

### Updating to a new weekly kernel (same repo)

Releases land weekly as stable `weekly-N`. MOK enrollment and TPM2
sealing are one-time — per new version you only redo fetch + install +
sign (the `sign-file` helper is per kernel version: re-extract it when the
script's error hint asks):

```sh
bash contrib/fetch-kernel.sh cachyos-bore          # verified, right ISA
cd cachyos-cachyos-bore-v2/
sudo dnf install ./kernel-<ver>_...rpm             # kernel ONLY: -devel/-headers replace stock ones
KVER=$(ls /lib/modules | grep cachyos | sort -V | tail -1); echo "$KVER"
sudo bash /path/to/repo/contrib/sign-kernel-mok.sh "$KVER"
sudo systemctl reboot  # pick it in GRUB; keep a stock entry as fallback
```

---

## How it works

```
generate-matrix   reads config/*.yml, resolves CachyOS's current kernel version live
      │
      ├──▶ build-arch    archlinux container · makepkg · CachyOS's own unmodified PKGBUILD ─┐
      └──▶ build-kbuild  ubuntu host · one compile, kbuild bindeb-pkg + binrpm-pkg passes ├─▶ release
                                                                                               (+ optional GPG signing)
                                                                                               └─▶ optional DNF repo on GitHub Pages (experimental: Pages is not enabled yet)
validate-patches.yml  PR gate: shellcheck + patch dry-runs per scheduler, no compiling
```

- One matrix cell per enabled variant × ISA level; all three packaging
  jobs consume the same matrix, so all distros get identical sources.
- Freshness gate runs first: resolved source tags are compared against
  `versions.json` from the latest stable release; unchanged weeks skip
  the builds (see "Running this pipeline yourself").
- Source tarball is fetched by release tag (e.g. `cachyos-7.2.0-1`) and
  **GPG-verified against CachyOS's published keys** — verification fails
  hard by default.
- Scheduler patches come from [`cachyos/kernel-patches`](https://github.com/cachyos/kernel-patches)
  at build time using the exact same mapping as upstream PKGBUILDs.
- Kernel configuration replicates upstream's `prepare()` toggles
  (scheduler, ISA level via `_processor_opt=generic_vN`, 1000 Hz, THP…).
- Optional Clang ThinLTO/Full (`lto_variants`, default: the 6 desktop
  variants `cachyos,cachyos-bore,cachyos-eevdf,cachyos-rt-bore,cachyos-deckify,cachyos-rc`)
  as extra kbuild cells next to the GCC ones, suffixed `-thin`/`-full` (plus your
  builder tag, e.g. `7.2.4-cachyos-v3-thin-yieskow` in `uname -r`); the
  legacy `build_lto=true` flips the whole kbuild run to ThinLTO instead.
  The Arch path always builds at each PKGBUILD's own authentic LTO default
  (its static `b2sums` array pins the source set, so overriding would
  break integrity checking). AutoFDO/Propeller cannot be replicated in
  CI at any distro — those require perf profiles collected from real
  workloads on upstream's infrastructure.

---

## Running this pipeline yourself

Dispatch `.github/workflows/weekly-build.yml` manually or let the weekly
cron run it:

| Input | Meaning |
|---|---|
| `variants` | comma-separated ids (blank = all enabled), e.g. `cachyos-bore` |
| `isa_levels` | comma-separated levels, e.g. `v2,v3` (blank = all) |
| `build_lto` | Clang ThinLTO for ALL kbuild cells (slower, memory-hungry; legacy whole-run mode) |
| `lto_variants` | Variants gaining extra ThinLTO+Full kbuild cells alongside GCC (default: `cachyos,cachyos-bore,cachyos-eevdf,cachyos-rt-bore,cachyos-deckify,cachyos-rc`; Arch excluded — makepkg pins LTO per PKGBUILD) |
| `builder_suffix` | Builder tag in `uname -r` (default `-yieskow`; blank = none; bare `yieskow` auto-becomes `-yieskow`; kbuild-only, Arch ignores) |
| `publish_repo` | publish RPMs as a browsable DNF repo on GitHub Pages |
| `force_rebuild` | bypass the freshness gate (rebuild even if unchanged) |

**Freshness gate:** before burning ~18-20h of builds, `generate-matrix`
compares every enabled variant's live source tag against `versions.json`
from the latest stable release (published as an asset by every run).
No upstream movement → build/release jobs skip with a `SKIP` note in the
run summary, and no empty release is created. Any moved variant (or a new
one, or a missing/unreadable manifest) rebuilds the full matrix — fail
open by design. Network cost of the check: 2 unauthenticated API calls.

Cost facts: **the repo must be public** for the full matrix (116 kernel
builds/week: 34 Arch cells + 82 kbuild cells, incl. 48 ThinLTO/Full
extras for the 6 desktop variants) — private repos get only a few thousand free Actions
minutes/month and one kernel compile takes 60–120 min. Per-job timeouts
(350 min) sit under GitHub's hard 6-hour cap. First run after a change?
Smoke-test one cell (`variants=cachyos-bore`, `isa_levels=v3`).

### Toolchain floors (single reference)

- Runners: `ubuntu-24.04`/`ubuntu-latest` + `archlinux:base-devel`
  (rolling) for the makepkg cells.
- Compilers: GCC >= 11 or Clang >= 12 for the v4 target
  (`-march=x86-64-v4`); ThinLTO cells add clang/lld/llvm.
- Python 3.x + **PyYAML 6.0.3 pinned** in all workflows (bump by editing
  the four `pip install` lines together); Rust stable (rustup on Ubuntu,
  distro packages on Fedora) for `CONFIG_RUST` + bindgen.
- Lint gate: shellcheck (apt) + `bash -n` + `py_compile`.
- GitHub Actions versions float on majors and are kept current by
  Dependabot (`.github/dependabot.yml`, weekly).

### Package signing (maintainers)

Create a **dedicated** GPG key (not your personal one), store it as repo
secrets `GPG_PRIVATE_KEY` + optional `GPG_PASSPHRASE`, and releases gain
signed RPMs plus a published public key; the DNF repo enables
`gpgcheck`. Without secrets nothing breaks — releases fall back to
`SHA256SUMS` only.

### Custom single build (manual tuning)

Dispatch `.github/workflows/custom-kernel.yml` for one kernel with your
exact CPU tuning — e.g. CachyOS `.rpm` `x86-64-v2` + ThinLTO tuned for
`ivybridge`:

| Input | Meaning |
|---|---|
| `variant` | id from `config/variants.yml`, e.g. `cachyos-bore` |
| `base_isa` | `v1..v4` Kconfig base (must equal the tuning's floor) |
| `cpu_tuning` | id from `config/cpu-tunings.yml`, e.g. `ivybridge`, `haswell`, `zen3` |
| `lto` | `none` (GCC) \| `thin` \| `thin-dist` \| `full` (Clang+LLVM) |
| `pkg_format` | `all` \| `deb` \| `rpm` (one compile serves both) |
| `src_tag` | blank = resolve live per variant, or pin `cachyos-7.2.4-1` |
| `builder_suffix` | lowercase tag in `uname -r` (default `-yieskow`) |
| `publish_release` | create a `custom-<variant>-<label>-<run>` Release with checksums |

Example label: `v2-ivybridge` → `uname -r` `7.2.4-cachyos-bore-v2-ivybridge-thin-yieskow`.
Kbuild-only (`.deb/.rpm`): arbitrary tunings have no makepkg
`_processor_opt` (upstream only knows `generic[_vN]/zen4/native` since
6.15), so there is no Arch cell here. Kconfig stays generic at `base_isa`
(except `native`→`X86_NATIVE_CPU`, `zen4`→`MZEN4`); the tuning itself is
`-march=` — same sources/patches/config as weekly. `native` needs
`native_ack=yes` (host-dependent, non-reproducible). New CPUs: append to
`config/cpu-tunings.yml` (see its header) — no workflow changes needed.

---

## Facts worth knowing

Checked against CachyOS's live repos/docs/APIs rather than assumed:

- CachyOS publishes prebuilt tiers for generic x86-64 (**kernels only**),
  x86-64-v3, x86-64-v4 and znver4 — **there is no official v2 anywhere**;
  v2 here is real, buildable, and exclusive to this kind of CI.
- The `GENERIC_CPU`/`X86_64_VERSION` Kconfig knobs used for ISA selection
  come from **CachyOS's own patch**, not mainline (mainline only has
  `CONFIG_X86_NATIVE_CPU`). They work here because we build CachyOS
  sources.
- Upstream's scheduler-patch application is **per-PKGBUILD, not global**:
  the flagship and lts apply *no* BORE patch for their `cachyos` default
  (their shipped kernels are pure EEVDF — upstream's own `-e SCHED_BORE`
  there is a silent no-op), while `bore`, `rt-bore`, `hardened` and
  `deckify` do. This pipeline mirrors each folder individually instead of
  assuming one mapping. Verified against all ten live PKGBUILDs (Aug 2026).
- Several variants track **their own kernel series** — lts on 6.18.x,
  hardened on 7.1.x, rc on the current `-rcN` cycle — so source tags are
  resolved per variant from each PKGBUILD (`_major/_minor/_tagrel`, plus
  `_rcver` for RC tags like `cachyos-7.2-rc7-1`).
- CachyOS ships no official `.deb` at all; the Debian path uses kbuild's
  native `bindeb-pkg` from the same patched source tree.
- Their shipped config sets `CONFIG_RUST=y`, so builds provision
  rustc/bindgen automatically (distro packages on Fedora, rustup on
  Ubuntu).
- Already on Fedora? The maintained [COPR repo](https://github.com/CachyOS/copr-linux-cachyos)
  (x86-64-v3 floor, lts/server at v2) is the more polished option — this
  project adds v1/v2, Debian, and full-matrix automation on top.
  Feature-wise both build the same CachyOS sources and configs, so the
  patch/config features travel together: BORE + sched-ext, amd-pstate
  enhancements, Cachy Sauce, ZSTD patchset, BFQ, BBRv3, Clear Linux picks,
  linux-next backports, OpenRGB, ACS override, NTSync — and, like COPR's
  server kernel, ours ticks at 300 Hz with lazy preemption. Differences
  are packaging choices: COPR publishes GCC *and* ThinLTO flavors
  side-by-side (here GCC+ThinLTO+Full ship side-by-side for the 6 desktop
  variants via `lto_variants`, `build_lto=true` remains as legacy whole-run
  ThinLTO mode; Arch builds at each PKGBUILD's authentic default), and COPR bundles the out-of-tree
  `v4l2loopback` module plus userland addons (cachyos-settings, scx-scheds,
  ananicy-cpp) — none of that ships here; pair these kernels with
  COPR-addons if you want it.

## Known limitations

- No APT or pacman repository hosting yet (DNF/Pages only); artifacts are
  Release assets for manual installs.
- Unsigned kernels/modules by design — Secure Boot users must self-sign.
- ThinLTO/Full cells (48 extras) may OOM on memory-constrained runners;
  ccache hit rates drop for LTO builds; Full LTO links single-threaded,
  slower and more memory-hungry than Thin for marginal gains.
- The `cachyos-rc` series is inherently volatile: when upstream rebases
  the folder onto the next `-rc1`, one weekly run may fail until the
  matching patches land on that series.

## Extending

Enable a disabled variant or point a new one at any folder in
[`CachyOS/linux-cachyos`](https://github.com/CachyOS/linux-cachyos) by
editing `config/variants.yml` (`enabled: true`) — no workflow changes
needed. Same for ISA levels in `config/isa-levels.yml`.

## License

Pipeline scripts/workflows: MIT-style, no warranty. Everything they fetch
and build remains GPL-2.0-only (Linux) plus whatever each CachyOS patch
series carries — this repo redistributes none of it.
