# Automatic filesystem checking at boot

## Goal

Check and safely repair an installed Sowa system's ext4 root filesystem before
it is mounted, then check eligible non-root filesystems before `mount -a`.
Clean filesystems should add negligible boot time. Corruption that cannot be
repaired safely must never result in the affected filesystem being mounted
read-write.

This feature is for filesystem consistency. It must not claim to repair a
physically failing device; repeated I/O errors require recovery or replacement
of the device rather than increasingly aggressive `fsck` runs.

## Current state

- Installed systems boot `/boot/vmlinuz` directly with
  `root=PARTUUID=... rw` and no initramfs.
- The kernel consequently mounts root read-write before `/sbin/init` starts.
- `rc.sysinit` calls `mount -a` and `swapon -a`, but does not call `fsck`.
- Generated fstab files already use pass 1 for root and pass 2 for other
  filesystems.
- `fsck`, `e2fsck`, and `fsck.fat` are present in the installed system.
- `CONFIG_BLK_DEV_INITRD=y`, devtmpfs, procfs, sysfs, ext4, and the required
  storage drivers are built into the kernel.

A root check must therefore happen in a new early-userspace environment. Adding
`fsck` only to `rc.sysinit` would be too late for root, although it is suitable
for non-root filesystems that have not yet been mounted.

## Chosen architecture

Add a disk-specific initramfs and keep it separate from the live-medium
initramfs. The live init deliberately probes disks without modifying them,
including using `noload` for ext4. Disk boot has the opposite responsibility:
it identifies one explicitly named root device, checks it, mounts it, and hands
control to the installed system.

The installed boot sequence becomes:

1. GRUB loads `/boot/vmlinuz` and `/boot/initramfs.img`.
2. The kernel starts the initramfs `/init` instead of mounting root itself.
3. Early init mounts procfs, sysfs, devtmpfs, and a tmpfs on `/run`.
4. It reads `root=` and waits for the named block device.
5. It runs `e2fsck` on the still-unmounted ext4 root according to the selected
   fsck policy.
6. It mounts root on `/new_root` with the requested read-only/read-write mode.
7. It moves the early virtual filesystems into the new root and calls
   `switch_root` to execute `/sbin/init`.
8. Before `mount -a`, `rc.sysinit` checks eligible non-root fstab entries.

The first implementation may explicitly support ext2/ext3/ext4 root filesystems,
which covers `sowa-setup` and the prebuilt disk image. A root filesystem type
that has no checker in the initramfs must be reported clearly and either mounted
without checking only under an explicit policy or rejected; it must not be
silently described as checked.

## Early init implementation

Create `src/diskinit/` containing a small, statically linked PID 1. Reuse or
factor out narrowly scoped code from `src/liveinit` where useful, particularly:

- `/proc/cmdline` parsing;
- console setup;
- procfs, sysfs, devtmpfs, and tmpfs mounting;
- block-device enumeration and bounded retry handling;
- fatal diagnostics and reboot support;
- mount-moving and `switch_root` logic.

Do not make disk repair part of live-medium probing. Keeping the programs
separate makes the live initramfs's no-write guarantee auditable.

Early init must accept these `root=` forms:

- `PARTUUID=<id>`;
- `UUID=<id>`;
- `/dev/<node>`.

Resolution may use an initramfs copy of `findfs`/`blkid`, or implement the
necessary resolution in early init using sysfs and libblkid. It must not depend
on udev-created `/dev/disk/by-*` symlinks. Device discovery must use a bounded
retry, honor `rootdelay=`, and print the device it selected.

Preserve boot arguments intended for the real init, including `single`, `S`,
runlevels, `emergency`, consoles, and `panic=`.

## Fsck policy

Support the following kernel-command-line interface:

- `fsck.mode=auto` (default): invoke the checker normally; a clean filesystem
  returns quickly, while the filesystem's state, mount count, and check interval
  determine whether a full check is due.
