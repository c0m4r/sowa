# The live medium

`make iso` builds a GRUB-based, `isohybrid` optical/USB image at
`artifacts/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.iso`. It reuses the same
audited release artifacts as `make image`: the pinned kernel, the squashfs root
filesystem, and the initramfs that mounts it. The stage never installs into the
host and only adds a boot layer around those existing files.

The root filesystem is *mounted* rather than unpacked to keep memory use
bounded. Sowa used to place the entire root filesystem in the initramfs, so the
kernel expanded close to a gigabyte of files into a ramfs whose pages could not
be reclaimed. That required about 3 GiB before the system had done useful work
and failed poorly below the limit.

## What the ISO contains

```text
/boot/vmlinuz                    the release kernel
/boot/initramfs.img              liveinit, and nothing else (~1 MiB)
/boot/grub/grub.cfg              the boot menu
/boot/grub/loopback.cfg          for a GRUB that boots this ISO from a file
/sowa/<id>.id                    the marker that identifies this medium
/sowa/x86_64/root.sfs            the root filesystem, squashfs
/sowa/x86_64/root.sfs.sha256     what checksum=y verifies it against
/sowa/pkglist.x86_64.txt         every package in the image and its version
```

`/sowa` is the base directory, named after `DISTRO_NAME` and passed to the
kernel as `sowa.basedir=`. Nothing outside `/boot` is read by firmware or by
GRUB — it is the payload, and Linux finds it for itself.

## How it boots

GRUB (BIOS via El Torito and the isohybrid MBR, UEFI via the FAT El Torito
image `grub-mkrescue` builds) loads the kernel and the initramfs, and the
kernel runs `/init`. That is [`src/liveinit/liveinit.c`](../src/liveinit/liveinit.c),
one static binary, which does the whole of early userspace:

```text
mount /proc, /sys, devtmpfs on /dev, tmpfs on /run
  -> find the medium
  -> optionally copy the squashfs into RAM
  -> optionally verify its SHA-256
  -> attach it to a loop device, mount it read-only on /run/sowa/sfs
  -> mount a tmpfs and overlay it: lowerdir=sfs, upperdir=cow/upper
  -> move /dev, /proc, /sys and /run into the new root
  -> switch_root and exec /sbin/init
```

There is deliberately no shell in this initramfs and nothing else to fall back
on. That is what keeps it at one megabyte rather than the twenty a Bash,
util-linux and glibc early userspace costs — and it is why every failure in
`liveinit` prints what it tried, including the list of block devices it looked
at, before rebooting after thirty seconds.

`/etc/rc.d/rc.sysinit` then finds `/proc`, `/sys`, `/dev` and `/run` already
mounted and skips them; every mount it makes is guarded by a test, which is
what lets one script serve both the live medium and an installed disk.

## Finding the medium

The medium is identified by `sowa.id=`, and the id is **the first 16 hex digits
of the squashfs's SHA-256**. The ISO stage writes an empty
`/sowa/<id>.id` beside the payload, and `liveinit` mounts each block device
read-only in turn — removable ones first, trying `iso9660`, then `vfat`, then
`ext4` — until it finds one carrying that file.

Deriving the id from the payload means two Sowa media are the same exactly when
they carry the same root filesystem. A rebuild that changes nothing produces
the same id, while a machine with two different Sowa media attached boots the
one it was started from. It also avoids using a creation timestamp that would
vary otherwise reproducible output.

Nothing depends on a device name or a filesystem label, both of which a second
copy of the medium would collide on. The search is retried for `rootdelay=`
seconds (default 30), because a USB controller takes seconds to enumerate a
stick and sysfs shows nothing at all until it has.

## Memory, and `copytoram=auto`

**512 MiB of RAM is enough**, and the figure no longer depends on the size of
the tree: the squashfs is read through the page cache, which the kernel can
evict, and only the writable tmpfs layer is unreclaimable.

`copytoram=auto` is on the command line of every menu entry. It copies the
whole image into RAM before mounting it — which is faster and frees the medium
— when all three of these hold:

