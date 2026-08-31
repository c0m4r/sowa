# Installing Sowa to a disk

`sowa-setup` installs the live system onto a disk so the machine boots Sowa on
its own. It runs inside the live ISO environment, is installed at
`/usr/sbin/sowa-setup`, and works on both legacy BIOS and UEFI firmware.

The other way to get the same result is not to install at all: `make disk-image`
builds a disk with this layout already on it, which is written to a drive with
`dd` or attached to a virtual machine. See [docs/disk-image.md](disk-image.md).
It is this document's layout, built without booting anything; `sowa-setup`
remains the way to install onto a machine's own disk, with its own partition
sizes and its own password.

## What the live system already provides

The block-device toolkit the installer relies on is already in the image:
`sfdisk`, `blockdev`, `lsblk` and `mount`/`umount` from util-linux, `chroot`,
`dd`, `od` and `sync` from coreutils, and GNU `tar`. Three cross-built packages
are there specifically for installation:

- **e2fsprogs** - `mke2fs`/`mkfs.ext4` for the ext4 root filesystem.
- **dosfstools** - `mkfs.fat` for the FAT EFI System Partition.
- **GRUB** (`i386-pc` and `x86_64-efi`) - `grub-install` and the boot modules.

The kernel is embedded in the image at `/boot/vmlinuz`, so the installer copies
the system's own kernel to the target.

## Disk layout

The installer writes an MBR "hybrid" layout that both firmwares can boot,
rather than GPT. That was once a limit of the only `sfdisk` in the image and is
now a limit of `sowa-setup` alone: util-linux's `sfdisk` writes GPT, so the
layout below is what the installer implements, not what the image can do.

```text
sector 2048            partition 1  type 0xEF  FAT32  EFI System Partition
after the ESP          partition 2  type 0x83  ext4   root filesystem
MBR gap (sectors 1-2047)                        GRUB BIOS core image
```

- **BIOS**: `grub-install --target=i386-pc` embeds the GRUB core image in the
  ~1 MiB gap before the first partition and writes boot code to the MBR.
- **UEFI**: `grub-install --target=x86_64-efi --removable` writes
  `EFI/BOOT/BOOTX64.EFI` to the ESP. Removable mode means firmware boots it
  without an NVRAM boot entry, so no `efibootmgr` is required.

The root partition takes every remaining sector, so the install fills whatever
disk it is given. If that disk is enlarged later, see
[docs/resize.md](resize.md) for growing the partition and the filesystem.

The installer writes a random 4-byte MBR disk signature and derives the kernel's
`root=PARTUUID=SSSSSSSS-02` from it, which the kernel resolves natively with no
initramfs. The installed system boots `/boot/vmlinuz` directly with
`init=/sbin/init`: no `liveinit`, no squashfs and no overlay, just the disk.

## What is copied

What is copied is the live root as it stands now - the merged view of the
read-only squashfs and everything written over it since boot - in a single
`tar` pass, skipping the kernel's
virtual filesystems (`/proc`, `/sys`, `/dev`), the transient ones (`/run`,
`/tmp`), and `/mnt`, where the target itself is mounted. Those directories are
then recreated empty on the target, because `/etc/rc.d/rc.sysinit` mounts proc,
sysfs, and devtmpfs over them on the next boot and `mount` fails on a missing
mount point. The installer also creates `/dev/console` and `/dev/null` as real device
nodes: the kernel opens `/dev/console` for init before init has had a chance to
mount devtmpfs.

The target's root partition has to hold the whole live root, so the installer
sizes its check from what the live system actually occupies (about 450 MiB
today) plus half again for ext4 metadata, the journal, and reserved blocks.
With the default 512 MiB ESP that puts the practical minimum disk at roughly
1.5 GiB.

## Usage

Choose `Install Sowa Linux` in the ISO's GRUB menu to boot directly into the
installer. The medium is verified first, then `sowa-setup` starts on the boot
console before the live login prompts appear.

Alternatively, choose the normal live entry, log in as root, then run:

```sh
sowa-setup
```

It lists the disks, asks for a target, and requires typing `yes` before erasing
it. Then — still before it writes anything — it asks twice, without echo, for
the root password the installed system will have, and applies it after the copy.
Asking up front is deliberate: the copy takes minutes and nobody is waiting at
the end of them.

An empty answer is accepted, and warned about: it leaves the account exactly as
the image ships it, which is passwordless. That is right for a live system that
is thrown away at reboot — and, on an installed one, means anyone at the console
is root. `sshd` refuses an empty password either way
(`PermitEmptyPasswords no`), so a machine reached only by key can legitimately
want it.

For unattended installs (used by `make run-install` testing) it is driven by
environment variables:

| Variable | Effect |
| --- | --- |
| `SOWA_SETUP_DISK` | target device (e.g. `/dev/sda`); skips the menu |
| `SOWA_SETUP_ASSUME_YES=1` | skip the destructive-wipe confirmation and the password prompt |
| `SOWA_SETUP_ROOT_PASSWORD` | set the installed root password without being asked |
| `SOWA_SETUP_ESP_SIZE_MB` | ESP size in MiB (default 512) |
| `SOWA_SETUP_HOSTNAME` | hostname for the installed system |

The prompt is skipped whenever it cannot be answered or has been answered
already: `SOWA_SETUP_ROOT_PASSWORD` set, `SOWA_SETUP_ASSUME_YES=1`, a standard
input that is not a terminal, or no `openssl` to hash the answer with. An
unattended install with no password named therefore installs a passwordless
root, as it always has.

## Installing into a filesystem you mounted yourself

`sowa-setup` owns the whole disk, which is what lets it be a single command —
and what stops it being usable on any layout but its own. `sowa-bootstrap`
is the same install with the disk half removed:

```sh
sowa-bootstrap /mnt
sowa-bootstrap --from-tarball sowa-0.1-x86_64-rootfs.tar.xz /mnt
```

It copies the live root into a directory where you have already mounted a
filesystem — with the same single `tar` pass, the same host-key reset and the
same recreated mount points — and then stops and prints what is left. That is
the path for LVM, RAID, an encrypted root, a custom multiboot layout, or a plain
directory that is only ever going to be a chroot.

With `--from-tarball` the source is a rootfs tarball made by
`make rootfs-tarball` instead of the running root, so the copy installs that
image as it was built rather than the live system as it now stands. The
tarball is unpacked with the same root ownership and modes the live copy would
have had, and refused if it does not hold a Sowa system.

What it prints is the three things it deliberately does not do, with the real
device names filled in wherever it can work them out: the `/etc/fstab` line for
the filesystem you mounted (named by PARTUUID, which it reads off the device),
both `grub-install` invocations, and a `grub.cfg` menu entry. Those depend on a
layout only the person who made it knows, and a boot loader written to a disk
this program merely guessed at is the one mistake it must not make.

The destination is excluded from the copy, so bootstrapping into a directory on
the running root filesystem is safe rather than a copy that feeds itself.

The `grub.cfg` entry it prints can also be generated instead of typed: the image
ships `/etc/default/grub` and a Sowa `10_linux`, so

```sh
sowa-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
```

writes the same single entry — kernel by PARTUUID, `rw`, both consoles — from
the system's own settings. That is the path to take after a kernel upgrade
replaces `/boot/vmlinuz`, and it is the same file `grub-install` reads.

It asks for a root password too, on the same terms as `sowa-setup`: after the
confirmation, before the copy, twice and without echo, with an empty answer
accepted and warned about. Here the prompt is also skipped when the host has no
`openssl` — a real possibility on somebody else's rescue system, and a reason to
drop the question rather than to fail the install.

| Variable | Effect |
| --- | --- |
| `SOWA_BOOTSTRAP_ASSUME_YES=1` | skip the confirmation and the password prompt |
| `SOWA_BOOTSTRAP_ROOT_PASSWORD` | set the installed root password without being asked |
| `SOWA_BOOTSTRAP_HOSTNAME` | hostname for the installed system |
| `SOWA_BOOTSTRAP_QUIET=1` | do not print the closing instructions |

## Working inside an installed system

```sh
sowa-chroot /mnt                    # a login shell
sowa-chroot /mnt grub-install ...   # one command, then leave
```

`chroot(8)` on its own changes the root directory and nothing else, which
leaves the new root without `/proc`, `/sys` or `/dev` — and almost everything
worth running in there needs at least one of them, `grub-install` above all,
since it reads `/sys` and `/dev` to find the disk it is being pointed at.
`sowa-chroot` mounts the four kernel filesystems, runs the shell or command,
and unmounts them in reverse on the way out, whether that shell exited cleanly
or not.

`/proc` and `/sys` are mounted fresh. `/dev` is recursively bind-mounted and
made a slave, because a fresh `devtmpfs` would carry the device nodes but not
`/dev/pts`, which is a separate filesystem mounted over it — and without a pty
there is no job control in the chroot's shell. `/run` is a new tmpfs rather
than a bind of the host's, because `/run` holds the state of the processes
running *now* and the chroot's are not those; a new tmpfs is also exactly what
the installed system gets from `rc.sysinit` at boot. On a UEFI host,
`efivarfs` is mounted too, so a `grub-install` run inside can write an NVRAM
entry.

It refuses a destination that does not hold a Sowa system — checked by reading
`ID=sowa` out of its `/etc/os-release` and looking for `/bin/bash` and
`/sbin/init`. The alternative is bind-mounting the host's `/dev` over whatever
directory was actually a typo, and a typo does not have a Sowa system in it. A
destination that is not a mount point is allowed, with a warning: a tree
bootstrapped into a plain directory is one of the things `sowa-bootstrap` is
for.