- `fsck.mode=force`: add `-f` and perform a full check.
- `fsck.mode=skip`: do not run a checker. Print that the check was skipped.
- `fsck.repair=preen` (default): use `e2fsck -p` and apply only repairs the
  checker considers safe for unattended operation.
- `fsck.repair=yes`: use `e2fsck -y`; expose this as an explicit operator
  choice, not the default.
- `fsck.repair=no`: use `e2fsck -n`; do not modify the filesystem.

Interpret e2fsck's bitmask exit status rather than treating every nonzero value
as the same failure:

- 0: no errors; continue.
- 1: errors corrected; continue.
- 2: errors corrected but reboot required; sync and reboot without mounting
  root.
- 4 or any status containing bit 4: errors remain; do not mount root
  read-write.
- 8, 16, 32, or 128: operational, usage, cancellation, or library failure; do
  not mount root read-write.

If multiple bits are present, the most restrictive action wins. Log the exact
checker command, target device, exit status, and resulting decision without
discarding e2fsck's own console output.

An unrepaired root must lead to a stable recovery state, not an automatic
reboot loop. Preferred behavior is an initramfs recovery shell. If adding a
shell is deferred, stop with a readable console message and require an
operator reboot. Provide a GRUB entry or documented edit using
`fsck.mode=skip` so an operator can make an explicit recovery decision.

## Initramfs contents and build

Extend the image build to create a second initramfs for installed disk boot;
the existing live initramfs remains unchanged.

The disk initramfs needs at least:

- `/init` from `src/diskinit`;
- `/usr/sbin/e2fsck`;
- the ELF interpreter and runtime libraries required by e2fsck (`libc`,
  `libblkid`, and `libuuid` in the current build), preserving their symlink
  chains;
- a resolver executable and its dependencies if root resolution is not built
  into `/init`;
- `/dev`, `/proc`, `/sys`, `/run`, and `/new_root` directories;
- any e2fsck configuration file actually required by the built version.

Assert during the build that every dynamically linked initramfs executable has
its interpreter and dependencies in the archive. Assert the target architecture
and test the archive with `xz -t`, as the live initramfs stage already does.

Install the reproducible archive as `/boot/initramfs.img` in the assembled
rootfs so that `sowa-setup`, `sowa-bootstrap`, the rootfs tarball, and the
prebuilt disk image all receive it. Decide and document package ownership. The
kernel package is the natural owner if it always ships `/boot/vmlinuz` and the
matching boot initramfs together.

Invalidate and rebuild the disk initramfs when any of these change:

- `src/diskinit`;
- e2fsprogs or its embedded runtime libraries;
- the initramfs assembly script;
- relevant filesystem or storage configuration.

Because all necessary storage drivers are built into the kernel, this
initramfs need not carry kernel modules and need not be specific to a kernel
release solely for module compatibility.

## Bootloader changes

Every installed-system boot path must load the new archive. Update:

- `rootfs-overlay/etc/grub.d/10_linux`;
- `rootfs-overlay/usr/sbin/sowa-setup`;
- the hand-written example printed by `sowa-bootstrap`;
- `scripts/stages/image/disk-image.sh`;
- associated manual pages and installation documentation.

Each normal and single-user entry needs:

```grub
linux /boot/vmlinuz root=PARTUUID=... rw ...
initrd /boot/initramfs.img
```

The early init, rather than the kernel's direct-root path, now decides when to
mount root. Retain `rw` as the requested final root mode, or replace it with an
explicit Sowa argument if doing so makes the implementation less ambiguous.

Add a recovery menu entry where Sowa writes a complete static GRUB menu:

```grub
menuentry "Sowa Linux (skip filesystem check)" {
    linux /boot/vmlinuz root=PARTUUID=... rw fsck.mode=skip ...
    initrd /boot/initramfs.img
}
```

For `grub-mkconfig`, document that the same result can be obtained by editing
the selected menu entry and appending `fsck.mode=skip`; avoid making skip the
normal default.

## Non-root filesystems