| condition | why |
| --- | --- |
| the medium is not optical | a disc is in a drive nobody is going to walk off with, so the copy buys only speed, and buys it with the memory the live system was booted to use |
| the image is under 4 GiB | past that the copy takes longer than the boot it saves |
| `MemAvailable` > image + 2 GiB | a system that copies still has to have somewhere to work |

Otherwise it streams from the medium and boots anyway. Neither outcome is a
failure, which is the point of deciding at boot rather than at build time — the
old design made this choice unconditionally, in favour of RAM, at build time.
`make image` and `make iso` both print the two figures: the floor, and the
threshold at which the copy happens.

`copytoram=y` and `copytoram=n` force it either way. When the copy happens,
`liveinit` unmounts the medium and says so on the console; the stick can be
pulled from that moment.

## The boot menu

Four entries. Integrity checking is on unless the third one explicitly turns
it off:

```text
Sowa Linux 0.1                            adds checksum=y; the default
Install Sowa Linux 0.1                    adds checksum=y and sowa.setup=y
Sowa Linux 0.1 (skip medium verification) omits checksum=y
Sowa Linux 0.1 (single user)              adds checksum=y and single
```

`checksum=y` reads the whole image and compares it against
`root.sfs.sha256` before mounting anything. Doing that by default finds a
damaged USB stick or optical disc before a corrupt block becomes a failure much
later in boot. The skip entry is the escape hatch for slow media that was
already checked independently.

The checksum and the image sit on the same medium. This is an integrity check,
not authenticity: an attacker who replaces the ISO can replace both. Verify the
external signed release manifest before writing or booting the image; see
[Release authenticity](releases.md).

`sowa.setup=y` makes the waited boot task in `/etc/inittab` run `sowa-setup`
after `rc.sysinit` has prepared the live root and before the normal runlevel
starts. The installer therefore owns the boot console without competing with a
login prompt. If it returns, whether after installation or cancellation, boot
continues to the ordinary live login. The entry keeps `checksum=y`: a system
should not be installed from a damaged image merely because setup was selected
directly. The hook also requires liveinit's `/run/sowa/sfs` mount, so an
installed system ignores this parameter instead of offering to reinstall its
running disk.

`single` is not a parameter `liveinit` claims, so it is passed through to
`/sbin/init` exactly as the kernel would have passed it had there been no
initramfs — init stops at runlevel S with a root shell.

Every entry names both consoles. The order still decides `/dev/console` — it is
whichever `console=` comes last — and `ttyS0` is deliberately last, so init's
own messages and the single-user shell follow the serial line as the rest of
Sowa's tooling does. The login prompt does not depend on it:
[inittab](../rootfs-overlay/etc/inittab) puts a getty on each console. A serial
port the machine has not got is the getty's problem rather than the menu's, and
[`/usr/sbin/serial-getty`](../rootfs-overlay/usr/sbin/serial-getty) is where it
is solved.

`grub.cfg` still probes for a serial port, but only to decide where GRUB draws
its own menu:

```
if serial --unit=0 --speed=115200; then
    terminal_input serial console
    terminal_output serial console
fi
```

GRUB's `ns8250` driver only registers a port whose line status register reads
back something other than `0xff`, which a floating ISA bus does not, so this
fails on a machine with no UART and succeeds under QEMU, where `make run-iso`
drives the whole boot over `ttyS0`. The test is what guards the
`terminal_input`/`terminal_output` pair: naming a terminal GRUB never
registered is an error. The timeout is five seconds.

## Booting the ISO from a file

`/boot/grub/loopback.cfg` is for a GRUB on some other system that loop-mounts
the image rather than booting a medium:

```
menuentry "Sowa" {
    set isofile=/sowa.iso
    loopback loop $isofile
    configfile (loop)/boot/grub/loopback.cfg
}
```