## Installing with the portable bundle

The three programs above live at `/usr/lib/sowa/install-functions` and
`/usr/sbin/sowa-*` inside the image. To use them from a hosting rescue
environment or another non-Sowa host, `make installer-bundle` packs all four
into one file:

```sh
make installer-bundle          # -> artifacts/sowa-install
```

Copy that and a rootfs tarball to the machine, and the whole install is three
commands — but first authenticate both downloads against the signed release
manifest using a public-key fingerprint obtained independently:

```sh
./verify-release.sh --key sowa-release.pub \
    sowa-0.1-x86_64-release.manifest \
    sowa-install sowa-0.1-x86_64-rootfs.tar.xz
./sowa-install bootstrap --from-tarball sowa-0.1-x86_64-rootfs.tar.xz /mnt
./sowa-install chroot /mnt grub-install --target=i386-pc /dev/sda
./sowa-install chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
```

`scripts/verify-release.sh` comes from a trusted source checkout and can verify
only the downloaded subset even when the manifest names other release forms.
The detached Ed25519 signature is checked before any filename in the manifest
is parsed. See [Release authenticity](releases.md) for the raw OpenSSL command,
key custody and the distinction between signed downloads and Secure Boot.

`grub-mkconfig` comes after `grub-install` because `grub-install` is what
creates the `/boot/grub` its output goes in.

Both `grub` commands run through `sowa-install chroot` rather than directly,
which is not a stylistic preference: they are then Sowa's own GRUB 2.14 rather
than whatever the host has, and a rescue environment shipping GRUB 0.97 cannot
write a boot loader for this system at all.

The bundle needs `bash`, `tar`, `xz` and root, and nothing else. It carries the four
files verbatim in plain here-documents — readable with `less`, and checked at
generation time to be byte-identical to what the image ships — unpacks them
into a temporary directory, runs the one asked for, and deletes them again.
What makes that possible is that the three programs find their library through
`${SOWA_INSTALL_LIB}` rather than at a fixed path, so there is one copy of each
program in the tree and no generated duplicate to keep in step.

`bootstrap` without `--from-tarball` copies the *running* system, which is only
correct when that system is Sowa. On a non-Sowa host it refuses and directs the
user to `--from-tarball`. `setup` is whole-disk and likewise only works from a
booted Sowa.

### The host kernel has to be 6.1 or newer

Every binary in the image was built against glibc configured
`--enable-kernel=6.1.0`, so all three programs check the kernel they are running
on and stop if it is older. This is the kernel you install *from* — the
installed system boots its own and is unaffected.

The check exists because the failure it prevents is not clean. On an older
kernel the binaries may start, but `statx(2)` returns `ENOSYS`; coreutils then
prints `Function not implemented`, and programs consuming file listings may
quietly receive incomplete data. Use a rescue environment with a newer kernel
or boot the Sowa ISO. `SOWA_INSTALL_IGNORE_KERNEL=1` overrides the check and is
not recommended.

## The container image

```sh
make docker-image      # -> artifacts/sowa-0.1-x86_64-docker.tar
make docker-run        # load that archive and open a shell in it
```

`make docker-run` is the two commands below with the bookkeeping done for you.
It reads the image id and the tag out of the archive rather than assuming them,
loads it only when the runtime does not already hold that exact id — which the
reproducible build makes a meaningful question — and runs it. `ARGS=` passes a
command instead of a shell (`make docker-run ARGS="uname -a"`), a terminal is
only requested when there is one, so a piped or logged run behaves, and `podman`
is used when `docker` is absent (`SOWA_CONTAINER_RUNTIME=` picks either).

```sh
docker load -i artifacts/sowa-0.1-x86_64-docker.tar
docker run --rm -it sowa:0.1
```

The archive is the format `docker save` writes, so `podman load` and `skopeo`
read it too. It is assembled with `tar` and `sha256sum` rather than by a
container runtime — building it needs no daemon, no builder and no container
tooling installed at all — and everything in it is derived from the tree and
from `SOURCE_DATE_EPOCH`, so the same rootfs produces a byte-identical archive
with the same image ID every time. A `docker build` could not say that: it
stamps a fresh creation time and layer ID on every run.

What is in it is the whole system minus the kernel. `/boot` is dropped because a
container never boots one; everything else stays, including the compiler, the
manual pages, `sowa-pkg`, GRUB and the three installers. Keeping those last two
is what makes the image a way to install Sowa onto a real disk from any machine
that can run a container:

```sh
make docker-run ARGS=--install
sowa-bootstrap --from-tarball /artifacts/sowa-0.1-x86_64-rootfs.tar.xz /mnt
```

