---
title: Centos-arm64 - Validating CONFIG_CRASH_DM_CRYPT on CentOS 10
published: true
categories: [kdump]
tags: [kdump,kexec,luks,dm-crypt,qemu]
---

# centos-arm64: Validating CONFIG_CRASH_DM_CRYPT on CentOS 10

This directory holds the build output for the aarch64 counterpart of
[`centos-x86-readme.md`]({% post_url 2026-10-06-centos-x86-readme %}): a kernel compiled from the real
`centos-stream-10/src` tree, with a full `dnf`-installed CentOS Stream 10
rootfs (systemd, all kernel modules, real `kexec-tools`/`kdump-utils`), set
up to exercise the same `CONFIG_CRASH_DM_CRYPT` LUKS-encrypted kdump target
that [`vanilla-x86-readme.md`]({% post_url 2026-10-02-vanilla-x86-readme %})
exercises on x86_64, and that `centos-x86-readme.md` exercises on the
real CentOS Stream 10 x86_64 distro.

**Unlike `centos-x86`, this did not just work out of the box.** Getting
here required two separate, independently-discovered gaps to be closed --
one in the kernel, one in userspace -- neither of which exists on x86_64.
[The missing pieces](#the-missing-pieces-why-this-was-not-a-copy-paste-of-centos-x86)
below covers both in full; everything after that section describes the
now-working end state.

## Table of Contents

- [The missing pieces: why this was not a copy-paste of centos-x86](#the-missing-pieces-why-this-was-not-a-copy-paste-of-centos-x86)
  - [1. The kernel gap: three upstream commits absent from centos-stream-10/src](#1-the-kernel-gap-three-upstream-commits-absent-from-centos-stream-10src)
  - [2. The userspace gap: kdump-utils' own x86_64-only gates](#2-the-userspace-gap-kdump-utils-own-x86_64-only-gates)
  - [3. The QEMU/kexec gap: EL2 is required for the crash-kernel jump, not just HVF](#3-the-qemukexec-gap-el2-is-required-for-the-crash-kernel-jump-not-just-hvf)
  - [4. A related, NOT-exercised-by-this-test gap: kdump-anaconda-addon](#4-a-related-not-exercised-by-this-test-gap-kdump-anaconda-addon)
- [Why centos-arm64 exists alongside vanilla-arm64 and centos-x86](#why-centos-arm64-exists-alongside-vanilla-arm64-and-centos-x86)
- [Script naming](#script-naming)
- [Directory layout (this folder, after a full build)](#directory-layout-this-folder-after-a-full-build)
- [Requirements](#requirements)
- [Build pipeline](#build-pipeline)
- [Script-by-script walkthrough](#script-by-script-walkthrough)
- [Step by step: what actually happens, start to finish](#step-by-step-what-actually-happens-start-to-finish)
- [Running the LUKS kdump test](#running-the-luks-kdump-test)
- [Validating the result: what this project's own run actually produced](#validating-the-result-what-this-projects-own-run-actually-produced)
- [Re-running against the same disk image](#re-running-against-the-same-disk-image)

## The missing pieces: why this was not a copy-paste of centos-x86

`centos-x86`'s `CONFIG_CRASH_DM_CRYPT` support needed zero kernel source
changes and zero userspace changes -- the stock CentOS Stream 10 kernel
tree and the stock `kdump-utils` package both already fully supported it
on x86_64. Before any of the ARM64 work below could even be attempted, two
independent gaps had to be found and closed, plus one QEMU-level quirk
had to be worked around. All three are specific to ARM64; none apply to
`centos-x86`.

### 1. The kernel gap: three upstream commits absent from centos-stream-10/src

`centos-stream-10/src`'s own git history (`git log --author="Coiby Xu"`)
has the full *x86* half of `CONFIG_CRASH_DM_CRYPT`'s history --
`x86/crash: pass dm crypt keys to kdump kernel`, `crash_dump: store dm
crypt keys in kdump reserved memory`, etc. -- but stops there. A parallel
search of `centos-stream-10/linux` (the plain upstream torvalds tree also
checked out in this project, see `../../README.md`) with the same
`--author` filter turns up a later 3-patch series that `src` does **not**
have:

| Order | Commit (upstream `linux`) | Subject |
| --- | --- | --- |
| 1 | `03738dd159db` | crash_dump/dm-crypt: don't print in arch-specific code |
| 2 | `fe74eb289163` | crash: align the declaration of `crash_load_dm_crypt_keys` with `CONFIG_CRASH_DM_CRYPT` |
| 3 | `e3a84be1ec2f` | **arm64,ppc64le/kdump: pass dm-crypt keys to kdump kernel** |

This is literally titled, in its own cover letter, **"kdump: Enable
LUKS-encrypted dump target support in ARM64 and PowerPC" (v5)** -- patch 3
is the actual enablement: it adds a new device-tree property,
`linux,dmcryptkeys` (the arm64/ppc64le analogue of the already-existing
`linux,elfcorehdr` property), so that the kdump kernel -- which on these
architectures boots via a kernel-generated device tree rather than x86's
`boot_params`/`setup_data` structures -- can find the dm-crypt keys the
first kernel stashed in crash-reserved memory. Patches 1-2 are small,
arch-agnostic cleanups patch 3 needed as prerequisites (fixing a
`CONFIG_CRASH_DUMP=y`+`CONFIG_CRASH_DM_CRYPT=n` build break, and removing
an arch-specific `pr_err` so the new arm64/ppc64le call site doesn't need
one). Patch 3 touches exactly:

```text
arch/arm64/kernel/machine_kexec_file.c |  4 ++
arch/powerpc/kexec/elf_64.c            |  4 ++
drivers/of/fdt.c                       | 21 ++
drivers/of/kexec.c                     | 19 ++
```

All three were cherry-picked (`git am`) into `centos-stream-10/src` as-is
and applied **cleanly** with no conflicts, confirmed with `git apply
--check` before committing them:

```text
08594d847c9f arm64,ppc64le/kdump: pass dm-crypt keys to kdump kernel
26ba686c3a4a crash: align the declaration of crash_load_dm_crypt_keys with CONFIG_CRASH_DM_CRYPT
50a3141c3141 crash_dump/dm-crypt: don't print in arch-specific code
431596d168bc [redhat] kernel-6.12.0-273.el10          <- previous HEAD
```

`build-centos-arm64-kernel.sh` builds from this now-patched tree; nothing
in the build script itself does anything ARM64-specific to compensate --
once the commits are in, `CONFIG_CRASH_DM_CRYPT=y` (already on in the
stock `redhat/configs/kernel-6.12.0-aarch64.config`, same as x86's config)
Just Works on the kernel side, confirmed end-to-end in
[Validating the result](#validating-the-result-what-this-projects-own-run-actually-produced)
below.

### 2. The userspace gap: kdump-utils' own x86_64-only gates

Even with the kernel patched, the first full test run
([what failed, and why](#what-failed-on-the-first-run)) stalled with:

```text
kdump: WARNING: Currently only x86_64 supported
...
[WARN] reuse write failed — keys may not be in reserved memory
=== configfs ===
count=0
[WARN] FAIL  could not set /sys/kernel/config/crash_dm_crypt_keys/reuse (keys not saved?)
=== crypttab ===
luks-20ffe883-... UUID=20ffe883-... /root/kdump-luks.key luks
[WARN] FAIL  crypttab missing link-volume-key
```

Grepping the installed `kdump-utils-1.0.61-2.el10.aarch64` package itself
(not this project's own scripts) found the actual root cause -- three
**independent** `uname -m` gates, all hardcoded to x86_64 only, in the
real RHEL-shipped `/usr/bin/kdumpctl` and
`/usr/lib/dracut/modules.d/99kdumpbase/module-setup.sh`:

| Function | File | What it's responsible for | Effect when gated off |
| --- | --- | --- | --- |
| `prepare_luks()` | `kdumpctl` (~line 1184) | Populates `/sys/kernel/config/crash_dm_crypt_keys/<uuid>/description` *before* `kexec_file_load`, telling the kernel which keys to copy into crash-reserved memory | configfs `count` stays 0 forever -- there is nothing for the kernel to save, regardless of whether the DT `dmcryptkeys` plumbing from patch 3 above works correctly |
| `setup_crypttab()` | `kdumpctl` (~line 1272) | Writes the `link-volume-key=` option into `/etc/crypttab` | crypttab is left with `04-configure-kdump.sh`'s provisional plaintext-keyfile-path entry, never upgraded |
| `kdump_check_crypt_targets()` | `99kdumpbase/module-setup.sh` (~line 1118) | Builds the **crash kernel's own** dracut module: installs `cryptsetup`, and generates the `70-luks-kdump.rules` udev rule that runs `cryptsetup luksOpen --volume-key-keyring %user:<key-desc> <dev> luks-<uuid>` with no passphrase | The kdump initramfs has no self-contained unlock mechanism at all, independent of everything the first kernel did |

This is a **confirmed, still-current upstream gap**, not a misreading of
something that already works: as of this writing, the kernel's own
published documentation
([docs.kernel.org/admin-guide/kdump/kdump.html](https://docs.kernel.org/admin-guide/kdump/kdump.html))
still says *"CONFIG_CRASH_DM_CRYPT can be enabled to support saving the
dump file to an encrypted disk volume (only x86_64 supported for now)"* --
`kdump-utils` simply has not been updated for the brand-new (per the
commit dates above) kernel-side ARM64 enablement yet, and no newer
`kdump-utils` release with an aarch64-aware patch was found to cherry-pick
the way the kernel commits were.

**Why lifting the gate, rather than rewriting the logic, is the correct
fix:** all three functions are otherwise 100% architecture-generic --
UUID-based device lookup via `get_all_kdump_crypt_dev` (no arch branch
anywhere inside it), the generic `/sys/kernel/config/crash_dm_crypt_keys`
configfs interface (the exact same interface the arm64 kernel patch wires
up to the new DT property), and a plain `cryptsetup luksOpen
--volume-key-keyring` udev rule with no x86-specific `boot_params`/`e820`
code anywhere in the gated code paths. Nothing else needed to change.

[`centos-arm64/luks/patch-kdump-utils-arm64.sh`](https://github.com/mukeshpilaniya/kernel-qemu-lab/blob/main/centos-arm64/luks/patch-kdump-utils-arm64.sh)
applies the minimal fix -- loop-mounts `centos-rootfs.raw` and widens each
guard from `!= "x86_64"` to `!= "x86_64" && != "aarch64"` -- as a
re-runnable, documented step in the pipeline rather than a one-off manual
edit:

```text
--- before ---
kdumpctl:1184:  # Currently only x86_64 is supported
kdumpctl:1275:          dwarn "Currently only x86_64 supported"
module-setup.sh:1117:    # Currently only x86_64 is supported
--- after ---
kdumpctl:1185:  if [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "aarch64" ]]; then
kdumpctl:1274:  if [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "aarch64" ]]; then
module-setup.sh:1118:    [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "aarch64" ]] && return 1
```

After this patch, the exact same test produced (see
[Validating the result](#validating-the-result-what-this-projects-own-run-actually-produced)
for the full picture):

```text
kdump:    - Added link-volume-key for UUID: 86988197-e7b5-4207-8b62-abe850378c5b
...
luks-86988197-... UUID=86988197-... /root/kdump-luks.key luks,link-volume-key=@u::%logon:kdump-cryptsetup:vk-86988197-...
[INFO] reuse=1 — dm-crypt keys are saved in crash-reserved memory
[INFO] PASS  link-volume-key is set
```

#### What failed on the first run

For completeness, the first attempt (kernel patched, `kdump-utils` not yet
patched) got surprisingly far before failing -- `03-create-luks-target.sh`
formatted and opened the LUKS device, `04-configure-kdump.sh` wrote
`kdump.conf`, and `05-rebuild-kdump.sh` successfully ran `kdumpctl
rebuild` + `systemctl restart kdump` (`kexec_crash_loaded=1`, "PASS crash
kernel loaded") -- i.e. everything **this project's own scripts** drive
worked. It was specifically the parts owned by the real `kdumpctl`
binary -- `prepare_luks()`'s configfs population and
`setup_crypttab()`'s crypttab rewrite -- that silently no-op'd, which
`06-precrash-checks.sh` then correctly caught and failed on
(`crypttab missing link-volume-key`, `could not set .../reuse`). Nothing
about the DT/kernel side needed any further changes once this was
understood -- the fix was entirely in userspace.

#### Two different "patch the gate" steps, for two different reasons

This project ended up fixing the same three `kdump-utils` gates in **two
separate places**, and it's worth being explicit about why both exist
rather than just one:

| | What it patches | Why it's needed |
| --- | --- | --- |
| `centos-arm64/luks/patch-kdump-utils-arm64.sh` | The *binary* `/usr/bin/kdumpctl` and `module-setup.sh` already installed into `centos-rootfs.raw` by `dnf` | This project's rootfs is built by installing the **packaged** `kdump-utils-1.0.61-2.el10.aarch64` RPM (see [Requirements](#requirements)) -- not by compiling `kdump-utils` from source -- so the git-level fix below never reaches this test's actual QEMU guest unless the installed files are patched directly, in place, on every fresh rootfs build. |
| The `kdump-utils` git repository itself (`/Users/mpilaniy/pilaniya/work/kdump-utils`, a separate checkout, not part of this project's own tree), commit `4114efc` "Enable LUKS support for aarch64" | The actual upstream source | This is the real, re-submittable fix -- a proper `git commit` against the real `rhkdump/kdump-utils` project, with a commit message explaining the kernel-side prerequisite and citing this project's own test as verification. It is what a real downstream RPM rebuild (or an eventual upstream PR) would need, but it has **no effect whatsoever** on this project's own QEMU test, since that test never rebuilds or reinstalls `kdump-utils` from this source tree. |

In short: the `.sh` script is what makes *this test* pass; the git commit
is what would make the *next* person's `dnf install kdump-utils` not need
this test's workaround at all.

### 3. The QEMU/kexec gap: EL2 is required for the crash-kernel jump, not just HVF

`centos-arm64/run-qemu.sh` defaults to `-accel hvf` for a *plain*
boot, because Apple Silicon can HVF-accelerate an arm64 guest natively
(unlike x86_64, which Apple Silicon cannot virtualize at all -- the reason
every x86 script in this project is forced onto `-accel tcg`). It would be
reasonable to assume the LUKS test could use the same fast HVF path. It
cannot, for a reason specific to the kexec/kdump *jump* itself, not to
booting in general.

`arch/arm64/kernel/machine_kexec.c`'s `machine_kexec()` is shared, by
design, between a normal kexec reboot and the kdump crash-kernel jump
(gated internally by `in_kexec_crash`). On a kernel not already running
at EL2 (hyp mode), it calls `__hyp_set_vectors(kimage->arch.el2_vectors)`
before jumping via `cpu_soft_restart()` -- i.e. the jump to the *second*
kernel needs a usable EL2, present or not, on **both** the ordinary-kexec
path and the kdump path, since it is the exact same function. This
project's own `vanilla-arm64` precedent
(`vanilla-arm64/run-qemu-vanilla.sh`) already documents needing `-accel
tcg` plus `virtualization=on` for a plain `kexec -l`/`kexec -e` to
succeed, for exactly this reason. `centos-arm64/luks/run-qemu-luks-centos-arm64.sh`
carries the same default forward for the kdump path: QEMU TCG's own
`virtualization=on` nested-EL2 emulation is known-good here (this
project's own prior test proved it); QEMU HVF's support for the same
nested EL2 transition was not validated and is not the default. The
trade-off is a slower boot (TCG software emulation vs. HVF hardware
acceleration) in exchange for a kexec/kdump jump that is actually proven
to work.

### 4. A related, NOT-exercised-by-this-test gap: kdump-anaconda-addon

**This section documents a fix that was made for completeness, but which
nothing in this project's own test pipeline actually exercises.** It is
included because it is the same bug, in a sibling project, found by
inspection rather than by a failing test -- and because it matters for
anyone who would actually deploy this feature, as opposed to testing it
under QEMU the way this project does.

**What it is.** `kdump-anaconda-addon` is not something that runs on an
installed system at all -- it is a plugin for **Anaconda**, the RHEL/
CentOS/Fedora graphical-and-kickstart OS *installer*. It has two halves:
a GUI spoke (`com_redhat_kdump/gui/spokes/kdump.py`, the "KDUMP" screen
shown during an interactive install) and a kickstart/service module
(`com_redhat_kdump/service/kdump.py`, driven by a `%addon com_redhat_kdump`
kickstart block for unattended installs). Its job is to configure kdump
*onto the target system's disk before that system ever boots for the
first time* -- enabling the service, writing the bootloader's
`crashkernel=` argument, and (the part relevant here)
`KdumpCrypttabSetupTask`, a thin wrapper that shells out to `kdumpctl
setup-crypttab` -- the exact same `kdumpctl` function patched in
[the userspace gap](#2-the-userspace-gap-kdump-utils-own-x86_64-only-gates)
above -- so that a brand-new install onto an encrypted disk already has
`/etc/crypttab`'s `link-volume-key=` option set, instead of an admin
having to notice it is missing and run that command by hand after the
fact.

**The same bug, found the same way.** Grepping this sibling repository
(`/Users/mpilaniy/pilaniya/work/kdump-anaconda-addon`, a separate checkout,
not part of this project's own tree) for the same kind of architecture
check that caused
[the userspace gap](#2-the-userspace-gap-kdump-utils-own-x86_64-only-gates)
turned up two more, introduced by the same author in commit `a6c2cf4`
("Don't emit ENCRYPTION_WARNING for x86_64"), at the time that commit was
written for the same reason -- only x86_64 had kernel-side LUKS kdump
support:

| File | Gate (before) | Effect |
| --- | --- | --- |
| `com_redhat_kdump/gui/spokes/kdump.py` | `if self._luks_devs and blivet.arch.get_arch() != "x86_64":` shows `ENCRYPTION_WARNING` | On aarch64, the installer would warn that kdump "is not working well with encrypted dump target" even though, with the kernel and `kdump-utils` fixes in this README applied, it now does |
| `com_redhat_kdump/service/kdump.py` | `if self.kdump_enabled and blivet.arch.get_arch() == "x86_64":` appends `KdumpCrypttabSetupTask` | On aarch64, a fresh install onto an encrypted disk would **not** get `/etc/crypttab` set up automatically -- the exact gap [What failed on the first run](#what-failed-on-the-first-run) hit, just encountered at install time instead of at `kdumpctl restart` time |

**The fix**, committed directly to that repository as `3c1095a` ("Also
skip ENCRYPTION_WARNING and enable crypttab setup for aarch64"), widens
both checks the same way the `kdump-utils` fix does:

```python
# gui/spokes/kdump.py
if self._luks_devs and blivet.arch.get_arch() not in ("x86_64", "aarch64"):
    self.set_warning(_(ENCRYPTION_WARNING))

# service/kdump.py
if self.kdump_enabled and blivet.arch.get_arch() in ("x86_64", "aarch64"):
    tasks.append(KdumpCrypttabSetupTask(sysroot=conf.target.system_root))
```

**Why "not exercised" is not a minor caveat.** This project's rootfs is
built by `make-centos-rootfs.sh` calling `dnf --installroot` directly
against an already-existing empty disk image (see
[Build pipeline](#build-pipeline)) -- there is no Anaconda process, no
installer boot media, no GUI, and no kickstart file anywhere in this
test's pipeline; confirmed directly, `rpm -qa` against the built rootfs
has no `anaconda*` package and no `com_redhat_kdump` directory exists
anywhere on it. `04-configure-kdump.sh` calls `kdumpctl setup-crypttab`
**itself**, as a plain post-install shell command, which is why the
`kdump-utils` fix alone was sufficient for this project's own test to
pass end-to-end. The `kdump-anaconda-addon` fix is therefore unverified by
anything in this repository -- it is the correct fix by inspection (the
exact same architecture check, same author, same underlying kernel
capability it is gating), but, unlike every other claim in this README's
[Validating the result](#validating-the-result-what-this-projects-own-run-actually-produced)
section, it does not come with a QEMU run to back it up. Confirming it
properly would require actually booting an Anaconda installer image on
aarch64 against an encrypted target, which is outside the scope of what
this project's QEMU-based kernel/kdump testing does.

## Why centos-arm64 exists alongside vanilla-arm64 and centos-x86

| | `vanilla-arm64` | `centos-x86` | `centos-arm64` (this folder) |
| --- | --- | --- | --- |
| Kernel source | `centos-stream-10/linux` (plain upstream torvalds tree) | `centos-stream-10/src` | `centos-stream-10/src`, **plus the 3 cherry-picked commits above** |
| Base `.config` | Hand-built via `scripts/config --enable ...` | `redhat/configs/kernel-6.12.0-x86_64.config` | `redhat/configs/kernel-6.12.0-aarch64.config` (already has `CONFIG_CRASH_DM_CRYPT=y`, same as x86) |
| Rootfs | Static busybox, hand-copied binaries | Full `dnf --installroot` CentOS userspace | Full `dnf --installroot` CentOS userspace, all modules |
| kdump mechanism | Hand-rolled: manual `cryptsetup` + `configfs` + `kexec -p -s` | Real `kdumpctl setup-crypttab` + dracut's `99kdumpbase` module | Same, **plus the userspace patch above** -- real `kdumpctl`, patched |
| Build arch vs. host | Native (same arch as container) | Cross-compiled from arm64 host | Native (same arch as container) |
| QEMU accel for the crash jump | `tcg` + `virtualization=on` (established precedent) | `tcg` (Apple Silicon cannot HVF x86 at all) | `tcg` + `virtualization=on` (same reason as vanilla-arm64, see above) |

`centos-arm64` is the ARM64 analogue of what `centos-x86` is for x86_64 --
"what would actually happen on a real aarch64 CentOS/RHEL box with this
feature enabled" -- except that, unlike x86_64, the feature did not
already fully exist on this architecture when this work started; getting
here is as much the point of this folder as the successful end-to-end run
itself.

## Script naming

Every script here carries an explicit `arm64`/`centos-arm64` marker so it
is never confused with its `centos-x86` counterpart, following the same
convention `centos-x86-readme.md`'s "Script naming" section establishes:

| `centos-arm64` (this folder) | `centos-x86` counterpart |
| --- | --- |
| `build-kernel.sh` (pre-existing, incremental only, no LUKS/debug-info) | `build-centos-x86-kernel.sh` |
| **`build-centos-arm64-kernel.sh`** (new: full build, debug info on, the cherry-picked commits) | `build-centos-x86-kernel.sh` |
| `make-centos-rootfs.sh` (pre-existing, extended in place with LUKS packages) | `make-centos-x86-rootfs.sh` |
| `install-modules-dracut.sh` (pre-existing, extended in place with `crypt dm xfs`) | `install-modules-dracut-x86.sh` |
| `run-qemu.sh` (pre-existing, unchanged, `hvf` default) | `run-qemu-centos-x86.sh` |
| `luks/run-qemu-luks-centos-arm64.sh` (new, `tcg`+EL2 default) | `luks/run-qemu-luks-centos-x86.sh` |
| `luks/stage-kdump-scripts-arm64.sh` (new) | `luks/stage-kdump-scripts-x86.sh` |
| **`luks/patch-kdump-utils-arm64.sh` (new -- no x86 equivalent, see above)** | *(none needed)* |
| `luks/luks-kdump-centos-arm64-test.py` (new) | `luks/luks-kdump-centos-x86-test.py` |
| `luks/verify-vmcore-centos-arm64.sh` (new) | `luks/verify-vmcore-centos-x86.sh` |
| `luks/verify-with-crash-centos-arm64.sh` (new) | `luks/verify-with-crash-centos-x86.sh` |

`build-kernel.sh`, `make-centos-rootfs.sh`, `install-modules-dracut.sh`,
and `run-qemu.sh` predate this LUKS work (see `../../README.md`) and are
kept for the original plain-kexec sanity test
(`kexec-guest-test.py`/`copy-to-rootfs.sh`); `make-centos-rootfs.sh` and
`install-modules-dracut.sh` were extended **in place**, additively, rather
than forked, so that older test keeps working unchanged against the newer
rootfs.

## Directory layout (this folder, after a full build)

```text
build-out/centos-arm64/
├── Image                        # aarch64 boot image, 38 MB, built WITH debug info this time
├── vmlinux                      # 392 MB uncompressed ELF, DWARF debug info (with debug_info, not stripped)
├── kernel.config                # the .config actually built (base + Kconfig deltas below)
├── kernel.release                # 6.12.0-centos10-arm64-local+
├── centos-rootfs.raw             # 8G ext4, full dnf-installed CentOS Stream 10 userspace
├── initramfs.img                 # 38 MB dracut initrd: virtio_blk/net, ext4, xfs, crypt, dm
├── kdump-scripts-stage/          # staging dir used by stage-kdump-scripts-arm64.sh (transient)
├── kdump-vdb.raw                 # the encrypted kdump target disk (/dev/vdb in the guest), 2 GiB sparse
├── vmcore-arm64.extracted        # the vmcore makedumpfile produced, copied out by verify-vmcore-centos-arm64.sh
├── luks-kdump-centos-arm64.log   # full serial transcript of the most recent test run
├── kernel-6.12.0-aarch64.config  # legacy: dist-configs-arch output from the ORIGINAL (pre-LUKS, Sep 24) build
├── kernel-aarch64.config         # legacy: the actual built .config from that same original, DEBUG_INFO_NONE build
└── kexec                        # legacy: a standalone kexec-tools binary, manually copied in before kdump-utils existed on this rootfs
```

The last three entries predate this LUKS work entirely (see `../../README.md`
and `copy-to-rootfs.sh`) and are superseded by `kernel.config` /
`kernel.release` / the dnf-installed `kexec-tools` package respectively --
kept only because nothing in this pipeline needs to delete them.

## Requirements

**Packages installed into the rootfs** (via `dnf --installroot`, in
`make-centos-rootfs.sh`), confirmed present in CentOS Stream 10's
`baseos`/`appstream` repos for aarch64 -- the identical list
`centos-x86-readme.md`'s Requirements table uses, confirming this is not
an architecture-specific package gap on top of everything else:

| Package | Version seen | Why |
| --- | --- | --- |
| `cryptsetup` | 2.8.6 | `>=2.7` required for `--link-vk-to-keyring` / `--volume-key-keyring` |
| `kexec-tools` | 2.0.32 | `/usr/sbin/kexec`, `/usr/sbin/vmcore-dmesg` |
| `kdump-utils` | 1.0.61 | `kdumpctl`, `/etc/kdump.conf`, `kdump.service`, the `99kdumpbase`/`99earlykdump` dracut modules -- **this is the exact version with the x86_64-only gates described above** |
| `xfsprogs` | 6.16.0 | dump target filesystem |
| `makedumpfile` | 1.7.8 | kdump's `core_collector` |
| `keyutils`, `crash`, `grubby` | -- | keyring inspection; `crash-9.0.2-1.el10.aarch64` is directly available on this distro |

**Kernel config requirements**, already satisfied by the stock
`redhat/configs/kernel-6.12.0-aarch64.config` -- identical set to x86,
confirmed in the actual built `.config`:

```text
CONFIG_CRASH_DM_CRYPT=y
CONFIG_CRASH_DM_CRYPT_CONFIGS=y
CONFIG_DM_CRYPT=m
CONFIG_CONFIGFS_FS=y
CONFIG_KEXEC_FILE=y
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y
CONFIG_XFS_FS=m
```

**Source requirement specific to this folder**: the 3 cherry-picked
commits from
[The kernel gap](#1-the-kernel-gap-three-upstream-commits-absent-from-centos-stream-10src)
above must already be applied to `centos-stream-10/src` -- without them,
`CONFIG_CRASH_DM_CRYPT=y` still compiles and the x86-only parts of the
feature still exist in the tree, but `crash_load_dm_crypt_keys()` is never
called from `arch/arm64/kernel/machine_kexec_file.c` and the kernel never
learns to read back the `linux,dmcryptkeys` DT property -- i.e. the
kernel would build, boot, and silently never actually pass the key to the
crash kernel.

**Build-environment requirements**: identical to the pre-existing
`centos-arm64` build (`centos-kernel-builder:el10`, native arm64, no
cross-toolchain needed) -- see `../../README.md` steps 1-3. No new
host-side tools were needed beyond what that original setup already
required.

## Build pipeline

All scripts below live in [mukeshpilaniya/kernel-qemu-lab](https://github.com/mukeshpilaniya/kernel-qemu-lab); paths are relative to a clone of that repository (`git clone https://github.com/mukeshpilaniya/kernel-qemu-lab && cd kernel-qemu-lab`). Run in order:

```sh
./centos-arm64/build-centos-arm64-kernel.sh       # Image + vmlinux + modules (long: full distro module set, debug info on)
./centos-arm64/make-centos-rootfs.sh               # 8G ext4 CentOS Stream 10 userspace (dnf --installroot), now with LUKS packages
VOLUME=centos-kernel-arm64-build ./centos-arm64/install-modules-dracut.sh   # modules_install + dracut initrd (native, single docker stage)
./centos-arm64/luks/stage-kdump-scripts-arm64.sh   # copies encrypt_crash_kernel/scripts/ into the rootfs
./centos-arm64/luks/patch-kdump-utils-arm64.sh     # lifts kdump-utils' x86_64-only gates -- see above
./centos-arm64/luks/luks-kdump-centos-arm64-test.py # boots it, runs the real kdumpctl LUKS flow, triggers the panic
./centos-arm64/luks/verify-vmcore-centos-arm64.sh  # unlocks kdump-vdb.raw externally, checks for the vmcore
./centos-arm64/luks/verify-with-crash-centos-arm64.sh # opens that vmcore with crash(8) -- confirms it is actually readable
```

### Step 1 -- `build-centos-arm64-kernel.sh`

A **new** one-shot script, filling the role `centos-x86`'s own
`build-centos-x86-kernel.sh` fills, that the pre-existing `build-kernel.sh`
never could: `build-kernel.sh` is explicitly incremental-only (its own
header comment: *"first build is manual, see kernel/README.md"*), and that
original first build (`../../README.md` step 6) deliberately forced
`CONFIG_DEBUG_INFO_NONE` to fit Docker Desktop's then-default memory, and
never copied `vmlinux` out at all. Neither is acceptable for `crash(8)`
analysis, which needs real DWARF debug info to resolve symbols.

This script instead:

- Uses the already-present, already-committed-to-the-working-tree
  `redhat/configs/kernel-6.12.0-aarch64.config` as-is -- no manual
  `scripts/config --enable CRASH_DM_CRYPT` needed, same reasoning as x86.
- **Leaves `CONFIG_DEBUG_INFO=y` / `CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y`
  on** (the stock config's own default) instead of forcing them off.
- Disables `KEXEC_SIG` and `DEBUG_INFO_BTF`/`_BTF_MODULES` for the same
  reasons `build-centos-x86-kernel.sh` does (no secure-boot chain in this
  QEMU test; `crash(8)` reads DWARF, not BTF; `pahole` version-matching
  risk for no benefit).
- **Does *not* disable anything arm64-specific** (no `ARM64_PTR_AUTH`/
  `ARM64_BTI` override, unlike x86's `X86_KERNEL_IBT`/`X86_CET`): x86's
  disables existed to work around a *cross*-toolchain/objtool mismatch
  that simply does not apply here, since this is a *native* build with
  the distro's own gcc (the exact same `centos-kernel-builder:el10` image
  the original, proven-working, pre-LUKS `Image` build already used).
- Uses a **new**, separate Docker volume, `centos-kernel-arm64-build` --
  not the original `centos-kernel-build` -- so this debug-info build's
  objects never mix with the old non-debug incremental build's objects.
  `LOCALVERSION` is correspondingly `-centos10-arm64-local` (distinct from
  the original `-centos10-local`), giving `kernel.release
  6.12.0-centos10-arm64-local+`.

Builds `Image modules` by default (`MODULES=1`) -- the same full,
real-distro module set `centos-x86` builds (amdgpu, nouveau, every NIC/
iSCSI/SCSI/InfiniBand driver, etc.), just natively rather than
cross-compiled, which in practice made this build *faster* wall-clock-wise
than the x86 cross-build despite producing a comparable module tree.

### Step 2 -- `make-centos-rootfs.sh`

The pre-existing script, extended **in place** (not forked) with the
LUKS-specific packages from [Requirements](#requirements) above: `xfsprogs`,
`cryptsetup`, `keyutils`, `kexec-tools`, `kdump-utils`, `makedumpfile`,
`crash`, `grubby`. Purely additive -- the original plain-kexec sanity test
(`kexec-guest-test.py`) still works unchanged against the resulting
rootfs.

### Step 3 -- `install-modules-dracut.sh`

Also extended in place:

- `--add-drivers` gained `xfs` (the dump target filesystem) alongside the
  pre-existing `virtio_blk virtio_pci virtio_mmio virtio_net ext4 crc32c
  jbd2 mbcache`; `--add "crypt dm"` was added for the first kernel's own
  boot environment to have cryptsetup/dm-crypt support too (needed since
  `03-create-luks-target.sh` and `04-configure-kdump.sh` run inside the
  *first* kernel, not just the kdump initramfs).
- **Now copies `Image` and `kernel.config` into the rootfs** as
  `/boot/vmlinuz-$KVER` / `/boot/config-$KVER` -- a step the original
  script never needed (the old plain-kexec test booted entirely via
  QEMU's own `-kernel`/`-initrd` flags, bypassing `/boot` on the rootfs
  completely), but which `kdumpctl` *requires*: by default it
  `kexec_file_load`s the **running** kernel as its own crash kernel,
  reading it from `/boot/vmlinuz-$(uname -r)` (`KDUMP_KERNEL` is unset in
  this project's `kdump.conf`). Matches
  `centos-x86/install-modules-dracut-x86.sh`'s equivalent copy exactly.
- **Takes a `VOLUME` override** (`VOLUME=centos-kernel-arm64-build`,
  defaulting to the original `centos-kernel-build` for backward
  compatibility) -- the single most important correctness fix made to
  this script: the original hardcoded `-v centos-kernel-build:/build`,
  which would otherwise silently install the *old*, non-debug build's
  modules under the *new* kernel's version string, a real failure hit
  during this work (`depmod: ERROR: could not open directory
  /lib/modules/6.12.0-centos10-arm64-local+: No such file or directory`,
  because `modules_install` had just populated
  `6.12.0-centos10-local+` instead -- the old volume's `kernel.release`).

### Step 4 -- `luks/stage-kdump-scripts-arm64.sh`

Line-for-line the same approach as `centos-x86/luks/stage-kdump-scripts-x86.sh`
(copies `encrypt_crash_kernel/scripts/*` plus a generated `run-all.sh`
chaining `01`→`03`→`04`→`05`→`06`→`07`) -- confirming the
`encrypt_crash_kernel/scripts/` toolkit itself needed **zero** changes for
ARM64. Every fix this folder required was either in the kernel source
tree or in the `kdump-utils` package already installed on the rootfs --
never in this project's own scripts.

### Step 5 -- `luks/patch-kdump-utils-arm64.sh`

New, no x86 equivalent -- see
[The userspace gap](#2-the-userspace-gap-kdump-utils-own-x86_64-only-gates)
above for the full rationale. Loop-mounts `centos-rootfs.raw`, `sed`s the
three `uname -m` guards in `/usr/bin/kdumpctl` and
`/usr/lib/dracut/modules.d/99kdumpbase/module-setup.sh` to accept
`aarch64` alongside `x86_64`, and verifies the change with a before/after
`grep`.

### Steps 6-8 -- test, verify, crash

Identical in structure and purpose to `centos-x86/luks/`'s steps 6-9 (that
README's own numbering includes the `run-qemu-luks-*.sh` script this one
folds into the Python driver's description) -- see
[Script-by-script walkthrough](#script-by-script-walkthrough) below for
the ARM64-specific details (TCG+EL2, `ttyAMA0`, DT-based key delivery)
that differ from the x86 versions.

## Script-by-script walkthrough

| # | Script | Runs where | What it actually does |
| --- | --- | --- | --- |
| 1 | `build-centos-arm64-kernel.sh` | host (native arm64 container) | Copies the committed `kernel-6.12.0-aarch64.config` to `/build/.config`, force-disables `KEXEC_SIG`/BTF, runs `olddefconfig`, then `make Image modules`. Copies `Image`, `vmlinux`, `kernel.config`, `kernel.release` to `build-out/centos-arm64/`. |
| 2 | `make-centos-rootfs.sh` | host (CentOS Stream 10 container, native arm64) | Creates an empty 8G raw disk, formats it ext4, then `dnf --installroot=/mnt/root` installs a full CentOS Stream 10 userspace including the LUKS/kdump package set. Sets root password to `root`, disables SELinux enforcement, enables a serial getty on `ttyAMA0`. |
| 3 | `install-modules-dracut.sh` | host, one container (native arm64, `VOLUME=centos-kernel-arm64-build`) | `modules_install` against the new volume's objects, copies `Image`/`kernel.config` into `/boot/vmlinuz-$KVER`/`/boot/config-$KVER`, `chroot`s in to run `depmod` and the *boot* `dracut` (virtio/ext4/xfs/crypt/dm drivers), copies the result to `build-out/centos-arm64/initramfs.img`. |
| 4 | `run-qemu.sh` | host | Plain boot sanity check, no second disk, `-accel hvf` default (fast, native) -- used to confirm the new kernel/rootfs/initramfs boot at all before attempting the LUKS flow. Not part of the LUKS pipeline itself. |
| 5 | `luks/stage-kdump-scripts-arm64.sh` | host, one container (arm64, mounts the rootfs loop) | Copies `encrypt_crash_kernel/scripts/*` verbatim plus a generated `run-all.sh` to `/root/kdump-scripts/` on `centos-rootfs.raw`. Nothing executes yet. |
| 6 | `luks/patch-kdump-utils-arm64.sh` | host, one container (arm64, mounts the rootfs loop) | Widens the three `kdump-utils` `uname -m` gates described above, in-place, on the same rootfs disk. |
| 7 | `luks/run-qemu-luks-centos-arm64.sh` | host | Same base as `run-qemu.sh` plus a second virtio disk (`kdump-vdb.raw`, 2 GiB sparse) as `/dev/vdb`, **`-accel tcg` + `virtualization=on` by default** (not `hvf` -- see [the EL2 gap](#3-the-qemukexec-gap-el2-is-required-for-the-crash-kernel-jump-not-just-hvf)), `console=ttyAMA0 earlycon=pl011,...` instead of x86's `ttyS0`. Not normally invoked directly; the Python driver launches it. |
| 8 | `luks/luks-kdump-centos-arm64-test.py` | host (spawns #7 on a pty) | The test driver: boots via #7, waits for the real systemd `login:` prompt, logs in `root`/`root`, runs `sh /root/kdump-scripts/run-all.sh`, waits for `KDUMP_SETUP_DONE`, then the SysRq panic line, then captures the crash kernel's own boot/dump sequence. Structurally identical to `centos-x86`'s driver, including the same `"FAIL"`-is-a-false-positive-trap reasoning for its `wait_for` patterns. Transcript: `build-out/centos-arm64/luks-kdump-centos-arm64.log`. |
| 9 | `luks/verify-vmcore-centos-arm64.sh` | host (one Alpine container) | Runs independently after the test, loop-mounts `kdump-vdb.raw`, opens the LUKS header with the known test passphrase, mounts the XFS filesystem read-only, looks under `/var/crash/` (actually landed at the mount root, `path /` in `kdump.conf` -- the timestamped dump directory sits directly at the FS root) for a `vmcore` file. On success, copies it to `build-out/centos-arm64/vmcore-arm64.extracted`. |
| 10 | `luks/verify-with-crash-centos-arm64.sh` | host (`crash-tool:fedora42-arm64` container, native -- no amd64 emulation needed, unlike the x86 side of this project) | Opens `vmcore-arm64.extracted` with `crash(8)` against `build-out/centos-arm64/vmlinux`, runs `sys`/`bt`/`log` (or whatever commands are passed) non-interactively. |

## Step by step: what actually happens, start to finish

1. **`build-centos-arm64-kernel.sh`** produces an `Image` + a full module
   tree, in the new `centos-kernel-arm64-build` Docker volume, with the
   3 cherry-picked commits baked in and debug info on.
2. **`make-centos-rootfs.sh`** produces an empty-of-kernel but otherwise
   complete CentOS Stream 10 disk, including the patched-later
   `kdump-utils` package and every other LUKS/kdump package.
3. **`install-modules-dracut.sh`** closes the boot gap: modules land on
   the rootfs disk, `/boot/vmlinuz-$KVER`/`/boot/config-$KVER` are added
   (new -- required for `kdumpctl`'s self-referential crash-kernel load),
   and the *boot* initramfs (with `xfs`/`crypt`/`dm` added) is generated.
4. **`luks/stage-kdump-scripts-arm64.sh`** places the
   `encrypt_crash_kernel/scripts/` toolkit onto that disk at
   `/root/kdump-scripts/`.
5. **`luks/patch-kdump-utils-arm64.sh`** widens the three `uname -m` gates
   in the already-installed `kdump-utils` package, on the same disk.
   Without this step, everything below still runs to completion but the
   crash kernel never actually unlocks the LUKS device unattended --
   see [What failed on the first run](#what-failed-on-the-first-run).
6. **`luks/luks-kdump-centos-arm64-test.py`** launches QEMU (`-accel
   tcg,virtualization=on`, `luks/run-qemu-luks-centos-arm64.sh` under it)
   with the rootfs as `vda` and a fresh `kdump-vdb.raw` as `vdb`. The
   first kernel boots, the login prompt appears.
7. The driver logs in and runs `run-all.sh`:
   - `01-verify-prereqs.sh` -- confirms `CONFIG_CRASH_DM_CRYPT`,
     `CONFIG_CONFIGFS_FS`, `kdump-utils`, `cryptsetup`, and the configfs
     interface are all present. Identical output shape to the x86 run.
   - `03-create-luks-target.sh` -- formats `/dev/vdb` LUKS2, opens it as
     `luks-<LUKS-UUID>` with `cryptsetup open --link-vk-to-keyring`.
   - `04-configure-kdump.sh` -- writes `kdump.conf` (`xfs
     UUID=<FS-UUID>`, `path /`, `core_collector makedumpfile -c ...`) and
     runs `kdumpctl setup-crypttab`, which -- now that the patch from
     step 5 is in place -- actually appends `link-volume-key=@u::%logon:
     kdump-cryptsetup:vk-<LUKS-UUID>` to the crypttab line this time,
     logged explicitly as *"kdump: Success! /etc/crypttab has been
     updated. - Added link-volume-key for UUID: ..."*.
   - `05-rebuild-kdump.sh` -- runs `kdumpctl rebuild` (regenerates the
     kdump-specific dracut initramfs, now **with** the
     `20-kexec-crypt-setup.sh` initqueue hook and `70-luks-kdump.rules`
     udev rule that `kdump_check_crypt_targets()` builds once unblocked)
     and `systemctl restart kdump`. This is also the point where
     `kdumpctl`'s `prepare_luks()` populates
     `/sys/kernel/config/crash_dm_crypt_keys/<uuid>/description`, which
     the kernel then reads when `kexec_file_load` runs -- confirmed by
     `reuse=1 — dm-crypt keys are saved in crash-reserved memory`
     immediately afterward.
   - `06-precrash-checks.sh` -- this time, both checks that failed on the
     first run pass: `PASS keys present in crash-reserved memory` and
     `PASS link-volume-key is set`.
   - `07-trigger-crash.sh` -- `echo c > /proc/sysrq-trigger`.
8. The panic hands control to `machine_kexec()`, which (via the
   `cpu_soft_restart()`/EL2-vectors path described above) boots the
   **second kernel** directly into the kdump initramfs. Its
   `20-kexec-crypt-setup.sh` hook waits for
   `/sys/kernel/config/crash_dm_crypt_keys/restore`, then the
   `70-luks-kdump.rules` udev rule fires: `cryptsetup luksOpen
   --volume-key-keyring %user:<key-desc> /dev/vdb luks-<uuid>` -- no
   passphrase, confirmed directly in the serial log:
   `Found device dev-mapper-luks-<uuid>.device` with **zero** occurrences
   of "Enter passphrase" anywhere in the transcript.
9. `kdump-capture.service` mounts the now-unlocked XFS filesystem, runs
   `makedumpfile`, and writes `vmcore` + `vmcore-dmesg.txt` to the mount
   root (`path /` in `kdump.conf`). The guest then reboots per
   `failure_action reboot`; QEMU's `-no-reboot` turns that into the QEMU
   process exiting.
10. **`luks/verify-vmcore-centos-arm64.sh`**, run separately, unlocks
    `kdump-vdb.raw` from outside the guest and confirms the `vmcore` file
    exists and is non-empty, copying it to
    `build-out/centos-arm64/vmcore-arm64.extracted`.
11. **`luks/verify-with-crash-centos-arm64.sh`** opens that file with
    `crash(8)` against `build-out/centos-arm64/vmlinux` -- see
    [Validating the result](#validating-the-result-what-this-projects-own-run-actually-produced)
    for the actual output.

## Running the LUKS kdump test

```sh
cd kernel-qemu-lab   # clone of https://github.com/mukeshpilaniya/kernel-qemu-lab
./centos-arm64/luks/luks-kdump-centos-arm64-test.py
```

The driver waits for the real systemd `login:` prompt, logs in as
`root`/`root`, runs `sh /root/kdump-scripts/run-all.sh`, waits for
`KDUMP_SETUP_DONE`, then the SysRq panic line, then captures whatever the
crash kernel's own boot sequence prints. The full transcript lands at
`build-out/centos-arm64/luks-kdump-centos-arm64.log`. A full, successful
run takes roughly 4 minutes end-to-end on this host (slower than
`centos-x86`'s equivalent run, almost entirely due to the TCG software
emulation `-accel tcg` requires for the crash-kernel jump -- see
[the EL2 gap](#3-the-qemukexec-gap-el2-is-required-for-the-crash-kernel-jump-not-just-hvf)).

## Validating the result: what this project's own run actually produced

This is not a hypothetical -- every value below is from this project's own
most recent successful run, cross-referenced against
`build-out/centos-arm64/luks-kdump-centos-arm64.log`.

**The test driver itself** exited `0`, having observed:

```text
setup: KDUMP_SETUP_DONE
panic: sysrq triggered crash
no_interactive_passphrase_prompt: True
```

**The crash kernel's own serial output** showed the unattended unlock
succeeding, with no interactive prompt anywhere in the transcript:

```text
Found device dev-mapper-luks\x2d86988197\x2de7b5\x2d4207\x2d8b62\x2dabe850378c5b.device
... Mounted kdumproot-mnt-kdump.mount - /kdumproot/mnt/kdump.
... kdump[495]: Kdump is using the default log level(3).
... kdump[667]: saving vmcore
Copying data : [100.0 %]
The dumpfile is saved to /kdumproot/mnt/kdump/127.0.0.1-.../vmcore-incomplete.
makedumpfile Completed.
... kdump[672]: saving vmcore complete
```

**`luks/verify-vmcore-centos-arm64.sh`**, run against the resulting
`kdump-vdb.raw` from outside the guest entirely:

```text
luksUUID: 86988197-e7b5-4207-8b62-abe850378c5b
VERIFY_RESULT=PASS vmcore=/mnt/extract/127.0.0.1-2026-10-04-15:25:39/vmcore bytes=73556280
4b 44 55 4d
```

73,556,280 bytes (~70 MiB) from a 2 GiB guest -- the same order of
magnitude `centos-x86-readme.md` reports (72-92 MB) for the same `-d 31`
`makedumpfile` filter level. `4b 44 55 4d` is `KDUM` -- the first 4 bytes
of `makedumpfile`'s own magic header (`KDUMP`), confirming the file is a
valid `makedumpfile`-format dump, not a truncated or corrupted copy.

**`luks/verify-with-crash-centos-arm64.sh`**, run against that extracted
file and `build-out/centos-arm64/vmlinux`:

```text
GNU gdb (GDB) 16.2 ... This GDB was configured as "aarch64-unknown-linux-gnu".
KERNEL: /out/vmlinux
    DUMPFILE: /out/vmcore-arm64.extracted  [PARTIAL DUMP]
        CPUS: 1
      UPTIME: 00:03:45
     NODENAME: centos-stream-10
     RELEASE: 6.12.0-centos10-arm64-local+
     MACHINE: aarch64  (unknown Mhz)
      MEMORY: 2 GB
       PANIC: "Kernel panic - not syncing: sysrq triggered crash"
         PID: 7991
     COMMAND: "07-trigger-cras"

crash> bt
PID: 7991     TASK: ffff0000107e9740  CPU/NUMA:    0/0    COMMAND: "07-trigger-cras"
 #0 [ffff800083bd39f0] crash_setup_regs at ffff8000802128f0
 #1 [ffff800083bd3a20] vpanic at ffff800080016b1c
 #2 [ffff800083bd3ad0] panic at ffff800080016d7c
 #3 [ffff800083bd3b20] sysrq_handle_crash at ffff8000809a55f0
 #4 [ffff800083bd3b30] __handle_sysrq at ffff8000809a5f3c
 #5 [ffff800083bd3b80] write_sysrq_trigger at ffff8000809a670c
 #6 [ffff800083bd3bc0] proc_reg_write at ffff8000805b9ca8
 #7 [ffff800083bd3c40] vfs_write at ffff8000804faaa0
 ...
#14 [ffff800083bd3fd8] el0t_64_sync at ffff800080011680
```

`RELEASE` matches the exact kernel this folder built (including the
`-arm64-local+` marker), `PANIC` matches the exact SysRq trigger
`07-trigger-crash.sh` sent, and `bt` shows a fully sane call stack from
`sysrq_handle_crash` straight down to the syscall entry point -- the same
bar `vanilla-x86-readme.md` Section 12 and `centos-x86-readme.md`'s "Validating the
result" apply to their own dumps. This is the complete chain, proven
working: cherry-picked kernel commits -> patched `kdump-utils` -> real
`kdumpctl`-driven LUKS setup -> unattended crash-kernel unlock -> valid,
analyzable vmcore.

## Re-running against the same disk image

Same logic as `centos-x86-readme.md`'s equivalent section --
`run-all.sh` already passes `FORCE=yes` to `03-create-luks-target.sh`, so
re-running `luks-kdump-centos-arm64-test.py` directly (no rebuild) is
sufficient for an ordinary repeat run against an already-staged rootfs.
The one ARM64-specific addition: if `make-centos-rootfs.sh` or
`install-modules-dracut.sh` is ever re-run from scratch (a fresh rootfs,
or a fresh `dnf`-installed `kdump-utils` package), **`luks/patch-kdump-utils-arm64.sh`
must be re-run too** before the next test -- a fresh rootfs has the
original, unpatched `kdumpctl`/`module-setup.sh`, and the x86_64-only
gates will be back.

| What changed | What to re-run | Why that's enough |
| --- | --- | --- |
| Nothing -- just running the test again | `./centos-arm64/luks/luks-kdump-centos-arm64-test.py` directly | `FORCE=yes` already handles the "already active" guard; the `kdump-utils` patch is already on-disk from the prior run. |
| `encrypt_crash_kernel/scripts/*` edited on the host | `luks/stage-kdump-scripts-arm64.sh`, then the test | Only re-copies the toolkit; the `kdump-utils` patch is untouched and does not need reapplying. |
| Kernel or modules rebuilt | `VOLUME=centos-kernel-arm64-build install-modules-dracut.sh`, then the test | Picks up the new `Image`/modules; the rootfs's installed packages (including the already-patched `kdumpctl`) are untouched. |
| Rootfs rebuilt from scratch (`make-centos-rootfs.sh` reran) | `install-modules-dracut.sh`, `stage-kdump-scripts-arm64.sh`, **`luks/patch-kdump-utils-arm64.sh`**, then the test | A fresh `dnf --installroot` reinstalls the unpatched `kdump-utils` package -- the gate-lifting patch must be reapplied, or the test will regress to [What failed on the first run](#what-failed-on-the-first-run). |
