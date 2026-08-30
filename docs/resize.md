# Resizing the disk

`sowa-setup` gives the root partition every sector left after the EFI System
Partition, so a fresh install already fills the disk it was installed on.
Resizing is for what happens afterwards: a VM's virtual disk is enlarged, the
image is copied onto a larger drive, or a disk image created small is grown
later. None of that reaches the guest on its own - the partition table and the
ext4 superblock both still describe the old geometry, and `df` keeps reporting
the old size until they are updated.

Root is the last partition on the disk (see
[docs/install.md](install.md#disk-layout)), so growing it never involves moving
anything. It is two steps: extend partition 2 to the new end of the disk, then
extend the filesystem inside it.

## What the system provides

Everything needed is in the image already, on the installed system and on the
live ISO alike:

- **util-linux** - `sfdisk` to rewrite the partition entry, `partx` to tell the
  running kernel about it, `blockdev` to read the disk's real size.
- **e2fsprogs** - `resize2fs` to grow or shrink the ext4 filesystem, `e2fsck`
  for the offline path.

These are the full util-linux and e2fsprogs programs, under `/usr/sbin`, and
nothing in the image answers to those names ahead of them - `sfdisk -N`, which
this whole procedure turns on, is a flag smaller implementations tend not to
have.

## Doing it automatically

`/etc/init.d/growroot` is this procedure as a service. It ships switched off,
because a machine `sowa-setup` installed already fills its disk and has nothing
to grow; the prebuilt disk image (see [docs/disk-image.md](disk-image.md)) is
smaller than any disk it will be written to and is the one artifact that ships
it enabled. Turn it on anywhere else with:

```sh
chkconfig growroot on
```

It runs first in the runlevel, does nothing on a disk that is already full, and
refuses — with a reason — when root is not an ext filesystem on the last
partition of a disk. Everything below is what it does, and what to do by hand
when it says it will not.

## Growing disk image

```sh
fallocate -l 10G artifacts/sowa-0.1-x86_64-disk.img
```

## Growing the root filesystem

The starting point looks like this - an 8 GiB disk whose partition 2 still ends
where the old 4 GiB disk did:

```text
Device     Boot   Start     End Sectors  Size Id Type
/dev/sda1          2048 1050623 1048576  512M ef EFI (FAT-12/16/32)
/dev/sda2       1050624 8388607 7337984  3.5G 83 Linux
```

ext4 grows online, so this runs on the live system with root mounted; GRUB
already boots it `rw`, so no remount is needed:

```sh
# 1. extend partition 2 to the end of the disk, keeping its start sector
echo ', +' | sfdisk -N 2 --force /dev/sda

# 2. update the running kernel's idea of the partition size
partx -u /dev/sda

# 3. grow the filesystem into the new space
resize2fs /dev/sda2

df -h /
```

The `, +` line is a one-partition sfdisk script: an empty start field means
"leave the start where it is", and `+` for the size means "take everything
available". `--force` is what gets past the warning about editing a disk that is
in use.

Step 2 is the one that is easy to miss. Rewriting the partition table does not
change the size the kernel has already registered for `/dev/sda2`, and
`resize2fs` asks the kernel, not the disk - skip it and `resize2fs` reports
"nothing to do" against the old 3.5 GiB size. `sowa-setup` uses
`blockdev --rereadpt` instead, which it can afford to because it is partitioning
a disk nothing has mounted yet; on a running system the whole-disk re-read fails
with `EBUSY`, while `partx -u` updates the individual partition in place.

## What does not change

- **The PARTUUID.** On an MBR label it is derived from the 4-byte disk
  signature and the partition number (`SSSSSSSS-02`), not from the partition's
  size, so the `root=PARTUUID=...` in `/boot/grub/grub.cfg` and the entries in
  `/etc/fstab` stay correct.
- **GRUB.** The BIOS core image lives in the MBR gap before partition 1 and the
  UEFI binary lives on the ESP; neither is touched by extending partition 2.
  There is no need to re-run `grub-install`.
- **The filesystem's features.** `sowa-setup` creates root with
  `-O ^orphan_file,^metadata_csum_seed` because GRUB 2.12's ext2 driver cannot
  read those, and `resize2fs` does not enable features. Do not "modernise" the
  root filesystem with `tune2fs -O` afterwards - it boots today because those
  two are off.

## Growing the underlying disk first

`scripts/run-qemu.sh` creates `artifacts/<name>-<version>-<arch>-disk.img` with
`truncate` at `SOWA_DISK_SIZE` (4 GiB by default). To give an existing VM more
room, grow the image while the guest is powered off, then boot it and follow the
steps above:

```sh
truncate -s 16G artifacts/sowa-0.1-x86_64-disk.img
make run-disk
```

For a fresh install, set the size up front instead and `sowa-setup` will use
all of it: `SOWA_DISK_SIZE=16G make run-install`.

On real hardware the equivalent is the storage layer's own resize (hypervisor
disk expansion, LUN growth, a larger physical disk written with `dd`); the guest
side is identical. `blockdev --getsz /dev/sda` reports the sector count the
kernel currently sees, which is the number to check if a hypervisor-side resize
does not seem to have arrived.

## Shrinking

Shrinking is the reverse order and cannot be done online: the filesystem must
come down before the partition does, and ext4 refuses to shrink while mounted.
Do it from the ISO, which has the same tools and leaves `/dev/sda` unmounted
(`make run-install` boots the ISO with the disk attached; `make run-recovery`
boots the recovery initramfs without one):

```sh
e2fsck -f /dev/sda2                 # required; resize2fs refuses otherwise
resize2fs /dev/sda2 6G              # filesystem first, to a size you are sure of
echo ', 13631488' | sfdisk -N 2 --force /dev/sda   # then the partition, in sectors
```

Leave slack between the two sizes - 6 GiB of filesystem inside a 6.5 GiB
partition above. A partition that ends before the filesystem does destroys the
filesystem. Back up first - unlike growing, this path has no
safe failure mode.

## Using the free space without touching root

Growing root is not the only option. The free space after partition 2 can hold a
separate partition:

```sh
echo ', +, 83' | sfdisk -a --force /dev/sda      # append partition 3
partx -a /dev/sda
mkfs.ext4 -O '^orphan_file,^metadata_csum_seed' -L data /dev/sda3
```

`/etc/rc.d/rc.sysinit` runs `mount -a`, so an `/etc/fstab` entry for it is
mounted at boot. The feature flags only matter for a filesystem GRUB has to
read, so they are optional here, but they keep the disk consistent with root.

Swap is different: `mkswap` and `swapon` are present, but nothing in
`rc.sysinit` calls `swapon -a`, so an `sw` entry in `/etc/fstab` alone does not
activate it. Call `swapon` from an rc script or an inittab entry.

## The ESP cannot grow in place

Partition 1 is followed immediately by root, so enlarging it would mean moving
every sector of the root filesystem. The supported way to get a bigger ESP is to
reinstall with `SOWA_SETUP_ESP_SIZE_MB` set. The 512 MiB default has room for
several kernels, so this rarely comes up.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `resize2fs: The filesystem is already ... blocks long. Nothing to do!` | `partx -u` was skipped, so the kernel still reports the old partition size |
| `sfdisk: device is in use` | add `--force`; it is expected when editing a mounted disk |
| `resize2fs: Please run 'e2fsck -f' first` | the filesystem is not clean, or an offline shrink was attempted - both need `e2fsck -f` with the partition unmounted |
| `df` unchanged after all three steps | check `/` is really on `/dev/sda2` (`findmnt /`) and not an overlay from a live boot |
| Partition table looks right but the system boots to a GRUB rescue prompt | unrelated to the resize; the PARTUUID does not change, so check whether the filesystem was recreated rather than resized |