`--install` is the reason that flag exists: it adds `--privileged -v /dev:/dev`
so the container can write a real disk, and mounts `artifacts/` read-only at
`/artifacts` so the rootfs tarball is there to install from. By hand it is:

```sh
docker run --rm -it --privileged -v /dev:/dev -v "$PWD":/art sowa:0.1
sowa-bootstrap --from-tarball /art/sowa-0.1-x86_64-rootfs.tar.xz /mnt
```

The kernel the installed system boots comes from that tarball, not from the
image, which is why dropping `/boot` costs nothing. `sowa-bootstrap` *without*
`--from-tarball` copies the running system, and inside the container the running
system has no kernel — it warns and continues, since a chroot tree does not need
one, but a copy meant to boot does.

Two things follow from a container sharing the host's kernel rather than
bringing its own. The image needs the host to be running Linux 6.1 or newer for
the same reason the installer does, and on an older one `ls -l` fails with
`Function not implemented`. And a container runtime that blocks `statx(2)` in
its seccomp profile — Docker with a libseccomp too old to know the syscall does
exactly this — produces that same failure on a new kernel.

### Publishing it

```sh
docker login ghcr.io                                        # or skopeo login
make docker-push SOWA_IMAGE_DESTINATION=ghcr.io/you/sowa:0.1
```

There is no default destination, no default registry and no default account:
publishing to the wrong repository cannot be undone, so the destination has to
be written out in full. A name with no registry host in it is refused rather
than resolved to Docker Hub, a destination with no tag is refused rather than
assumed to be `latest`, and the archive digest and destination are printed and
confirmed before anything is sent.

Credentials are the registry client's business. The script never reads, stores
or prompts for a password, so there is no path by which one reaches a shell
history or a build log — log in first with `docker login` or `skopeo login`.

`skopeo` is used when it is installed, because it copies the archive straight to
the registry the same way it was built: no daemon, and nothing loaded into a
local image store on the way past. `docker` is the fallback and needs the extra
`load` and `tag` steps to get there.

## The shared library

All three programs source `${SOWA_INSTALL_LIB:-/usr/lib/sowa}/install-functions`,
which holds the copy itself (`copy_system`), the tarball extraction
(`extract_rootfs_tarball`), the size measurements, the host-kernel check
(`require_supported_host_kernel`), the host-key reset and the mount-point
creation. The copy is the part that cannot be validated by reading, so there is
exactly one of it to prove — and proving it once covers all three programs.

The path is a variable rather than a constant for one reason: it is what lets
`make installer-bundle` put all four files in one relocatable script without
generating a second copy of any of them. Nothing sets `SOWA_INSTALL_LIB` inside
the image, where `/usr/lib/sowa` is where the library actually is.

## Testing in QEMU

```sh
make run-install     # boot the ISO with a blank disk; run sowa-setup
make run-disk        # boot the installed disk on legacy BIOS (SeaBIOS)
make run-disk-uefi   # boot the installed disk on UEFI firmware (OVMF)
```

`make run-install` attaches `artifacts/<name>-<version>-<arch>-disk.img` (created
at 4 GiB if absent; override with `SOWA_DISK_SIZE`). `make run-disk-uefi`
requires the host `edk2-ovmf` firmware. Exit QEMU with `Ctrl-a x`.

## Host requirements for the ISO's installer

Nothing extra: `sowa-setup` and every tool it needs are built into the image by
the normal `make rootfs`/`make image`/`make iso` pipeline. The e2fsprogs,
dosfstools, and GRUB stages use only the existing cross toolchain.

## Known limitations

- MBR layout only - `sowa-setup` writes no other, though util-linux's `sfdisk`
  is perfectly able to. UEFI boot uses the removable `EFI/BOOT/BOOTX64.EFI`
  path, which QEMU/OVMF and most firmware accept from an MBR ESP. A GPT layout
  is now an installer change rather than a missing tool.
- Single root partition, no separate `/home` or swap. The base system mounts
  `proc`/`sys`/`dev` from `/etc/rc.d/rc.sysinit` rather than from `/etc/fstab`,
  but rc.sysinit does run `mount -a`, so an entry added to the generated fstab
  is mounted at boot - and `swapon -a` after it, so a `swap` line added there is
  enabled too. An installed system is not without swap in the meantime: the zram
  service gives it compressed swap in memory from the first boot, and a disk
  swap partition added later takes the lower priority and only the overflow.
- `sowa-bootstrap` does not write `/etc/fstab` — it prints the line to add. The
  installed system boots without one, because `root=` and `rw` come from the
  kernel command line and the virtual filesystems come from rc.sysinit, but
  nothing else in the layout is mounted until the file names it.
- Installing from a host older than Linux 6.1 is refused rather than supported.
  See "The host kernel has to be 6.1 or newer" above.