In `rc.sysinit`, immediately before `mount -a`, run the util-linux frontend in
preen mode for eligible fstab filesystems while excluding root and anything
already mounted, approximately:

```sh
fsck -A -R -M -p
```

Capture and interpret its bitmask status. Continue after statuses 0 and 1.
Reboot for status 2. For uncorrected or operational failures, do not mount the
affected filesystems and enter the system's defined recovery behavior rather
than merely printing a warning and continuing.

Respect fstab pass numbers and standard `noauto` behavior. In particular, the
ESP written by Sowa is `noauto`; it need not delay every boot unless a separate
policy explicitly elects to check it. Do not attempt a checker for a filesystem
type whose checker is absent.

## Recovery and operator safety

- Never run e2fsck against a mounted root filesystem.
- Never default to `-y`.
- Never continue by mounting root read-write after uncorrected checker errors.
- Detect and clearly report repeated I/O errors. State that the next step is to
  clone or replace the device, not repeatedly force repairs.
- Keep live-media disk probing read-only and separate from installed-system
  repair.
- Ensure a user can select `fsck.mode=skip`, `fsck.mode=force`, and a recovery
  environment from the console.
- Avoid reboot loops after exit status 2 by recording or otherwise ensuring
  that a successful repair is observed on the following boot; unrepaired
  failures must remain stopped for operator action.

## Documentation updates

Replace statements that installed Sowa boots without an initramfs in:

- `README.md`;
- `docs/architecture.md`;
- `docs/disk-image.md`;
- `docs/init.md`;
- `docs/install.md`;
- relevant `sowa-setup` and `sowa-bootstrap` manual pages and messages;
- comments in the kernel, image, GRUB, and rootfs-tarball stages.

Document:

- what `auto` checks and when a full scan occurs;
- the difference between journal replay and a full fsck;
- the repair policy and exit-status decisions;
- force and skip command-line controls;
- recovery steps for uncorrected errors and failing storage;
- that live-media boot behavior is unchanged.

## Tests

Add automated QEMU coverage for BIOS and UEFI where applicable:

1. A clean ext4 root boots and reports a successful or unnecessary check.
2. An unclean shutdown causes journal/filesystem recovery and then boots.
3. Deliberately introduced, safely correctable metadata damage is repaired and
   the system boots.
4. Damage that `e2fsck -p` cannot repair stops before a read-write root mount.
5. `fsck.mode=force` performs a full check.
6. `fsck.mode=skip` bypasses the checker and is reported on the console.
7. `fsck.repair=no` detects damage without changing it and does not proceed to
   an unsafe read-write mount.
8. A delayed block device is found within `rootdelay=` and a missing one fails
   with a bounded, readable diagnostic.
9. Direct `/dev/...`, `UUID=...`, and `PARTUUID=...` root specifications resolve
   correctly.
10. A non-root ext4 filesystem with fstab pass 2 is checked before mounting.
11. A clean shutdown leaves root clean for the next boot.
12. Normal, single-user, installer-created, bootstrap-generated, prebuilt disk,
    BIOS, and UEFI boot paths all load the initramfs.

Use disposable copies of disk images for corruption tests. Suitable tools
include `debugfs`, `tune2fs`, and deliberate termination of QEMU without a guest
shutdown. Verify both console output and final mount state; a login prompt alone
does not prove the filesystem was checked safely.

## Acceptance criteria

- Root is never checked while mounted.
- A normal clean boot reaches the same runlevel and consoles as before.
- Safe automatic repairs boot successfully and are visible in the log.
- Unrepaired damage cannot lead to a read-write mount.
- Non-root pass-2 filesystems are checked before `mount -a` mounts them.
- All Sowa-created installed boot menus load `/boot/initramfs.img`.
- The live ISO's read-only probing behavior is unchanged.
- Force, skip, and recovery behavior are documented and tested.
- The rootfs tarball, interactive installer, and prebuilt disk image contain
  both the kernel and disk initramfs.
