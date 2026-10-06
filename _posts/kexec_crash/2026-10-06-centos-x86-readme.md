---
title: Centos-x86 - Validating CONFIG_CRASH_DM_CRYPT on CentOS 10
published: true
categories: [kdump]
tags: [kdump,kexec,luks,dm-crypt,qemu]
---

# centos-x86: Validating CONFIG_CRASH_DM_CRYPT on CentOS 10

This directory holds the build output for the x86_64 counterpart of
`build-out/centos-arm64`: a kernel compiled from the real
`centos-stream-10/src` tree, with a full `dnf`-installed CentOS Stream 10
rootfs (systemd, all kernel modules, real `kexec-tools`/`kdump-utils`),
set up to exercise the same `CONFIG_CRASH_DM_CRYPT` LUKS-encrypted kdump
target that [`vanilla-x86-readme.md`]({% post_url 2026-10-02-vanilla-x86-readme %})
exercises on the minimal busybox `vanilla-x86` build.

**The key difference from `vanilla-x86`:** that test hand-rolls every step
(`cryptsetup`, `configfs`, `kexec -p -s`, a custom kdump-init) because its
busybox rootfs has no systemd or `kdump-utils` at all. This one does not --
the dnf-installed `kdump-utils` package on CentOS Stream 10 already supports
**`kdumpctl setup-crypttab`** and ships a dedicated dracut module script,
`/usr/lib/dracut/modules.d/99kdumpbase/kexec-crypt-setup.sh`, built
specifically for this feature. So this test reuses the real production
toolkit at [`../../../encrypt_crash_kernel/scripts/`](https://github.com/mukeshpilaniya/kernel-qemu-lab/tree/main/encrypt_crash_kernel/scripts)
almost unchanged, staged straight into the rootfs -- this is the closest
thing in this project to "how an actual RHEL/CentOS admin would configure
this feature," run inside QEMU instead of on bare metal.

## Table of Contents

- [Why centos-x86 exists alongside vanilla-x86 and centos-arm64](#why-centos-x86-exists-alongside-vanilla-x86-and-centos-arm64)
- [Script naming](#script-naming)
- [Directory layout (this folder, after a full build)](#directory-layout-this-folder-after-a-full-build)
- [Requirements](#requirements)
- [Build pipeline](#build-pipeline)
- [Core concept: kdump-utils and kdumpctl](#core-concept-kdump-utils-and-kdumpctl)
- [Core concept: makedumpfile](#core-concept-makedumpfile)
- [The role of the rootfs, the boot initramfs, and the kdump initramfs](#the-role-of-the-rootfs-the-boot-initramfs-and-the-kdump-initramfs)
- [Script-by-script walkthrough](#script-by-script-walkthrough)
- [Step by step: what actually happens, start to finish](#step-by-step-what-actually-happens-start-to-finish)
- [Running the LUKS kdump test](#running-the-luks-kdump-test)
- [How kdump-utils integrates with CONFIG_CRASH_DM_CRYPT](#how-kdump-utils-integrates-with-config_crash_dm_crypt)
- [Validating the result](#validating-the-result)
- [Re-running against the same disk image](#re-running-against-the-same-disk-image)

## Why centos-x86 exists alongside vanilla-x86 and centos-arm64

| | `vanilla-arm64` / `vanilla-x86` | `centos-arm64` | `centos-x86` (this folder) |
| --- | --- | --- | --- |
| Kernel source | `centos-stream-10/linux` (plain upstream torvalds tree) | `centos-stream-10/src` (real CentOS Stream 10 tree) | `centos-stream-10/src` |
| Base `.config` | Hand-built via `scripts/config --enable ...` | `redhat/configs/kernel-6.12.0-aarch64.config` (committed, real distro config) | `redhat/configs/kernel-6.12.0-x86_64.config` (committed, real distro config) |
| `CONFIG_CRASH_DM_CRYPT` | Explicitly force-enabled | Already `=y` in the stock config | Already `=y` in the stock config |
| Rootfs | Static busybox, hand-copied binaries | Full `dnf --installroot` CentOS userspace, all modules | Full `dnf --installroot` CentOS userspace, all modules |
| kdump mechanism | Hand-rolled: manual `cryptsetup` + `configfs` + `kexec -p -s` + custom `kdump-init` | (not exercised for LUKS in this project) | Real `kdumpctl setup-crypttab` + dracut's `99kdumpbase` module, i.e. the production path |
| Build arch vs. host | Cross-compiled from arm64 host | Native (same arch as container) | Cross-compiled from arm64 host |

`centos-x86` is the closest thing in this project to "what would actually
happen on a real x86_64 CentOS/RHEL box with this feature enabled" --
`vanilla-x86` proves the kernel mechanism in isolation; this exercises the
*whole stack*, including the userspace integration Red Hat ships for it.

## Script naming

Every script here carries an explicit `-x86` (or `centos-x86`) marker so it
is never confused with its `centos-arm64` counterpart, since both now live
as sibling top-level directories in [mukeshpilaniya/kernel-qemu-lab](https://github.com/mukeshpilaniya/kernel-qemu-lab):

| `centos-arm64` (native, no suffix needed) | `centos-x86` (cross-compiled, `-x86` suffix) |
| --- | --- |
| `build-kernel.sh` (incremental only; first build is manual, see `kernel/README.md`) | `build-centos-x86-kernel.sh` (full build, one script, like `vanilla-x86`) |
| `make-centos-rootfs.sh` | `make-centos-x86-rootfs.sh` |
| `install-modules-dracut.sh` | `install-modules-dracut-x86.sh` |
| `run-qemu.sh` | `run-qemu-centos-x86.sh` |
| *(no LUKS test exists for arm64 in this project yet)* | `luks/run-qemu-luks-centos-x86.sh`, `luks/luks-kdump-centos-x86-test.py`, `luks/stage-kdump-scripts-x86.sh`, `luks/verify-vmcore-centos-x86.sh` |

## Directory layout (this folder, after a full build)

```text
build-out/centos-x86/
├── bzImage                      # x86_64 boot image, 14 MB compressed stub
├── vmlinux                      # 387 MB uncompressed ELF, DWARF debug info (with debug_info, not stripped)
├── kernel.config                # the .config actually built (base + Kconfig deltas below)
├── kernel.release                # 6.12.0-centos10-x86-local+
├── centos-rootfs-x86.raw        # 8G ext4, full dnf-installed CentOS Stream 10 userspace
├── initramfs-x86.img            # 42 MB dracut initrd: virtio_blk/scsi/net, ext4, xfs, crypt, dm
├── modules-stage/               # staging dir used by install-modules-dracut-x86.sh (transient)
├── kdump-scripts-stage/         # staging dir used by stage-kdump-scripts-x86.sh (transient)
├── kdump-vdb.raw                # the encrypted kdump target disk (/dev/vdb in the guest), 2 GiB sparse
└── luks-kdump-centos-x86.log    # full serial transcript of the most recent test run
```

## Requirements

**Packages installed into the rootfs** (via `dnf --installroot`, Step 2
below), confirmed present in CentOS Stream 10's `baseos`/`appstream` repos
for x86_64:

| Package | Version seen | Why |
| --- | --- | --- |
| `cryptsetup` | 2.8.6 | `>=2.7` required for `--link-vk-to-keyring` / `--volume-key-keyring` |
| `kexec-tools` | 2.0.32 | `/usr/sbin/kexec`, `/usr/sbin/vmcore-dmesg` |
| `kdump-utils` | 1.0.61 | **a separate package from `kexec-tools`** -- installing `kexec-tools` alone does not pull in `kdumpctl`, `/etc/kdump.conf`, or `kdump.service`. `kdump-utils` provides all three, plus the dracut `99kdumpbase`/`99earlykdump` modules. `encrypt_crash_kernel/scripts/01-verify-prereqs.sh` checks both package names separately for this reason |
| `xfsprogs` | 6.16.0 | `encrypt_crash_kernel/scripts/03-create-luks-target.sh` formats the dump target as XFS |
| `makedumpfile` | 1.7.8 | kdump's `core_collector` |
| `keyutils`, `crash`, `grubby` | -- | keyring inspection; `crash` is directly available on this distro (unlike the gap `vanilla-x86-readme.md` Section 12 documents for a bleeding-edge *vanilla* kernel); `grubby` is called by `kdumpctl` in a few code paths even with no real GRUB present |

**Kernel config requirements**, already satisfied by the stock
`redhat/configs/kernel-6.12.0-x86_64.config`:

```text
CONFIG_CRASH_DM_CRYPT=y
CONFIG_CRASH_DM_CRYPT_CONFIGS=y
CONFIG_DM_CRYPT=m
CONFIG_CONFIGFS_FS=y
CONFIG_CRYPTO_XTS=y
CONFIG_KEXEC_FILE=y
CONFIG_DEBUG_INFO=y
CONFIG_XFS_FS=m
```

**Build-environment requirements**, on top of the base cross-compile
toolchain (`gcc-x86-64-linux-gnu`, `binutils-x86-64-linux-gnu`):

- `xz-utils` -- `gen_kheaders.sh` pipes through `xz` to build
  `kernel/kheaders_data.tar.xz`; this is needed for the kernel build itself,
  not just for debuginfo/BTF generation.
- `git`, `make` -- needed in the `install-modules-dracut-x86.sh` native-arch
  stage (for `git config --global --add safe.directory` and the
  `modules_install` invocation itself).

## Build pipeline

All scripts below live in [mukeshpilaniya/kernel-qemu-lab](https://github.com/mukeshpilaniya/kernel-qemu-lab); paths are relative to a clone of that repository (`git clone https://github.com/mukeshpilaniya/kernel-qemu-lab && cd kernel-qemu-lab`). Run in order:

```sh
./centos-x86/build-centos-x86-kernel.sh        # bzImage + vmlinux + modules (long: full distro module set)
./centos-x86/make-centos-x86-rootfs.sh          # 8G ext4 CentOS Stream 10 userspace (dnf --installroot)
./centos-x86/install-modules-dracut-x86.sh      # modules_install + dracut initrd (two docker stages, see below)
./centos-x86/luks/stage-kdump-scripts-x86.sh    # copies encrypt_crash_kernel/scripts/ into the rootfs
./centos-x86/luks/luks-kdump-centos-x86-test.py # boots it, runs the real kdumpctl LUKS flow, triggers the panic
./centos-x86/luks/verify-vmcore-centos-x86.sh   # unlocks kdump-vdb.raw externally, checks for the vmcore
./centos-x86/luks/verify-with-crash-centos-x86.sh # opens that vmcore with crash(8) -- confirms it is actually readable
```

### Step 1 -- `build-centos-x86-kernel.sh`

Cross-compiles from `centos-stream-10/src` using an `ubuntu:24.04` container
with the `gcc-x86-64-linux-gnu`/`binutils-x86-64-linux-gnu` cross toolchain
-- the same approach as `vanilla-x86/build-vanilla-x86-kernel.sh`, just
pointed at the real CentOS tree. The base `.config` is **not** regenerated
with `make dist-configs-arch` (that target is tied to the *container's own*
`uname -m`, so it cannot produce an x86_64 config from an arm64 build
container) -- it is copied directly from the already-committed
`redhat/configs/kernel-6.12.0-x86_64.config`, which is the exact config a
real CentOS Stream 10 x86_64 kernel RPM ships.

No manual `scripts/config --enable CRASH_DM_CRYPT` step is needed, unlike
`vanilla-x86` -- that is the whole point of starting from the real distro
config instead of a hand-built one.

**Three things are explicitly disabled on top of the stock config**,
applied on every build (not just the first, so a stale `/build/.config`
from an earlier, differently-configured attempt always picks up the
current overrides):

| Disabled | Why |
| --- | --- |
| `KEXEC_SIG`, `KEXEC_BZIMAGE_VERIFY_SIG` | Would require a trusted signing chain this build does not have. QEMU's direct `-kernel` boot has no UEFI Secure Boot/lockdown anyway, so this only removes a check that could never pass here, not one actually protecting anything. |
| `DEBUG_INFO_BTF`, `DEBUG_INFO_BTF_MODULES` | Needs `pahole` built for the exact kernel version (`CONFIG_PAHOLE_VERSION=131` in the stock config) -- cross-build risk for no benefit; `crash(8)` reads DWARF (`CONFIG_DEBUG_INFO=y`, left on), not BTF. |
| `X86_KERNEL_IBT`, `X86_CET`, `OBJTOOL_WERROR` | `objtool` validates control-flow integrity against the Xen PVH entry stub (`pvh_start_xen`) in a way that depends on the exact toolchain version; this Ubuntu 24.04 cross-toolchain does not match what RHEL's own objtool expectations assume for this config. IBT/CET is pure hardware control-flow hardening, orthogonal to `CONFIG_CRASH_DM_CRYPT`, so it is disabled rather than chasing toolchain parity. |

Builds both `bzImage` **and** `modules` by default (`MODULES=1`) -- a full,
real distro module set (amdgpu, i915, nouveau, every NIC/iSCSI/SCSI driver,
etc.). The persistent `centos-kernel-x86-build` Docker volume means a
re-run after any build-environment fix resumes from already-compiled
objects rather than restarting from scratch.

### Step 2 -- `make-centos-x86-rootfs.sh`

Same `dnf --installroot` recipe as `centos-arm64/make-centos-rootfs.sh`,
`--platform linux/amd64` instead of `arm64`, plus the LUKS-kdump-specific
packages listed under [Requirements](#requirements) above.

### Step 3 -- `install-modules-dracut-x86.sh`

Two docker stages, unlike `centos-arm64`'s one-stage version:

1. **`modules_install`** (stripping + self-signing `.ko` files) runs
   *natively* on the arm64 host using the cross-binutils'
   `x86_64-linux-gnu-strip` -- fast, no emulation needed, since stripping
   and signing a foreign-arch ELF is a metadata operation, not an execution
   of it.
2. **`chroot /mnt/root dracut ...`** and **`chroot /mnt/root depmod ...`**
   have to actually **execute** real x86_64 ELF binaries inside the mounted
   rootfs, which needs an amd64-emulated container (the same QEMU-binfmt
   mechanism already used for the `crash-tool` Docker image elsewhere in
   this project).

### Step 4 -- `luks/stage-kdump-scripts-x86.sh`

Copies `encrypt_crash_kernel/scripts/` (`01`-`08`, `lib/common.sh`) into
`/root/kdump-scripts/` on the rootfs, plus one new file, `run-all.sh`,
chaining the setup stages and the panic trigger:

```sh
01-verify-prereqs.sh              || echo "[WARN] continuing"
FORCE=yes 03-create-luks-target.sh   # defaults to /dev/vdb -- it's there
04-configure-kdump.sh                # kdumpctl setup-crypttab + kdump.conf -> xfs target + link-volume-key
05-rebuild-kdump.sh                  # kdumpctl rebuild / systemctl restart kdump
06-precrash-checks.sh                # refuses to continue if anything above did not land
echo KDUMP_SETUP_DONE
CONFIRM=yes METHOD=sysrq 07-trigger-crash.sh   # echo c > /proc/sysrq-trigger
```

`02-install-packages.sh` is deliberately **not** in the chain -- its `dnf
install` assumes live guest network access this isolated QEMU test does
not have; every package it would install is already baked into the rootfs
by Step 2. `METHOD=sysrq` (not the script's own default, `METHOD=test`) is
used because a direct SysRq `c` is the same mechanism already proven in
[`vanilla-x86/luks/`](https://github.com/mukeshpilaniya/kernel-qemu-lab/tree/main/vanilla-x86/luks), independent of `kdumpctl test`'s own bookkeeping.

## Core concept: kdump-utils and kdumpctl

**What it is.** `kdump-utils` is the userspace package (split out of
`kexec-tools` in recent Fedora/RHEL-family releases -- confirmed as a
separate RPM on this CentOS Stream 10 install, see
[Requirements](#requirements)) that turns the kernel's raw crash-dump
primitives -- `kexec_file_load`, a `crashkernel=`-reserved memory region,
`/proc/vmcore` inside the second kernel -- into a single, declaratively
configured system service. It installs:

| File / unit | What it is |
| --- | --- |
| `/usr/bin/kdumpctl` | The control script. Almost everything below is a `kdumpctl` subcommand. |
| `/etc/kdump.conf` | The one config file: dump target (disk/NFS/SSH/raw), `core_collector`, `path`, `failure_action`, `extra_bins`/`extra_modules` for the generated initramfs. |
| `/usr/lib/systemd/system/kdump.service` | The systemd unit that loads the crash kernel at boot (and that `05-rebuild-kdump.sh` restarts by hand after changing `kdump.conf`). |
| `/usr/lib/dracut/modules.d/99kdumpbase/` | The dracut module that builds the *kdump* initramfs -- `kdump.sh` (its init script, run inside the crash kernel) and, specifically for this feature, `kexec-crypt-setup.sh` (the `CONFIG_CRASH_DM_CRYPT` integration point, see below). |
| `/usr/lib/dracut/modules.d/99earlykdump/` | A separate, unrelated dracut module for firmware-assisted *early* kdump triggering -- not exercised by this test. |

**What the relevant `kdumpctl` subcommands actually do:**

- **`kdumpctl start` / `restart` / `stop`** -- read `kdump.conf`, build (or
  reuse) the kdump initramfs if needed, then `kexec -p -s` (i.e.
  `kexec_file_load`) the crash kernel + that initramfs into reserved
  memory. `05-rebuild-kdump.sh` calls `systemctl restart kdump`, which
  invokes this path.
- **`kdumpctl rebuild`** -- explicitly regenerates *only* the kdump
  initramfs via `dracut`, with `99kdumpbase` force-included, baking in
  whatever `kdump.conf`/`/etc/crypttab` say *at that moment* (the LUKS
  UUID, the mount target, the key description). `05-rebuild-kdump.sh`
  calls this before the restart above.
- **`kdumpctl status`** -- reports whether `/sys/kernel/kexec_crash_loaded`
  is `1` and prints a short summary. Used by both `05-rebuild-kdump.sh`
  and `06-precrash-checks.sh`.
- **`kdumpctl showmem` / `estimate`** -- report the currently reserved
  `crashkernel=` size, and estimate (via `makedumpfile`-style memory-usage
  math) what size is actually needed. Diagnostic only in this project;
  `crashkernel=256M` is set directly on the QEMU append line instead.
- **`kdumpctl test --force`** -- deliberately triggers a *controlled* test
  panic and records a test ID under `/var/lib/kdump/`, so a post-reboot
  check can confirm *that specific test's* dump landed. This project uses
  a direct SysRq `c` instead (`METHOD=sysrq` in `07-trigger-crash.sh`),
  independent of this bookkeeping -- see
  [Script-by-script walkthrough](#script-by-script-walkthrough) item 7.
- **`kdumpctl setup-crypttab`** -- the specific integration point for
  `CONFIG_CRASH_DM_CRYPT`. Inspects the dump target in `kdump.conf`,
  recognizes it is dm-crypt/LUKS-backed, and: derives the key description
  `kdump-cryptsetup:vk-<LUKS-UUID>` (the exact convention the kernel's
  configfs interface and `cryptsetup --link-vk-to-keyring` both need to
  agree on), and writes a `/etc/crypttab` entry with `link-volume-key=`
  so systemd (256+) links the already-registered keyring entry instead of
  prompting for or re-deriving a passphrase. Called by
  `04-configure-kdump.sh`.

**The problem it solves.** Every one of the steps above -- initramfs
construction with exactly the right drivers for *this* dump target,
`crashkernel=` sizing, dump-target-type handling (local disk vs. NFS vs.
SSH), retry/failure policy, and the LUKS key-linking convention -- would
otherwise be a by-hand, per-machine undertaking. `vanilla-x86`'s custom
`kdump-init`/`luks-kdump-test.sh` *is* that by-hand undertaking, built
specifically because that busybox rootfs has no `kdump-utils` to prove the
kernel mechanism works in isolation from it. `centos-x86` exercises the
real thing instead: one config file, a handful of `kdumpctl` calls.

## Core concept: makedumpfile

**What it is.** A standalone userspace program (set as `core_collector` in
`kdump.conf` by `04-configure-kdump.sh`: `core_collector makedumpfile -c
--message-level 7 -d 31`) that reads `/proc/vmcore` inside the crash
kernel, classifies every physical page in it, and writes out a filtered,
compressed dump. It is not part of `kdump-utils` -- it is its own upstream
project, invoked *by* the kdump initramfs's `kdump.sh`, not by `kdumpctl`
directly.

**The problem it solves.** `/proc/vmcore`, as the crash kernel exposes it,
is an ELF-formatted view of **the entire physical RAM** of the machine
that just panicked -- all of it, including pages with zero debugging
value: free pages, anonymous user-process memory, page cache, zeroed
pages. On a server with 128 GB or more of RAM, a byte-for-byte copy of
that is enormous and slow to write, especially to a small dedicated dump
partition -- and almost entirely noise for `crash`-style analysis, which
only cares about kernel memory (kernel data structures, stacks, slabs).
`makedumpfile` exists specifically to avoid writing that noise out at all.

**How it does it.** Its `-d <level>` flag is a bitmask, each bit excluding
one category of page: zero pages, cache pages, cache-private pages, user
pages, free pages. `-d 31` (all five bits) is the most aggressive filter
level and the one this project uses. One of `-c`/`-l`/`-p`/`-z` then
selects the page-compression codec -- zlib, lzo, snappy, or zstd
respectively -- into `makedumpfile`'s own compact format (explicitly
documented by `makedumpfile --help` as being "ONLY FOR THE CRASH
UTILITY"), the same format `crash(8)` reads directly with no separate
decompression step. This project's `04-configure-kdump.sh` uses `-c`
(zlib) specifically: zlib is virtually always linked into a `crash(8)`
build, whereas the `crash-tool` image this project's own
`verify-with-crash-centos-x86.sh` uses (built from the `crash-utility`
git source, see [Script-by-script walkthrough](#script-by-script-walkthrough)
item 9) links zlib/bz2/xz/snappy but not `liblzo2` -- `-l` (lzo) produced
a dump that build's `crash` reported as `"uncompress failed: no lzo
compression support"` on, while `-c` opens cleanly. A dump level of 31
typically shrinks a vmcore from many gigabytes down to tens or hundreds
of megabytes, depending on what was resident in kernel memory at panic
time -- confirmed directly in this project's own runs: 72-92 MB vmcores
from a 2 GiB guest.

**How it differs from the other tools in this pipeline** -- three layers,
no overlap:

| Tool | Layer | Job |
| --- | --- | --- |
| `kdumpctl` (kdump-utils) | Orchestration | Decides *when* a dump capture happens, builds the environment (initramfs, mount, LUKS unlock) it happens in. Never reads a memory page itself. |
| `makedumpfile` | Capture | Runs *inside* that environment, reads `/proc/vmcore`, filters + compresses it into the file that then gets written to the configured target. |
| `crash` (see [Step 10](#step-by-step-what-actually-happens-start-to-finish)) | Analysis | Runs later, against whatever file `makedumpfile` produced, to interactively inspect it. Never filters or compresses anything; purely read-only, after the fact. |

If `core_collector` is left unset in `kdump.conf`, kdump instead does a
plain, unfiltered copy of `/proc/vmcore` -- simpler, but potentially
10-100x larger, and correspondingly slower to write; this project always
sets `core_collector`, so that path is not exercised here. A separate,
narrower mode, `makedumpfile --dump-dmesg`, extracts *only* the kernel
ring-buffer log from a vmcore without needing `crash`'s full
symbol-resolution machinery -- useful as a fast, dependency-light sanity
check that a dump is intact, independent of whether full `crash` analysis
succeeds.

## The role of the rootfs, the boot initramfs, and the kdump initramfs

Three different filesystem images are involved, each with a distinct job.
Conflating them is the single easiest way to misread this setup, since two
of the three are both called "initramfs" and live right next to each other
in `/boot`.

| | `centos-rootfs-x86.raw` (rootfs) | `initramfs-x86.img` (boot initramfs) | the kdump initramfs (built by `kdumpctl rebuild`, lives inside the rootfs) |
| --- | --- | --- | --- |
| What it is | A real, persistent 8G ext4 disk image -- the actual CentOS Stream 10 install: systemd, dnf, every installed package, all kernel modules under `/lib/modules/<kver>/` | A 42 MB **temporary, RAM-resident** filesystem, generated by `dracut`, containing just enough to find and mount the real root | A **separate**, smaller RAM-resident filesystem, also generated by `dracut` (via `kdumpctl rebuild`, not `install-modules-dracut-x86.sh`), stored at `/boot/initramfs-<kver>kdump.img` on the rootfs itself |
| Who boots into it | The **first kernel**, as its real root (`root=/dev/vda`) | The **first kernel**, briefly, before the real root is mounted | The **second kernel** (the crash kernel), exclusively, after a panic |
| Its job | Everything: runs systemd, PID 1, all services, holds `/etc/crypttab`, `/etc/kdump.conf`, and is where `03`-`07` actually execute as root-shell commands | Load `virtio_blk`/`ext4` modules, find `/dev/vda`, mount it as the real root, then `switch_root` into it and exec systemd -- and nothing else | Load `virtio_blk`/`xfs`/`crypt`/`dm` modules, unlock the LUKS dump target using the **key the kernel itself restored from crash-reserved memory** (no passphrase), mount it, copy `/proc/vmcore` via `makedumpfile`, then reboot |
| Where it lives on disk | `build-out/centos-x86/centos-rootfs-x86.raw`, passed to QEMU with `-drive ...if=virtio` (becomes `/dev/vda`) | `build-out/centos-x86/initramfs-x86.img`, passed to QEMU with `-initrd` | Inside `centos-rootfs-x86.raw` at `/boot/initramfs-<kver>kdump.img` -- **not** a separate top-level file in `build-out/centos-x86/`, and not the same file as `initramfs-x86.img` |
| Built by | `make-centos-x86-rootfs.sh` (base) + `install-modules-dracut-x86.sh` (modules installed into it) | `install-modules-dracut-x86.sh`, Step 3's `[2/2]` stage (`dracut --add-drivers 'virtio_blk ... ext4 xfs crc32c jbd2 mbcache' --add 'crypt dm'`) | `05-rebuild-kdump.sh`'s `kdumpctl rebuild`, run **on the guest itself** at the serial console, using the `99kdumpbase` dracut module that `install-modules-dracut-x86.sh` never touches |

The practical consequence: `install-modules-dracut-x86.sh` only ever
produces the *boot* initramfs. The *kdump* initramfs does not exist until
`05-rebuild-kdump.sh` runs `kdumpctl rebuild` inside the booted guest --
there is no host-side script that builds it, because it depends on runtime
state only the first kernel has at that point (the LUKS UUID, the
configfs-registered key description, the mount target from `kdump.conf`).
This is also why `lsinitrd` against `initramfs-x86.img` will never show
`cryptsetup`/`dm-crypt` -- those only exist in the *other* initramfs, the
one `05-rebuild-kdump.sh` builds later, on the guest.

**What actually runs inside the kdump initramfs, in order.** Both
initramfs images are built by the same `dracut`, so both use the same
generic init framework -- a hook-based pipeline, not a full init system.
The *boot* initramfs's hook chain ends at `switch_root` into systemd; the
*kdump* initramfs's hook chain, driven by the `99kdumpbase` module's
`kdump.sh`, is shorter and never hands off to anything resembling a normal
userspace:

1. **cmdline hooks** -- parse `/proc/cmdline` for `elfcorehdr=` (where
   `/proc/vmcore` is exposed) and, when `CONFIG_CRASH_DM_CRYPT` put one
   there, `dmcryptkeys=`.
2. **pre-mount hooks** -- for an encrypted target specifically, this is
   where `kexec-crypt-setup.sh`'s generated udev rule fires: it unlocks
   the device with `cryptsetup luksOpen --volume-key-keyring
   %%user:<key-description> <device> luks-<uuid>`, using the `user`-type
   key the kernel already restored into crash-reserved memory -- no
   passphrase prompt is possible here even in principle, since there is
   no interactive shell to prompt into yet.
3. **mount hooks** -- mount the now-unlocked device at the path
   `kdump.conf`'s `path`/filesystem-type line specifies.
4. **`do_dump`** -- runs `makedumpfile` (per `core_collector` in
   `kdump.conf`) against `/proc/vmcore`, writing the filtered, compressed
   result under `/var/crash/<timestamp>/` on the just-mounted filesystem.
5. **`do_final_action`** -- per `kdump.conf`'s `failure_action`, default
   `reboot` either way (success or failure) -- see
   [Validating the result](#validating-the-result) for why this makes the
   serial console alone an unreliable pass/fail signal.

**Scope and size, compared.** The boot initramfs (42 MB in this project)
has to be able to find and mount *any* root filesystem a general-purpose
distro install might have -- `virtio_blk`/`ext4` here, but in principle
LVM/mdraid too -- and then hand off to a full systemd. The kdump
initramfs only ever needs *one specific, already-known* dump target's
driver (`xfs` here) plus `crypt`/`dm` and `makedumpfile`'s own compression
libraries, and never needs systemd, a shell prompt, or general userspace
at all -- it is narrower in scope by construction, not just by
coincidence of what happened to be included. Its built size is not
captured as a top-level artifact in this project (unlike
`initramfs-x86.img`), since it never leaves the rootfs it was built
inside.

## Script-by-script walkthrough

In the order they run. Scripts already covered in detail under
[Build pipeline](#build-pipeline) are summarized here just enough to place
them in the full sequence; see that section for the Kconfig/package
reasoning behind each.

| # | Script | Runs where | What it actually does |
| --- | --- | --- | --- |
| 1 | `build-centos-x86-kernel.sh` | host (Ubuntu container, arm64-native) | Copies the committed `kernel-6.12.0-x86_64.config` to `/build/.config`, force-disables `KEXEC_SIG`/BTF/IBT via `scripts/config`, runs `olddefconfig`, then `make bzImage modules`. Copies `bzImage`, `vmlinux`, `kernel.config`, `kernel.release` to `build-out/centos-x86/`. The compiled `.ko` files stay in the `centos-kernel-x86-build` Docker volume -- not copied out here, because Step 3 needs them in place for `modules_install`, not as loose files. |
| 2 | `make-centos-x86-rootfs.sh` | host (CentOS Stream 10 container, amd64-emulated) | Creates an empty 8G raw disk, formats it ext4, then runs `dnf --installroot=/mnt/root` to install a full CentOS Stream 10 userspace into it -- systemd, `cryptsetup`, `kdump-utils`, `xfsprogs`, etc. Sets the root password to `root`, disables SELinux enforcement, enables a serial getty on `ttyS0`. Produces no kernel, no modules, no initramfs yet -- just the userspace. |
| 3 | `install-modules-dracut-x86.sh` | host, two containers (arm64-native, then amd64-emulated) | `[1/2]`: `make modules_install INSTALL_MOD_PATH=/stage` -- copies every compiled `.ko` out of the build volume, strips and self-signs them, into a staging directory. `[2/2]`: mounts the rootfs disk, copies that staged module tree into `/lib/modules/<kver>/` on it, copies `bzImage`/`kernel.config` in as `/boot/vmlinuz-<kver>`/`/boot/config-<kver>` (so the guest's own `uname -r` and `/boot/config-$(uname -r)` resolve correctly), `chroot`s in to run `depmod -a` and `dracut` (the *boot* initramfs only -- see the table above), and copies that initramfs back out to `build-out/centos-x86/initramfs-x86.img`. |
| 4 | `run-qemu-centos-x86.sh` | host | A plain boot, no second disk -- `-kernel bzImage -initrd initramfs-x86.img -drive centos-rootfs-x86.raw`, `crashkernel=256M` on the append line. Used for a quick sanity boot; the LUKS test uses `luks/run-qemu-luks-centos-x86.sh` instead, which adds the second disk. |
| 5 | `luks/stage-kdump-scripts-x86.sh` | host, one container (arm64, mounts the rootfs loop) | Copies `encrypt_crash_kernel/scripts/*` verbatim into a staging directory, generates one new file there (`run-all.sh`, which chains `01`→`03`→`04`→`05`→`06`→`07`), `chmod +x`s everything, then mounts `centos-rootfs-x86.raw` via loop and copies the whole staged tree to `/root/kdump-scripts/` on it. Nothing executes yet -- this only places files on disk. |
| 6 | `luks/run-qemu-luks-centos-x86.sh` | host | Same as `run-qemu-centos-x86.sh`, plus a second virtio disk (`kdump-vdb.raw`, created as a 2 GiB sparse file on first use) attached as `/dev/vdb` in the guest -- this is the LUKS dump target. Not normally invoked directly; `luks-kdump-centos-x86-test.py` launches it. |
| 7 | `luks/luks-kdump-centos-x86-test.py` | host (spawns #6 on a pty) | The actual test driver. Boots via #6, waits for the real systemd `login:` prompt, logs in as `root`/`root`, runs `sh /root/kdump-scripts/run-all.sh` (which is scripts `01`/`03`/`04`/`05`/`06` staged by #5), waits for `KDUMP_SETUP_DONE`, then sends nothing further -- `run-all.sh` itself triggers the SysRq panic as its last step. Everything from boot to (attempted) crash-kernel dump is recorded verbatim to `luks-kdump-centos-x86.log`. |
| 8 | `luks/verify-vmcore-centos-x86.sh` | host (one Alpine container) | Runs independently, *after* the test above, against whatever `kdump-vdb.raw` ended up containing. Loop-mounts it, opens the LUKS header with the known test passphrase, mounts the XFS filesystem it contains read-only, and looks under `/var/crash/` for a `vmcore` file. This is the only step that actually inspects the dump target's contents -- nothing in steps 1-7 does, including the test driver, since the guest itself reboots either way (see [Validating the result](#validating-the-result)). On success, copies the file to `build-out/centos-x86/vmcore-x86.extracted`. |
| 9 | `luks/verify-with-crash-centos-x86.sh` | host (`crash-tool:fedora42-x86` container) | Runs independently of everything above, against whatever step 8 produced. Opens `vmcore-x86.extracted` with `crash(8)`, using `build-out/centos-x86/vmlinux` as the matching debug symbols, and runs `sys`/`bt`/`log` (or whatever commands are passed as arguments). Confirms the dump is actually *parseable* by `crash`, not just present as a file -- see [Validating the result](#validating-the-result). |

The staged `encrypt_crash_kernel/scripts/01`-`08` themselves (what `run-all.sh`
actually calls) are described in
[How kdump-utils integrates with CONFIG_CRASH_DM_CRYPT](#how-kdump-utils-integrates-with-config_crash_dm_crypt)
above, rather than repeated here.

## Step by step: what actually happens, start to finish

1. **`build-centos-x86-kernel.sh`** produces a bzImage + a full module tree,
   still sitting in a Docker volume, not yet installed anywhere a guest
   could boot from.
2. **`make-centos-x86-rootfs.sh`** produces an empty-of-kernel but
   otherwise complete CentOS Stream 10 disk -- it could not yet boot,
   because it has no `/boot/vmlinuz-*`, no `/lib/modules/<kver>/`, and no
   initramfs.
3. **`install-modules-dracut-x86.sh`** closes that gap: the kernel's
   modules land on the rootfs disk, `/boot/vmlinuz-<kver>` and
   `/boot/config-<kver>` are added, and the *boot* initramfs is generated
   and copied out. After this step, the rootfs disk is bootable.
4. **`luks/stage-kdump-scripts-x86.sh`** places the
   `encrypt_crash_kernel/scripts/` toolkit (plus `run-all.sh`) onto that
   disk at `/root/kdump-scripts/`, purely as files -- still nothing has
   booted.
5. **`luks/luks-kdump-centos-x86-test.py`** launches QEMU
   (`luks/run-qemu-luks-centos-x86.sh` under it) with the rootfs as `vda`
   and a fresh, empty `kdump-vdb.raw` as `vdb`. The **first kernel** boots,
   `dracut`'s *boot* initramfs finds and mounts `vda`, `switch_root` hands
   off to systemd, and the login prompt appears.
6. The driver logs in and runs `run-all.sh`, which executes, in order,
   inside the booted first kernel:
   - `01-verify-prereqs.sh` -- read-only sanity check (kernel config,
     installed packages, configfs interface).
   - `03-create-luks-target.sh` -- formats `/dev/vdb` as LUKS2, opens it
     with `cryptsetup open --link-vk-to-keyring`, linking the volume key
     into a `logon` key in the user keyring.
   - `04-configure-kdump.sh` -- runs `kdumpctl setup-crypttab`, which
     writes `/etc/crypttab` (`link-volume-key=`) and points
     `/etc/kdump.conf` at the now-unlocked filesystem.
   - `05-rebuild-kdump.sh` -- runs `kdumpctl rebuild`, which is the point
     where the **second**, *kdump*-specific initramfs (see the table above)
     actually gets built for the first time, containing the `99kdumpbase`
     dracut module. `systemctl restart kdump` then `kexec_file_load`s the
     crash kernel with that initramfs -- this is also the moment
     `crash_load_dm_crypt_keys()` runs in the kernel, copying the
     configfs-registered key into crash-reserved memory.
   - `06-precrash-checks.sh` -- refuses to continue (would exit non-zero)
     if the crash kernel is not actually loaded, or the key is not
     confirmed present in reserved memory.
   - `07-trigger-crash.sh` -- `echo c > /proc/sysrq-trigger`, panicking the
     first kernel on purpose.
7. The panic hands control to `machine_kexec`, which boots the **second
   kernel** directly into the *kdump* initramfs built in step 6 (not the
   *boot* initramfs from step 3 -- the first kernel is gone at this point,
   there is no `switch_root`, no systemd, no login). That initramfs's
   `99kdumpbase`-generated udev rule unlocks `/dev/vdb` using the restored
   key (`cryptsetup ... --volume-key-keyring`, no passphrase), mounts the
   filesystem `kdump.conf` points at, and attempts to write `/proc/vmcore`
   there via `makedumpfile`.
8. Whatever happened, the kdump initramfs calls `kdump.conf`'s
   `final_action` (default `reboot`), and QEMU's `-no-reboot` flag turns
   that into the QEMU process simply exiting.
9. **`luks/verify-vmcore-centos-x86.sh`**, run separately against the
   resulting `kdump-vdb.raw`, is the only step that opens the dump target
   from outside the guest and checks whether `/var/crash/.../vmcore`
   actually exists on it. On success it copies that file out to
   `build-out/centos-x86/vmcore-x86.extracted`.
10. **`luks/verify-with-crash-centos-x86.sh`** closes the loop: a vmcore
    file existing is not the same as a vmcore being *readable*. This step
    runs `crash(8)` -- via the `crash-tool:fedora42-x86` image built from
    [`crash-tool/Dockerfile`](https://github.com/mukeshpilaniya/kernel-qemu-lab/blob/main/crash-tool/Dockerfile)
    (`docker build --platform linux/amd64 -t crash-tool:fedora42-x86 ./crash-tool`) -- against
    `build-out/centos-x86/vmlinux` and the `vmcore-x86.extracted` from
    step 9, and runs `sys`/`bt`/`log` (or any commands passed on the
    command line) non-interactively. Unlike `vanilla-x86`'s situation in
    `vanilla-x86-readme.md` Section 12, this kernel is CentOS Stream 10's own
    6.12.0 release, not a bleeding-edge upstream `-rc` build, so there is
    no expected `crash`/kernel version mismatch here -- the same image
    built for `vanilla-x86` works unchanged, since `crash` only needs to
    match the dump's *architecture* (x86_64), not any particular kernel
    version within reason.

## Running the LUKS kdump test

```sh
cd kernel-qemu-lab   # clone of https://github.com/mukeshpilaniya/kernel-qemu-lab
./centos-x86/luks/luks-kdump-centos-x86-test.py
```

The driver waits for the real systemd `login:` prompt (unlike `vanilla-x86`'s
busybox, which drops straight to a root shell), logs in as `root`/`root`,
runs `sh /root/kdump-scripts/run-all.sh`, waits for `KDUMP_SETUP_DONE`, then
the SysRq panic line, then captures whatever the crash kernel's own boot
sequence prints. The full transcript lands at
`build-out/centos-x86/luks-kdump-centos-x86.log`.

## How kdump-utils integrates with CONFIG_CRASH_DM_CRYPT

This is the production mechanism `encrypt_crash_kernel/scripts/` drives,
spelled out so the Step 4 chain above is not a black box:

**First-kernel side (`03`/`04`/`05`):**

- `03-create-luks-target.sh` formats the target device as LUKS2 and opens
  it with `cryptsetup open --link-vk-to-keyring`, linking the volume key
  into a `logon`-type key in the user keyring, described as
  `kdump-cryptsetup:vk-<LUKS-UUID>`. The device-mapper name it opens the
  volume under is **`luks-<LUKS-UUID>`**, not an arbitrary fixed name --
  see "Why the mapper name matters" below for why this specific choice is
  load-bearing, not cosmetic.
- `04-configure-kdump.sh` runs `kdumpctl setup-crypttab`, which writes
  `/etc/crypttab` with a `link-volume-key=` entry and points
  `/etc/kdump.conf` at the unlocked filesystem (`xfs UUID=<FS-UUID>`,
  `path /`). `kdumpctl setup-crypttab` (confirmed by reading
  `/usr/bin/kdumpctl`'s `setup_crypttab()`) only ever *adds* the
  `link-volume-key=` option to whatever crypttab line already matches the
  LUKS UUID -- it does not rename the mapper column, so the name `03`
  chose is preserved untouched.
- `05-rebuild-kdump.sh` runs `kdumpctl rebuild`, which regenerates the
  kdump-specific dracut initramfs (distinct from the boot initramfs) with
  the `99kdumpbase` module, and `systemctl restart kdump` to
  `kexec_file_load` the crash kernel with that initramfs.

**Crash-kernel side (built into the `99kdumpbase` dracut module):**

- `kdump_check_crypt_targets()` (in `99kdumpbase/module-setup.sh`) detects
  that the dump target is LUKS-backed and arranges for the crash kernel's
  initramfs to unlock it independently of the generic dracut `crypt`
  module -- it writes its own udev rule rather than a generic
  `/etc/crypttab` entry.
- That rule calls `cryptsetup luksOpen --volume-key-keyring
  %%user:<key-description> <device> luks-<LUKS-UUID>` -- using the
  `user`-type key the kernel itself restored from crash-reserved memory
  (no passphrase, no second Argon2 run), and naming the resulting
  `/dev/mapper` node `luks-<LUKS-UUID>`. This naming is **hardcoded and
  unconditional** -- it is derived purely from the dump target's
  underlying device UUID (via `get_all_kdump_crypt_dev()` in
  `kdump-lib.sh`), with no awareness of, or dependency on, whatever
  mapper name the first kernel happened to use.
- Once unlocked and mounted, kdump's `do_dump` path writes `vmcore` under
  `/var/crash/<timestamp>/` on that filesystem, then calls
  `do_final_action()`, which reboots the guest per `kdump.conf`'s
  `final_action` (default `reboot`).

**Why the mapper name matters.** The kdump initramfs's *mount* unit
(generated during `kdumpctl rebuild`, via `mkdumprd`'s
`get_mntpoint_from_target()`) is built by asking the **currently running
first kernel** what device is presently mounted at the dump target --
i.e. it bakes in a `--mount '/dev/mapper/<whatever 03 named it> ...'`
argument reflecting the *first* kernel's current state. The unlock
mechanism above, on the *crash* kernel side, is completely independent of
that and always creates `luks-<LUKS-UUID>` regardless. If `03` had opened
the volume under a different, arbitrary name (a static `kdump_luks`, for
example), the mount unit would wait for a device name the unlock step
never creates, the device the unlock step *does* create would be reported
via `dracut-initqueue` as `Device luks-<uuid> already exists` (confirming
the unlock worked) with no further progress, and `do_dump` would never
run. Naming the first kernel's mapper `luks-<LUKS-UUID>` from the start --
matching the crash-kernel convention `kdump_check_crypt_targets()` is
always going to use regardless -- is what keeps both sides in agreement,
entirely at this project's own configuration layer, with no changes
needed to `kdump-utils` itself.

## Validating the result

The dracut `99kdumpbase` module has no "I succeeded" marker on the serial
console comparable to `vanilla-x86`'s custom `kdump-init` (which explicitly
prints `LUKS_KDUMP_VMCORE_OK`) -- it calls `do_final_action()` and reboots
the guest regardless of whether the dump succeeded. Under QEMU's
`-no-reboot` flag, that guest-initiated reboot makes QEMU exit rather than
cycle back, so "the QEMU process ended" is not, by itself, evidence of
anything.

`luks/verify-vmcore-centos-x86.sh` is the authoritative check for whether a
dump landed at all: it unlocks `kdump-vdb.raw` externally (a privileged
Alpine container, the same pattern as `vanilla-x86-readme.md` Section 12 Step 3),
mounts the XFS filesystem read-only, and looks for an actual `vmcore` file
under `/var/crash/`.

A `vmcore` existing is still not the same as a `vmcore` being *usable*.
`luks/verify-with-crash-centos-x86.sh` is the follow-up check: it opens
the file `verify-vmcore-centos-x86.sh` extracted with `crash(8)` (via the
`crash-tool:fedora42-x86` image, see [Script-by-script walkthrough](#script-by-script-walkthrough)
item 9), against the matching `vmlinux` from Step 1. Only once that
succeeds -- `sys` reporting the right kernel release and panic reason,
`bt` showing a sane call stack -- is the dump considered fully validated,
the same bar `vanilla-x86-readme.md` Section 12 applies to `vanilla-x86`.

## Re-running against the same disk image

**No, rebuilding the rootfs and initramfs is not required for an ordinary
re-run.** Rebuilding them (Steps 2 and 3 of the
[Build pipeline](#build-pipeline), each several minutes) is only needed
when you specifically want a pristine, zero-history baseline. What you
actually need to re-run depends on what changed:

| What changed | What to re-run | Why that's enough |
| --- | --- | --- |
| Nothing -- just running the test again | `./centos-x86/luks/luks-kdump-centos-x86-test.py` directly | `run-all.sh` already passes `FORCE=yes` to `03-create-luks-target.sh`, so the "already active" guard (see below) does not block a second run. |
| `encrypt_crash_kernel/scripts/*` edited on the host | `luks/stage-kdump-scripts-x86.sh`, then the test | Only re-copies the toolkit onto the existing rootfs; cheap (one Alpine container, seconds), no kernel/rootfs rebuild involved. |
| Kernel or modules rebuilt (`build-centos-x86-kernel.sh` ran again) | `install-modules-dracut-x86.sh`, then the test | Picks up the new `bzImage`/modules and regenerates the *boot* initramfs. The rootfs's installed userspace packages are untouched, so `make-centos-x86-rootfs.sh` itself is not needed. |
| You want a fully clean, zero-history baseline | `make-centos-x86-rootfs.sh` **and** `install-modules-dracut-x86.sh`, then `stage-kdump-scripts-x86.sh`, then the test | See below for exactly what a stale rootfs carries forward that `FORCE=yes` does not clean up. |

**Why a re-run against an *unrebuilt* rootfs still works.**
`luks-kdump-centos-x86-test.py` mutates `/etc/crypttab` and
`/etc/kdump.conf` *inside* `centos-rootfs-x86.raw` (via `kdumpctl
setup-crypttab`), so a second boot of the same image auto-activates the
LUKS mapping via systemd before the test scripts even run --
`03-create-luks-target.sh`'s own "already active" guard would otherwise
(correctly) refuse to re-format a device that is already open.
`run-all.sh` passes `FORCE=yes` specifically to get past that guard, and
`03`/`04` then simply redo the LUKS format, crypttab, and `kdump.conf`
steps against the same device -- cheaply, in seconds, with no rebuild of
anything.

**What `FORCE=yes` does *not* clean up**, and so what a from-scratch
rebuild is actually for: leftover kernel-keyring entries from the previous
run's key, a previously-built *kdump* initramfs still on disk with the
old run's UUID baked into its udev rule (overwritten by the next
`kdumpctl rebuild` in `05-rebuild-kdump.sh`, but briefly stale in between),
and whatever was left under `/var/crash` from a prior attempt. None of
these have caused an observed difference in this project's own re-runs,
but a full rebuild is the way to rule all of them out at once when
reproducibility of a specific result matters more than iteration speed.
