---
title: CONFIG_CRASH_DM_CRYPT - Validating kdump on a LUKS-Encrypted Target
published: true
categories: [kdump]
tags: [kdump,kexec,luks,dm-crypt,qemu]
---

# `CONFIG_CRASH_DM_CRYPT`: Validating kdump on a LUKS-Encrypted Target

This page provides a practical test approach for validating Linux kernel kdump support on LUKS-encrypted dump targets using `CONFIG_CRASH_DM_CRYPT`.

Use this guide when verifying that a crash kernel can automatically unlock an encrypted dump target and successfully save a vmcore without requiring manual passphrase entry after a kernel panic.

**A vmcore that exists is not the same as a vmcore that is validated.** This guide treats opening the dump with the `crash` utility — and confirming it shows the expected panic, backtrace, and kernel log — as part of the core pass bar, not an optional extra at the end. A dump that is present but unreadable, or that was never actually opened, is a fail. The [Dependencies and Requirements](#dependencies-and-requirements-for-the-complete-workflow) section below lists everything needed for that, including the parts most test plans miss: a debug-info `vmlinux` matching the exact panicking kernel, and a `crash` build new enough for that kernel's internal structures.

The feature landed in mainline Linux 6.16, documented at the time as x86_64-only. A later upstream series, cherry-picked and proven end-to-end as part of this repository's own aarch64 work (see [Related implementations](#related-implementations-in-this-repository) below), extends it to arm64 and ppc64le via a `linux,dmcryptkeys` device-tree property. **This document itself stays architecture-neutral and is the test-plan/spec the implementations below all follow** — it intentionally avoids hard-coding one distro's package names, one architecture's command-line syntax, or one project's directory layout, so any of those write-ups can be checked against it.

Every test target in this guide is a **real, persistent block device** — a dedicated disk or partition. A loop-backed file is deliberately not used anywhere in this document, including in the example commands below: the crash kernel does not inherit the first kernel's loop-device mapping, so a loop-backed target looks correctly configured right up until the panic, then silently fails to produce a usable dump. Substitute your own target device path (shown below as `$DUMP_DEV`) wherever one is needed.

## Related implementations in this repository

This document is the vendor-neutral test plan; the following three documents are concrete, increasingly complete implementations of it, each with real command output from an actual passing run:

| Document | Architecture | Rootfs | What it proves |
| --- | --- | --- | --- |
| [`vanilla-x86-readme.md`]({% post_url 2026-10-02-vanilla-x86-readme %}) | x86_64 | Minimal static busybox | The kernel mechanism in isolation, hand-rolled (`cryptsetup`, `configfs`, `kexec -p -s`, a custom kdump-init) -- no `kdump-utils` exists on this rootfs at all, so every step this guide describes is done by hand and shown explicitly. |
| [`centos-x86-readme.md`]({% post_url 2026-10-06-centos-x86-readme %}) | x86_64 | Full `dnf`-installed CentOS Stream 10 | The real production path: the distro-packaged `kdump-utils` (`kdumpctl setup-crypttab`, the `99kdumpbase` dracut module) doing everything this guide describes, unmodified, because x86_64 support already exists in both the shipped kernel and the shipped `kdump-utils`. |
| [`centos-arm64-readme.md`]({% post_url 2026-10-06-centos-arm64-readme %}) | aarch64 | Full `dnf`-installed CentOS Stream 10 | The same real production path on an architecture where it did **not** already work out of the box -- documents the exact upstream kernel commits that had to be cherry-picked, the `kdump-utils` gate that also had to be patched, and a QEMU/kexec quirk specific to arm64, before this guide's pass criteria could be met. |

If you are implementing this test plan on a new distro or architecture, start from whichever of the three above is closest to your situation, and treat any deviation from this document's [Pass and fail criteria](#pass-and-fail-criteria) as something to explain the same way `centos-arm64-readme.md` explains its own gaps, rather than something to silently work around.

---

## Table of Contents

- [Related implementations in this repository](#related-implementations-in-this-repository)
- [Feature summary](#feature-summary)
  - [Key lifecycle](#key-lifecycle)
- [What to validate](#what-to-validate)
- [Dependencies and Requirements for the Complete Workflow](#dependencies-and-requirements-for-the-complete-workflow)
  - [Platform and kernel](#platform-and-kernel)
  - [Userspace, for the feature itself](#userspace-for-the-feature-itself)
  - [Dump target](#dump-target)
  - [To verify the dump with `crash`](#to-verify-the-dump-with-crash)
  - [Version compatibility: check before you rely on `crash`](#version-compatibility-check-before-you-rely-on-crash)
  - [Kernel limits](#kernel-limits)
- [Recommended test setup](#recommended-test-setup)
  - [Example test target creation](#example-test-target-creation)
- [Configure kdump to use the encrypted target](#configure-kdump-to-use-the-encrypted-target)
  - [1. Update kdump configuration](#1-update-kdump-configuration)
  - [2. Ensure crypt metadata is available to the kdump environment](#2-ensure-crypt-metadata-is-available-to-the-kdump-environment)
  - [3. Rebuild and load the crash kernel](#3-rebuild-and-load-the-crash-kernel)
- [Pre-crash verification](#pre-crash-verification)
  - [Kernel configuration checks](#kernel-configuration-checks)
  - [Runtime verification](#runtime-verification)
- [Core functional test](#core-functional-test)
  - [Objective](#objective)
  - [Execution steps](#execution-steps)
  - [Expected result](#expected-result)
- [Post-crash validation](#post-crash-validation)
  - [Verify dump files](#verify-dump-files)
  - [Validate vmcore readability](#validate-vmcore-readability)
  - [Confirm keys were not dumped in the clear](#confirm-keys-were-not-dumped-in-the-clear)
- [Pass and fail criteria](#pass-and-fail-criteria)
- [Negative and edge-case testing](#negative-and-edge-case-testing)
  - [Reload test](#reload-test)
  - [Missing key description](#missing-key-description)
  - [Missing logon key](#missing-logon-key)
  - [Expired or revoked key](#expired-or-revoked-key)
  - [Hotplug test](#hotplug-test)
  - [Multiple encrypted devices](#multiple-encrypted-devices)
  - [Too many keys](#too-many-keys)
  - [Insufficient crashkernel memory](#insufficient-crashkernel-memory)
  - [Filesystem variation](#filesystem-variation)
  - [LUKS1 versus LUKS2](#luks1-versus-luks2)
  - [Nested storage](#nested-storage)
  - [Multipath, NVMe, and virtio](#multipath-nvme-and-virtio)
  - [Network dump is a different path](#network-dump-is-a-different-path)
  - [Confidential VM and TPM](#confidential-vm-and-tpm)
  - [Alternate panic triggers](#alternate-panic-triggers)
  - [Default action and dump failure](#default-action-and-dump-failure)
- [Architecture-specific suggestions](#architecture-specific-suggestions)
- [Troubleshooting checklist](#troubleshooting-checklist)
- [Suggested test evidence to collect](#suggested-test-evidence-to-collect)
- [Minimal test report template](#minimal-test-report-template)
- [References](#references)

---

## Feature summary

The feature allows the first kernel to preserve active dm-crypt volume key information for use by the crash kernel. After a panic, the second kernel can recover that information from reserved crash memory and use it to access the encrypted dump device.

Without this feature, dumping to a LUKS target has two practical failures:

- The crash kernel often cannot prompt for a passphrase. Unattended servers, remote systems, and confidential VMs with an untrusted virtual keyboard cannot complete unlock. TPM unsealing in the crash kernel can also fail depending on policy.
- LUKS2 defaults to the memory-hard Argon2 KDF. Fedora-class defaults reserve about 256M of crashkernel memory on 4G–64G systems, while re-deriving an Argon2 keyslot can require around 1300M. That reserved memory is unavailable to the first kernel.

Reusing the already-unlocked volume key avoids both the interactive prompt and the second KDF pass.

- Removes the need for interactive passphrase entry in the kdump environment
- Reduces dependency on memory-heavy key derivation during crash capture
- Enables vmcore dumping directly to a LUKS-backed target
- Works with passphrase, TPM-sealed, or other first-kernel unlock methods, as long as the volume key is linked into a kernel keyring
- Stores a kdump copy of the volume key in crash-reserved memory, not in ordinary first-kernel RAM

### Key lifecycle

1. The first kernel unlocks the LUKS volume during boot. systemd or cryptsetup links the volume key into a kernel keyring with `--link-vk-to-keyring` or the crypttab `link-volume-key=` option. The key is expected to expire after a configured time.
2. A userspace helper such as kdump-utils creates key items under `/sys/kernel/config/crash_dm_crypt_keys` so the first kernel knows which keys the crash kernel will need.
3. When the crash image is loaded with `kexec_file_load`, the first kernel copies those logon keys into crash-reserved memory. The copy is placed at a random address in that reserved region. On x86, the page is also marked not-present so the first kernel cannot map it.
4. After panic, the crash-kernel initramfs restores the keys into a user keyring by writing to the `restore` attribute, then unlocks the volume with cryptsetup `--volume-key-keyring`.
5. vmcore is written to the unlocked target and the system reboots into the first kernel.
6. After reboot, the dump target is unlocked again, the vmcore is located, and it is opened with `crash` against a matching debug-info `vmlinux`. This last step is what actually closes the loop — it is the difference between "a file was written" and "the feature produced a usable crash dump."

## What to validate

- The running kernel is built with the expected kdump and dm-crypt support
- `CONFIG_CRASH_DM_CRYPT` is enabled and the configfs interface is present
- The kdump image is loaded with `kexec_file_load`, not legacy `kexec_load`
- The kdump image includes the required storage, crypto, device-mapper, and filesystem components
- cryptsetup in both environments is new enough to support volume-key keyring APIs
- The encrypted target is unlocked in the first kernel and the volume key is linked into a keyring
- configfs key items exist and match the dump-target UUID before the crash kernel is loaded
- The encrypted target is available to the first kernel and configured as the kdump destination
- The crash kernel boots successfully after panic
- Crash-kernel command line or device tree includes the key-location hint (`dmcryptkeys=` on x86_64)
- The encrypted target is unlocked automatically in the crash kernel
- There is no passphrase prompt and Argon2 is not re-run in the crash kernel
- The vmcore is written successfully and is readable after reboot
- The saved key material is excluded from the dumped vmcore
- **The vmcore actually opens in `crash`** — with a matching debug-info `vmlinux` and a `crash` build new enough for the kernel under test — and shows the expected panic reason, a sane backtrace, and a complete kernel log. "The file exists and is non-zero size" is not sufficient evidence by itself.

## Dependencies and Requirements for the Complete Workflow

This is the complete dependency list for the full workflow: getting the encrypted dump written, and then proving the dump is actually analyzable by opening it with `crash`. Treat every item here as a hard requirement — a missing item in the second half of this list ("To verify the dump with `crash`") produces a vmcore that exists but that nobody can read, which is a fail under [What to validate](#what-to-validate) above, not a partial pass.

### Platform and kernel

- A test system on x86_64, aarch64, or ppc64le. x86_64 is the only architecture upstream kdump documentation currently describes for this feature; treat aarch64/ppc64le as backport-dependent.
- Kernel 6.16 or later, or a product kernel that backports `CONFIG_CRASH_DM_CRYPT`.
- Kernel config: `CONFIG_CRASH_DM_CRYPT`, `CONFIG_CRASH_DUMP`, `CONFIG_KEXEC_FILE`, `CONFIG_DM_CRYPT`, `CONFIG_KEYS`, and built-in (not module) `CONFIG_CONFIGFS_FS`.
- A configured `crashkernel=` boot parameter with enough reserved memory for the crash kernel. Volume-key reuse means this does **not** need the large extra reservation Argon2 re-derivation would otherwise require — if your sizing guidance still assumes that extra memory, the key-reuse path may not be active (see [Troubleshooting checklist](#troubleshooting-checklist)).
- Console access (serial, remote console, or hypervisor console) for observing the panic through crash-kernel boot. Needed for both the feature test and the `crash` validation step below, since a hang before vmcore save looks identical to a slow dump without one.

### Userspace, for the feature itself

- kexec-tools, with `kexec_file_load` support (not just legacy `kexec_load`).
- kdump-utils, or equivalent `kdumpctl`-style tooling.
- cryptsetup 2.7 or later, in **both** the first kernel and the kdump initramfs — needed for `--link-vk-to-keyring` in the first kernel and `--volume-key-keyring` in the crash kernel.
- systemd 256 or later, if using the crypttab `link-volume-key=` option.
- dracut (or your distribution's initramfs builder), configured to include cryptsetup, dm-crypt, and the dump filesystem's driver in the kdump image.
- makedumpfile.

### Dump target

- A persistent, real block device — a dedicated disk or partition. The crash kernel does not inherit the first kernel's loop-device mapping, so a loop-backed target must not be used; it will appear to work right up until the panic, and then fail to produce a usable dump.
- LUKS2 header. LUKS2 is required for `link-volume-key=` and the cryptsetup 2.7 keyring APIs; LUKS1 is not automatically covered (see [LUKS1 versus LUKS2](#luks1-versus-luks2)).

### To verify the dump with `crash`

A dump that exists but cannot be opened is not evidence the feature works — it is only evidence that a file got written. These are required, not optional, for that final check:

- **A `vmlinux` with debugging information, from the exact build that produced the panicking kernel.** This means the uncompressed kernel image (not `bzImage`/`Image`, which are compressed boot stubs with no debug info), compiled with `CONFIG_DEBUG_INFO=y` (plus `CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y`). On RHEL/Fedora-family systems this is normally the matching `kernel-debuginfo` package — install with `debuginfo-install kernel-$(uname -r)` or `dnf debuginfo-install kernel` — which places `vmlinux` at `/usr/lib/debug/lib/modules/$(uname -r)/vmlinux`. For a custom-built or cross-compiled kernel, this means explicitly enabling debug info and keeping the `vmlinux` produced by that exact build; a fast build with debug info disabled (a common choice, since it shrinks build time and image size) still produces a perfectly valid, encrypted vmcore, but that vmcore cannot later be opened in `crash` without a matching debug `vmlinux`.
- **The `crash` binary itself, matching the dump's architecture**, from one of:
  - A distro package (`dnf install crash` on Fedora/RHEL/CentOS, `apt-get install crash` on Debian/Ubuntu) — but confirm the packaged version is new enough for the kernel under test; see the version-compatibility note just below.
  - Built from source ([crash-utility/crash](https://github.com/crash-utility/crash)) if the packaged version is too old, or if you need a fix that has not been released yet.
- **Build dependencies, only if building `crash` from source.** Its `Makefile` downloads and compiles its own patched copy of GDB as part of the build: `git`, `gcc`, `gcc-c++`, `make`, `bison`, `flex`, `ncurses-devel`, `zlib-devel`, `bzip2-devel`, `xz-devel`, `lzo-devel`, `snappy-devel`, `libzstd-devel`, `elfutils-libelf-devel`, `elfutils-devel`, `gmp-devel`, `mpfr-devel`, `libmpc-devel`, `texinfo`, `wget`, and **`patch`**. `patch` is the easiest one to miss: if it is not installed, the build applies no patch, prints no error at that point, and only fails much later with a generic `"crash" build failed` / `gdb_merge: Error 1` — giving no indication that a missing `patch` binary was the actual cause.
  - This build takes roughly 12-13 minutes (it compiles a full patched GDB 16.2). To avoid paying that cost on every validation run, [`crash-tool/Dockerfile`](https://github.com/mukeshpilaniya/kernel-qemu-lab/blob/main/crash-tool/Dockerfile) builds it once into a persistent local image (`crash-tool:fedora42`); every subsequent `crash` invocation then just `docker run`s that cached image, with no recompilation. See [vanilla-x86-readme.md]({% post_url 2026-10-02-vanilla-x86-readme %}), Section 12, Step 4.
- **The runtime library `elfutils-debuginfod-client`** (provides `libdebuginfod.so.1`), if running a freshly built `crash` binary in a minimal environment that does not already have it installed.
- **A way to reach the raw encrypted bytes of the dump target outside the panicked system**, if validating from a different host or container rather than from the booted-back-up first kernel: `cryptsetup` and `losetup` (or equivalent) to open the LUKS volume with the original passphrase, keyfile, or TPM-sealed secret, then mount the filesystem to reach the `vmcore` file.

### Version compatibility: check before you rely on `crash`

`crash` releases lag behind kernel internals, particularly slab-allocator structures. A `crash` build that predates a given kernel's internal changes can fail immediately, during its own startup, with an error such as:

```text
please wait... (gathering kmem slab cache data)
crash: invalid structure member offset: kmem_cache_s_num
       FILE: memory.c  LINE: 9988  FUNCTION: kmem_cache_init()
```

This is a known, named upstream issue class — not specific to this feature, to encryption, or to anything about the vmcore's validity — but it is easy to misread as a bad dump. Confirm the `crash` version in use is new enough for the kernel's release before concluding the dump itself failed; if it is not, building from upstream git source (see above) is the fix. A worked example of hitting exactly this failure, diagnosing it, and resolving it is documented in [vanilla-x86-readme.md]({% post_url 2026-10-02-vanilla-x86-readme %}), Section 12.

### Kernel limits

| Limit | Value | Test implication |
| --- | --- | --- |
| Maximum registered keys | 128 | Registering more than 128 keys must fail |
| Maximum key size | 256 bytes | Unusual volume-key sizes above this must fail cleanly |
| Maximum key description length | 128 characters | Oversized descriptions must be rejected |
| First-kernel key type | logon | Userspace must not be able to read the linked volume key |
| Crash-kernel restored key type | user | cryptsetup `--volume-key-keyring` can consume it |

## Recommended test setup

Use a dedicated test disk or partition as the encrypted kdump target -- a real block device, not a loop-backed file. The crash kernel does not inherit the first kernel's loop-device mapping, so a loop-backed target is a weak crash-capture target: the backing file may also live on a filesystem that is not available after panic.

### Example test target creation

Create a LUKS2 volume on the real target device. LUKS2 is the intended format for `link-volume-key=` and the cryptsetup 2.7 keyring APIs. Substitute your own target device for `$DUMP_DEV` (e.g. `/dev/vdb`, or a dedicated disk/partition on bare metal):

```sh
DUMP_DEV=/dev/vdb
cryptsetup luksFormat --type luks2 "$DUMP_DEV"
cryptsetup luksUUID "$DUMP_DEV"
cryptsetup open "$DUMP_DEV" kdump_luks
mkfs.ext4 /dev/mapper/kdump_luks
mkdir -p /mnt/kdump
mount /dev/mapper/kdump_luks /mnt/kdump
```

Record the LUKS UUID; kdump configuration and configfs key names should use that UUID.

Confirm the header and KDF:

```sh
cryptsetup luksDump "$DUMP_DEV"
cryptsetup --version
```

Expect LUKS2. Argon2id or Argon2i in the keyslot is the interesting case, because that is what this feature is meant to avoid in the crash kernel.

## Configure kdump to use the encrypted target

### 1. Update kdump configuration

Edit `/etc/kdump.conf` so the dump is written to the filesystem on the unlocked encrypted device. Prefer UUID-based device identification over a transient mapper name.

```
ext4 UUID=<luks-fs-uuid>
path /
```

or, if the mapper name is stable in the crash environment:

```
ext4 /dev/mapper/kdump_luks
path /
```

Useful optional settings:

```
core_collector makedumpfile -l --message-level 1 -d 31
extra_bins /usr/sbin/cryptsetup
extra_modules dm_mod dm_crypt
default reboot
```

### 2. Ensure crypt metadata is available to the kdump environment

Depending on distribution tooling, add the encrypted mapping details through the supported kdump or dracut workflow. If available in your environment, use:

```sh
kdumpctl setup-crypttab
```

That command adds the `link-volume-key=` option to `/etc/crypttab` so the volume key is linked into a kernel keyring at activation. The option is a LUKS2 systemd 256+ feature. `kdumpctl setup-crypttab` is documented as x86_64-only for now.

This step is optional if `kdump.service` already starts without a passphrase prompt. Confirm by running `kdumpctl restart`. If the helper asks for a passphrase to unlock the dump target, run `kdumpctl setup-crypttab` and reopen or reboot so the crypttab change takes effect.

If that command is not available, ensure the kdump initramfs contains the required cryptsetup, device-mapper, and filesystem support needed to recognize the target, and perform the keyring and configfs steps manually.

Manual first-kernel keyring link, using the LUKS UUID:

```sh
cryptsetup open --link-vk-to-keyring "@u::%logon:cryptsetup:<luks-uuid>" "$DUMP_DEV" kdump_luks
```

Register the key with the first kernel before loading the crash image. The kernel reads **logon** keys by description at `kexec_file_load` time. The description must be set; loading kdump before writing it has caused kernel failures.

```sh
mkdir /sys/kernel/config/crash_dm_crypt_keys/<luks-uuid>
echo cryptsetup:<luks-uuid> > /sys/kernel/config/crash_dm_crypt_keys/<luks-uuid>/description
cat /sys/kernel/config/crash_dm_crypt_keys/count
```

Inspect the configfs tree:

```sh
find /sys/kernel/config/crash_dm_crypt_keys -ls
```

### 3. Rebuild and load the crash kernel

```sh
kdumpctl estimate
kdumpctl rebuild
systemctl restart kdump
kdumpctl status
kdumpctl showmem
```

Before triggering a crash, confirm that kdump reports the crash kernel as loaded successfully. `kdumpctl estimate` should no longer need a large extra "LUKS required size" reservation when volume-key reuse is in effect. If estimate still recommends hundreds of extra megabytes for Argon2, the key-reuse path is not active and the crash kernel may still try to derive the key.

## Pre-crash verification

### Kernel configuration checks

```sh
grep CONFIG_CRASH_DM_CRYPT /boot/config-$(uname -r)
grep CONFIG_CRASH_DUMP /boot/config-$(uname -r)
grep CONFIG_KEXEC_FILE /boot/config-$(uname -r)
grep CONFIG_DM_CRYPT /boot/config-$(uname -r)
grep CONFIG_CONFIGFS_FS /boot/config-$(uname -r)
grep CONFIG_KEYS /boot/config-$(uname -r)
```

Expect `CONFIG_CRASH_DM_CRYPT=y` and `CONFIG_CONFIGFS_FS=y`. configfs must be built-in for the key interface to exist early enough.

### Runtime verification

- Confirm the encrypted mapping is active in the first kernel
- Confirm the dump target filesystem is mounted and writable
- Confirm `/etc/crypttab` contains `link-volume-key=` for the dump target
- Confirm configfs key count is at least 1 and the description matches the LUKS UUID
- Confirm kdump loaded through the file-based kexec path
- Review dmesg and service logs for kdump loading messages and dm-crypt key load messages

```sh
lsblk -o NAME,UUID,TYPE,MOUNTPOINT
dmsetup ls
cryptsetup status kdump_luks
mount | grep kdump
keyctl show @u || true
cat /sys/kernel/config/crash_dm_crypt_keys/count
dmesg | grep -iE 'kdump|dm.crypt|dmcrypt'
journalctl -u kdump --no-pager
cat /proc/cmdline
lsinitrd /boot/initramfs-*kdump.img | grep -iE 'cryptsetup|dm-crypt|crypttab'
```

A writable dump check before panic:

```sh
touch /mnt/kdump/.kdump-write-test && rm /mnt/kdump/.kdump-write-test
```

## Core functional test

### Objective

Verify that a panic causes the crash kernel to boot, automatically access the encrypted dump target, and save a valid vmcore.

### Execution steps

1. Start from the running production kernel with the encrypted target already unlocked and kdump loaded.
2. Make sure all important logs are captured through serial console, remote console, or hypervisor console.
3. Trigger a controlled kernel panic.

```sh
echo c > /proc/sysrq-trigger
```

Alternatively, use the kdump-utils helper if present:

```sh
kdumpctl test
```

`kdumpctl test --force` skips the confirmation prompt and is intended for automation only.

4. Observe the system transition into the crash kernel.
5. Confirm the crash kernel received the key location. On x86_64 look for `dmcryptkeys=0x...` on the crash-kernel command line, alongside `elfcorehdr=`.
6. Confirm there is no passphrase prompt in the kdump environment.
7. Confirm the dump target is unlocked and the vmcore save operation completes.
8. Allow the system to reboot back into the normal kernel.

### Expected result

- The crash kernel boots successfully
- The encrypted device is accessible without manual intervention
- vmcore and related dump files are present on the target after reboot
- The dump operation completes within expected time for the system size and storage speed
- Crash-kernel logs show key restore and cryptsetup open by volume-key keyring, not a passphrase or Argon2 unlock
- After reboot, kdump can be reloaded and the feature still works
- **The vmcore opens in `crash`** and shows the expected panic string, a plausible backtrace through the panic trigger, and a complete kernel log — see [Validate vmcore readability](#validate-vmcore-readability)

## Post-crash validation

### Verify dump files

```sh
cryptsetup open "$DUMP_DEV" kdump_luks
mount /dev/mapper/kdump_luks /mnt/kdump
find /mnt/kdump -maxdepth 3 -type f
ls -l /mnt/kdump/*/
```

Typical artifacts include `vmcore`, `vmcore-dmesg.txt`, and kdump log files. Record sizes; a tiny or zero-length vmcore is a fail.

### Validate vmcore readability

This is the step [Dependencies and Requirements](#dependencies-and-requirements-for-the-complete-workflow) is mostly about, and the step most test plans short-circuit by only checking that the file exists. Do not skip it.

```sh
crash /usr/lib/debug/lib/modules/$(uname -r)/vmlinux /mnt/kdump/*/vmcore
```

If `/usr/lib/debug/lib/modules/$(uname -r)/vmlinux` does not exist, the matching debuginfo was never installed — install it (`debuginfo-install kernel-$(uname -r)` or equivalent) before concluding anything about the dump. A debug-less `vmlinux`, or a `vmlinux` from a different build than the one that panicked, is not a substitute; `crash` either refuses to start or produces nonsense output in that case.

Once `crash` opens, confirm with a few commands at the prompt, not just a clean exit:

```text
crash> sys
crash> bt
crash> log
crash> quit
```

- `sys` should show the correct `RELEASE`/`VERSION` for the kernel under test and a `PANIC:` line matching how the panic was actually triggered.
- `bt` should show a plausible call stack leading through the panic trigger (for example, `sysrq_handle_crash` for a SysRq-triggered test) — not a corrupted or truncated stack.
- `log` should reproduce the complete kernel boot-through-panic log, including the panic message.

If `crash` instead fails immediately with something like `invalid structure member offset: kmem_cache_s_num`, that is a **version-compatibility problem between `crash` and this kernel**, not evidence the vmcore is bad — see [Version compatibility](#version-compatibility-check-before-you-rely-on-crash). Confirm with the independent check below before assuming the dump itself is at fault.

As an independent cross-check that does not depend on `crash` or a matching `vmlinux` at all, confirm the panic reason directly from the dump's embedded VMCOREINFO:

```sh
makedumpfile --dump-dmesg /mnt/kdump/*/vmcore /tmp/vmcore-dmesg.txt
grep -iE 'sysrq|panic|SysRq' /tmp/vmcore-dmesg.txt
```

This can still succeed even when `makedumpfile` itself warns `The kernel version is not supported` for a very recent kernel — the warning means its own kernel-version table is out of date, not that the extraction failed. If this independent check shows the correct panic reason and a complete log while `crash` fails to open the same file, that is strong evidence the problem is `crash`'s version compatibility, not the dump.

### Confirm keys were not dumped in the clear

The key copy lives in crash-reserved memory and should be excluded from `/proc/vmcore`. After opening the dump, search crash-kernel logs for key-load addresses and confirm that range is not present as ordinary dumped pages. A fail would be finding the restored volume-key payload in the vmcore.

## Pass and fail criteria

| Area | Pass criteria | Fail indicators |
| --- | --- | --- |
| Crash kernel load | Kdump service loads the crash kernel without errors | Kdump service fails, missing initramfs content, or insufficient reserved memory |
| File-based kexec | Crash image is loaded with `kexec_file_load` | Legacy `kexec_load` only; keys are never copied |
| Key registration | configfs count is correct and descriptions are set before load | Missing description, wrong UUID, or `No such logon key` |
| Encrypted target access | Crash kernel accesses the LUKS-backed target automatically | Passphrase prompt appears, target not found, or crypt mapping fails |
| KDF avoidance | Crash kernel does not run Argon2 / large KDF | OOM, cryptsetup stall, or estimate still requires ~512M+ extra LUKS memory |
| Dump generation | vmcore is written to the configured target path | No vmcore, partial dump, write errors, or reboot before save completes |
| Dump integrity | vmcore opens correctly with analysis tools | Corrupt, truncated, or unreadable dump output |
| `crash` validation | `crash` opens the vmcore against a matching debug-info `vmlinux` and `sys`/`bt`/`log` show the correct panic, a plausible backtrace, and a complete log | `vmlinux` missing/mismatched, `crash` too old for the kernel (see [Version compatibility](#version-compatibility-check-before-you-rely-on-crash)), or `crash` never actually run against the dump |
| Key exclusion | Volume-key copy is not in the dumped vmcore | Key material recoverable from vmcore |

## Negative and edge-case testing

### Reload test

Reload the crash kernel configuration and verify the feature still works after a fresh kdump load.

```sh
kdumpctl restart
```

Also test `kdumpctl reload`, which reloads the crash image without rebuilding initramfs.

### Missing key description

Register a configfs key directory but do not write `description`, then try `kdumpctl restart`. This must fail cleanly. Earlier kernels could crash if userspace loaded kdump before writing the description.

### Missing logon key

Register a description that does not exist in the keyring. kdump load must fail with a logon-key lookup error rather than loading a crash image that cannot unlock the target.

### Expired or revoked key

If the linked volume key expires or is revoked before kdump is loaded, loading must fail. Re-open the volume with `--link-vk-to-keyring` and reload kdump.

### Hotplug test

If your platform supports CPU or memory hotplug, change the system topology after loading kdump, then trigger a crash and verify the encrypted target remains usable by the crash kernel.

If userspace reloads the crash image after hotplug, reuse keys already saved in reserved memory instead of requiring the logon key to still be present:

```sh
echo true > /sys/kernel/config/crash_dm_crypt_keys/reuse
```

Kernel documentation also mentions `/sys/kernel/config/crash_dm_crypt_key/reuse` (singular). Check which path exists on the kernel under test. If `CONFIG_CRASH_HOTPLUG` updates elfcorehdr in place, a full kdump reload may not be required; still confirm the encrypted dump path keeps working.

### Multiple encrypted devices

Open more than one LUKS device in the first kernel and verify the intended kdump target is still handled correctly. This helps detect issues in key selection or preserved key-table handling. Register only the dump-target key, then register both keys, and confirm the crash kernel unlocks the configured target.

### Too many keys

Attempt to create more than 128 configfs key items. The kernel must reject additional keys.

### Insufficient crashkernel memory

Reduce the reserved crashkernel memory in a separate test cycle to identify the minimum reliable reservation for your platform and storage stack.

```sh
kdumpctl estimate
kdumpctl showmem
```

With volume-key reuse, the working reservation should be close to a normal kdump reservation, not the Argon2-sized reservation. Run insufficient-memory tests only in controlled environments. A too-small crashkernel reservation can cause the crash kernel to fail before dump capture starts.

### Filesystem variation

If your support matrix allows it, repeat the test with the actual filesystem used by your product or environment rather than relying only on ext4. XFS is common on RHEL-class systems. Also try the dump path at a subdirectory (`path /var/crash`) rather than `/`.

### LUKS1 versus LUKS2

Repeat once with LUKS1 if that format is still in the support matrix. `link-volume-key=` is a LUKS2 systemd option. A LUKS1 target may still work if cryptsetup can link the volume key, but do not assume the automated crypttab path applies.

### Nested storage

If production uses LVM on LUKS or LUKS on LVM, test that stack. The crash initramfs must include both dm-crypt and LVM, and device discovery order must still find the dump filesystem.

### Multipath, NVMe, and virtio

On systems that boot from multipath, NVMe, or virtio, confirm the crash kernel has the same storage drivers and that the LUKS UUID still resolves. Missing storage modules look like "target not found" even when key restore succeeded.

### Network dump is a different path

This feature is for a local LUKS-backed dump device. SSH/NFS dump targets do not need `CONFIG_CRASH_DM_CRYPT`. Do not treat a successful NFS dump as coverage for encrypted local disks.

### Confidential VM and TPM

On confidential VMs, confirm that the crash kernel does not need to unseal a TPM key and does not depend on a virtual keyboard. First-kernel TPM or passphrase unlock plus key reuse is the intended path. AMD SEV and similar memory-encrypted guests need the crash kernel to read the reserved key page through the old-memory helper; include at least one encrypted-guest run if that is in the product matrix.

### Alternate panic triggers

Repeat the functional test with more than one panic source when the harness allows it:

```sh
echo c > /proc/sysrq-trigger
echo 1 > /proc/sys/kernel/panic_on_oops
```

NMI watchdog or `kdumpctl test` are also valid if supported. The unlock path must not depend on sysrq specifically.

### Default action and dump failure

If the encrypted target cannot be unlocked, confirm the configured kdump default action (`reboot`, `dump_to_rootfs`, `poweroff`, `halt`, `shell`) still behaves. A hang at a passphrase prompt is a fail even if a later reboot recovers.

## Architecture-specific suggestions

- **x86_64:** This is the architecture documented by upstream kdump.rst for `CONFIG_CRASH_DM_CRYPT`. Validate both BIOS and UEFI if relevant. Confirm `dmcryptkeys=` is appended to the crash-kernel command line. `kdumpctl setup-crypttab` is currently documented as helpful on x86_64 only. A local QEMU x86_64 run on the vanilla busybox guest is in [vanilla-x86-readme.md]({% post_url 2026-10-02-vanilla-x86-readme %}).
- **aarch64:** Test the kernel variants you support, including page-size differences where applicable. Key location is passed with a `linux,dmcryptkeys` device-tree property in the arm64/ppc64le enablement patches, not the x86 command-line parameter. Confirm that property is reserved so the crash kernel does not reuse the key page for other allocations.
- **ppc64le:** Validate on the target virtualization model or bare-metal platform used in production, such as PowerVM, KVM, or PowerNV. FADump is a different capture path; `kdumpctl test` notes that fadump is not supported by that helper.

## Troubleshooting checklist

- Check whether the crash kernel initramfs includes cryptsetup, dm-crypt, filesystem, and storage drivers
- Verify cryptsetup is 2.7+ in both the first kernel and the kdump image
- Verify the dump target path in `/etc/kdump.conf` matches the mounted filesystem inside the crash environment
- Confirm `/etc/crypttab` has `link-volume-key=` and that the first kernel actually has a logon key before `kexec_file_load`
- Confirm configfs items exist under `/sys/kernel/config/crash_dm_crypt_keys` and that `count` is non-zero
- Confirm kdump is using `kexec_file_load`
- Review journal and dmesg logs from the first kernel before panic for kdump preparation errors, including `Failed to load dm crypt keys` and `No such logon key`
- Use console capture to identify whether failure occurs during device discovery, crypt activation, or vmcore writing
- On x86, confirm `dmcryptkeys=` is present in the crash kernel; on arm64/ppc64le, confirm `linux,dmcryptkeys`
- In the crash kernel, restore is documented as `echo yes > /sys/kernel/crash_dm_crypt_keys/restore`. Current kernels expose the restore attribute through configfs at `/sys/kernel/config/crash_dm_crypt_keys/restore`. kdump-utils should do this automatically.
- Confirm the target device is not dependent on userspace components missing from the kdump image
- If cryptsetup runs Argon2 in the crash kernel, the reuse path was skipped and crashkernel memory is likely too small
- If `crash` fails to open the vmcore with `invalid structure member offset: ...` immediately after "gathering kmem slab cache data," that is a `crash`-version-vs-kernel-version compatibility gap, not necessarily a bad dump — cross-check with `makedumpfile --dump-dmesg` (which does not need `crash` or a matching `vmlinux`) before concluding the dump is corrupt
- If building `crash` from source fails late, with a generic `"crash" build failed` / `gdb_merge: Error 1` and no other obvious error, check specifically whether `patch` is installed — its absence makes the build skip a required GDB patch silently, with no error at the point it actually happens
- If `crash` cannot find `/usr/lib/debug/lib/modules/$(uname -r)/vmlinux`, the kernel-debuginfo package was never installed, or a different kernel release than the one that panicked is running now — a vmlinux from any other build will not line up with this vmcore

## Suggested test evidence to collect

- Kernel version, architecture, and config output showing required options
- `cryptsetup --version` and `cryptsetup luksDump` of the dump target
- `/etc/crypttab` and `/etc/kdump.conf`
- configfs tree and `count` before crash
- `kdumpctl status`, `kdumpctl estimate`, and `kdumpctl showmem` before crash
- `lsinitrd` excerpt showing cryptsetup and dm-crypt in the kdump image
- Console logs from panic through crash-kernel boot, including any `dmcryptkeys=` line
- List of dump artifacts written to the encrypted target
- `crash --version`, and whether it came from a distro package or an upstream source build
- Full `crash` session output for `sys`, `bt`, and `log` against the generated vmcore — not just "it opened"
- `makedumpfile --dump-dmesg` output showing the panic, as an independent cross-check of `crash`'s result

## Minimal test report template

| Field | Details |
| --- | --- |
| Kernel build | Record exact kernel version and architecture under test |
| Feature availability | Record `CONFIG_CRASH_DM_CRYPT`, configfs presence, and kexec file-load path |
| Userspace | Record kdump-utils, cryptsetup, and systemd versions |
| Platform | Record hardware, VM type, firmware mode, confidential-compute mode, and storage details |
| Encrypted target | Record LUKS version, UUID, PBKDF, filesystem, and mount path used for kdump |
| Key setup | Record crypttab `link-volume-key=`, configfs count, and key description |
| Crashkernel | Record `crashkernel=` value and `kdumpctl estimate` output |
| Crash trigger | Record the method used to trigger the panic |
| Observed behavior | Record whether auto-unlock worked, whether a passphrase appeared, and whether vmcore was saved |
| `crash` validation | Record `crash` version, debug-info `vmlinux` source, and whether `sys`/`bt`/`log` showed the correct panic — this is a separate pass/fail from "vmcore was saved" |
| Result | Record pass or fail with supporting logs |

## References

- [Kdump documentation: write the dump file to an encrypted disk volume](https://docs.kernel.org/admin-guide/kdump/kdump.html)
- [CONFIG_CRASH_DM_CRYPT](https://cateee.net/lkddb/web-lkddb/CRASH_DM_CRYPT.html)
- [kdumpctl(8)](https://www.mankier.com/8/kdumpctl)
- [kdump.conf](https://www.mankier.com/5/kdump.conf)
- [crypttab(5) `link-volume-key=`](https://man7.org/linux/man-pages/man5/crypttab.5.html)
- [cryptsetup 2.7 `--link-vk-to-keyring` / `--volume-key-keyring`](https://www.kernel.org/pub/linux/utils/cryptsetup/v2.7/v2.7.0-ReleaseNotes)
- [crash-utility/crash](https://github.com/crash-utility/crash) — source, for when the distro-packaged `crash` is too old for the kernel under test
- [RHEL: running kdump on systems with encrypted disk](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/managing_monitoring_and_updating_the_kernel/configuring-kdump-on-the-command-line)
- [RHEL: Enabling kdump](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/managing_monitoring_and_updating_the_kernel/enabling-kdump)
- [RHEL: Supported kdump configurations and targets](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/managing_monitoring_and_updating_the_kernel/supported-kdump-configurations-and-targets)
- [RHEL: Firmware assisted dump mechanisms](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/managing_monitoring_and_updating_the_kernel/firmware-assisted-dump-mechanisms)
- [RHEL:Analyzing a core dump](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/managing_monitoring_and_updating_the_kernel/analyzing-a-core-dump)
- [RHEL:Automating crash dump analysis](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/managing_monitoring_and_updating_the_kernel/automating-crash-dump-analysis)
- [RHEL: Using early kdump to capture boot time crashes](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/managing_monitoring_and_updating_the_kernel/using-early-kdump-to-capture-boot-time-crashes)
