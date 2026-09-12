# CachyOS multi-ISA kernel CI

Automated weekly builds of [CachyOS-flavoured Linux kernels](https://github.com/CachyOS/linux-cachyos)
across every x86-64 microarchitecture level (v1/v2/v3/v4), packaged for
**Arch**, **Debian/Ubuntu** and **Fedora** — powered by GitHub Actions,
published as GitHub Releases.

Nothing is forked or vendored: every run pulls CachyOS's current signed
kernel source, patches and configs live from their repos and builds them.
This repository only owns the build matrix and its glue scripts, so it
keeps working as CachyOS updates without code changes here.

---

## Downloading and installing a kernel

Grab artifacts from the [Releases page](../../releases) (weekly stable
releases tagged `weekly-N`). Each release contains packages for every
variant × ISA level × distro combination, plus `SHA256SUMS`.

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
| `cachyos-server` | EEVDF, lazy preemption | main | `CONFIG_CACHY` off, like upstream; needs only v2 |
| `cachyos-deckify` | BORE | main | Steam Deck / handheld patches included |
| `cachyos-rc` | pure EEVDF | current `-rcN` cycle | churns weekly by design |

Every variant is reproduced against **its own source series tag**, resolved
live from that folder's PKGBUILD — not from the flagship's. Patch sets are
declared per variant too, mirroring exactly what each upstream PKGBUILD's
`source=()` array adds (they genuinely differ: the flagship applies *no*
scheduler patch for its default, deckify applies BORE for the same
scheduler value, and so on).

That yields 34 ISA-level combinations (38 minus the 4 disabled BMQ
cells) × 2 build jobs (Arch + merged kbuild for .deb/.rpm) ≈ **68 builds
per week** — sized for a public repo's unlimited Linux minutes.

### 3. Install

Verify first: every asset is covered by `SHA256SUMS`; if the repo has
GPG signing configured there will also be signed RPMs and a
`RPM-GPG-KEY-cachyos-ci.asc` public key.

```sh
sha256sum -c SHA256SUMS          # from inside the download folder
```

**Fedora**

```sh
sudo dnf install ./kernel-cachyos-*v3*.rpm
# SELinux only, needed once so modules can load:
sudo setsebool -P domain_kernel_load_modules on
```

**Debian / Ubuntu**

```sh
sudo dpkg -i ./linux-image-*.deb ./linux-headers-*.deb
```

**Arch**

```sh
sudo pacman -U ./linux-cachyos-*.pkg.tar.zst
```

Then reboot. Keep your stock kernel installed as a fallback boot entry.

> ⚠️ **These kernels are unsupported and UNSIGNED.** Don't use them on
> machines you care about without understanding what you're installing.
> If you boot with **Secure Boot enabled**, the kernel won't start unless
> *you* sign it and enroll your own key (mokutil/sbctl/pesign — your
> choice; this project deliberately stays out of that).

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
- Source tarball is fetched by release tag (e.g. `cachyos-7.2.0-1`) and
  **GPG-verified against CachyOS's published keys** — verification fails
  hard by default.
- Scheduler patches come from [`cachyos/kernel-patches`](https://github.com/cachyos/kernel-patches)
  at build time using the exact same mapping as upstream PKGBUILDs.
- Kernel configuration replicates upstream's `prepare()` toggles
  (scheduler, ISA level via `_processor_opt=generic_vN`, 1000 Hz, THP…).
- Optional Clang ThinLTO (`build_lto=true`) for the deb/rpm paths; the
  Arch path always builds at each PKGBUILD's own authentic LTO default
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
| `build_lto` | Clang ThinLTO for deb/rpm cells (RAM-hungry link phase) |
| `publish_repo` | publish RPMs as a browsable DNF repo on GitHub Pages |

Cost facts: **the repo must be public** for the full matrix (68 kernel
builds/week: 34 Arch cells + 34 merged kbuild cells) — private repos get only a few thousand free Actions
minutes/month and one kernel compile takes 60–120 min. Per-job timeouts
(350 min) sit under GitHub's hard 6-hour cap. First run after a change?
Smoke-test one cell (`variants=cachyos-bore`, `isa_levels=v3`).

### Package signing (maintainers)

Create a **dedicated** GPG key (not your personal one), store it as repo
secrets `GPG_PRIVATE_KEY` + optional `GPG_PASSPHRASE`, and releases gain
signed RPMs plus a published public key; the DNF repo enables
`gpgcheck`. Without secrets nothing breaks — releases fall back to
`SHA256SUMS` only.

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

## Known limitations

- No APT or pacman repository hosting yet (DNF/Pages only); artifacts are
  Release assets for manual installs.
- Unsigned kernels/modules by design — Secure Boot users must self-sign.
- ThinLTO cells may OOM on memory-constrained runners; ccache hit rates
  drop for LTO builds.
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