The loopback menu offers both live and install entries. Both pass
`checksum=y img_loop=${iso_path}` instead of leaving `liveinit` to find a
medium, and the install entry also passes `sowa.setup=y`. `liveinit` then looks
for that path on every block device it can mount
— `img_dev=/dev/sda1` restricts the search to one — attaches the ISO to a loop
device, mounts it, and carries on from there exactly as if it had been a
medium. Searching for the file is what lets this work without teaching a
one-megabyte initramfs to resolve `UUID=`.

## Kernel command line

The live boot path's parameters, all optional:

| parameter | default | meaning |
| --- | --- | --- |
| `sowa.id=HEX` | — | the medium's identity; without it, any medium carrying a `root.sfs` will do |
| `sowa.basedir=DIR` | `sowa` | the base directory on the medium |
| `copytoram=auto\|y\|n` | `auto` | copy the image into RAM before mounting it |
| `cow_spacesize=SIZE` | half of RAM | `size=` for the writable overlay tmpfs |
| `checksum=y` | off in `liveinit`; the ISO passes it by default | verify the image before mounting it |
| `sowa.setup=y` | off | launch `sowa-setup` before entering the normal live runlevel |
| `img_loop=PATH` | — | boot an ISO stored as a file |
| `img_dev=DEVICE` | — | restrict the `img_loop` search to one device |
| `rootdelay=SECONDS` | 30 | how long to wait for the medium to appear |

Sowa leaves the tmpfs at its default of half of RAM: the live system is used to
install packages and run a compiler, and a small fixed cap would turn ordinary
work into an out-of-space error far from its cause.

## The kernel it needs

A from-RAM boot could reach a login prompt on a machine whose disks it could
not see at all. This one has to find the medium, so
[`config/kernel-x86_64.fragment`](../config/kernel-x86_64.fragment) carries the
whole storage stack — SCSI with its disk and CD-ROM drivers, ATA/AHCI, NVMe,
every USB host controller plus `usb-storage` and UAS, MMC — along with
`ISO9660_FS`, `BLK_DEV_LOOP`, `SQUASHFS` and `OVERLAY_FS`. This kernel has no
module loader, so every one of them is built in.

`TMPFS_XATTR` is the non-obvious entry: overlayfs records deletions from its
lower layer in `trusted.overlay.*` extended attributes on the upper one, so a
tmpfs built without xattr support cannot be an `upperdir` at all — the mount
fails and the live system has no root filesystem.

## Building it

`make image` needs `mksquashfs` (squashfs-tools); `make iso` needs
`grub-mkrescue` and `xorriso`, plus `mtools` for the optional UEFI image. These
are required only for those targets, not for the core toolchain, kernel, or
root filesystem build, so they are checked inside the stages rather than by
`make check`.

The root filesystem is compressed with xz, the x86 BCJ filter, and 1 MiB blocks
for the smallest image. `SFS_COMPRESSOR=zstd` in
[`config/build.conf`](../config/build.conf) is the other sensible answer:
roughly a tenth larger and several times faster to read, which is what a
machine that streams rather than copies actually feels.

When the host provides `mtools` and the GRUB `x86_64-efi` platform files, the
result is a hybrid image that boots on BIOS and UEFI firmware. When either is
missing the stage prints a warning and restricts
`grub-mkrescue` to the BIOS platform, producing a valid BIOS-only ISO rather
than failing.

## Reproducibility

`mksquashfs` is given `-all-root`, both time options fixed to
`SOURCE_DATE_EPOCH`, and the deterministic ordering it uses by default, so the
same tree produces the same image — and therefore the same medium id. The stage
runs under the shared build environment, so `xorriso` honors
`SOURCE_DATE_EPOCH` for its filesystem timestamps. As noted in
[architecture.md](architecture.md), bit-identical output across different hosts
is not yet a release claim; the GRUB core image in particular depends on the
host GRUB build.

## Installed systems pay none of this

`sowa-setup` writes a real root filesystem to disk and the installed machine
boots the kernel directly with `root=` and no initramfs at all — no squashfs,
no overlay, no `liveinit`. See [install.md](install.md).
