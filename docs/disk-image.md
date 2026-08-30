# The prebuilt disk image

`make disk-image` writes the assembled root filesystem out as a partitioned,
bootable disk. It is the artifact for people who do not want to install
anything: write it to a drive with `dd`, attach it to a virtual machine, or hand
it to a hypervisor that takes disk images, and the result boots into the same
system `sowa-setup` would have produced.

Four files land in `artifacts/`, and the last two are the ones to publish:

```text
sowa-0.1-x86_64.img            the raw disk, sparse
sowa-0.1-x86_64.img.xz         the same disk, compressed
sowa-0.1-x86_64.qcow2          the same disk as QEMU's own format
sowa-0.1-x86_64.qcow2.xz       the same again, compressed
```

Both compressed files are accompanied by a `.sha256`. The uncompressed pair is
kept rather than deleted because `make run-disk-image` boots it and because a
hypervisor pointed at a file should not have to be given a `.xz`.

## What is on it

An MBR label, because it is what boots everywhere without a firmware setting:

```text
sector 0            master boot record, GRUB's boot.img
sectors 1-2047      GRUB's core.img, in the gap before the first partition
partition 1  type ef  FAT32, 64 MiB   the EFI System Partition
partition 2  type 83  ext4            the root filesystem, and the rest of the disk
```

The layout, the filesystems and the boot loader are `sowa-setup`'s (see
[docs/install.md](install.md)), which is the point: an installed machine and a
machine that was handed this image are the same machine afterwards. GRUB is
installed for both firmwares — BIOS from the MBR and the gap behind it, UEFI as
`EFI/BOOT/BOOTX64.EFI` on the ESP, which is the removable-media path every
firmware boots without being told to. There is no NVRAM entry to make and
nothing registered on the machine it is written to.

The kernel is booted directly from `/boot/vmlinuz` with `root=PARTUUID=...` and
no initramfs, so the disk it lands on can be `/dev/sda`, `/dev/vda` or
`/dev/nvme0n1` without anything in the image caring. Every driver needed to
find it — virtio, AHCI, the PIIX IDE emulation, NVMe, USB storage — is compiled
into the kernel rather than loaded from a module, which is what makes booting
without an initramfs possible in the first place.

The menu has two entries: the system, and the system with `single` for a root
shell. Both name `console=tty0` and `console=ttyS0,115200`, and `/etc/inittab`
runs a getty per console, so there is a login prompt on the screen and on the
serial line at the same time.

## Writing it to a disk

```sh
xz -dc sowa-0.1-x86_64.img.xz | dd of=/dev/sdX bs=4M oflag=direct status=progress
sync
```

`/dev/sdX` is the disk, not a partition. Everything on it is overwritten,
partition table included.

## Running it in a virtual machine

```sh
make run-disk-image        # QEMU, legacy BIOS
make run-disk-image-uefi   # QEMU, UEFI firmware (OVMF)
```

Both boot the raw image with `snapshot=on`, so QEMU writes to a temporary file
it throws away and the artifact stays the artifact. By hand, or for a machine
that is meant to keep its changes:

```sh
qemu-system-x86_64 -m 2048 -drive file=sowa-0.1-x86_64.qcow2,if=virtio -nographic
```

VirtualBox reads neither raw images nor qcow2 as disks, so convert once:

```sh
VBoxManage convertfromraw sowa-0.1-x86_64.img sowa.vdi --format VDI
```

## It grows into the disk at the first boot

The image is only as large as it has to be — the tree plus room to work,
rounded up to a whole GiB — because it is a file people download. A disk it is
written to is almost always larger than that, and the extra space is not root's
until something claims it.

`/etc/init.d/growroot` claims it. This image is the only one that ships that
service enabled, and it is the first service of the runlevel: it extends
partition 2 to the end of the disk, tells the running kernel the partition
changed, and grows the ext4 inside it. On a disk that is already full it does
nothing and says so, which is also what happens on the second boot — and on the
boot after a virtual disk was enlarged, it grows again.

It refuses rather than guesses. Root has to be an ext2/3/4 filesystem, mounted
read-write, on a partition that is the last one on its disk; anything else is
reported and left alone. [docs/resize.md](resize.md) is the same procedure by
hand, and is what to reach for when the answer is "left alone".

## What can be decided at build time

Nothing has to be, and by default nothing is: the image boots with the shipped
`/etc/nic.conf` (DHCP on `eth0`), sshd on, and a root account that has no
password and can therefore be logged into on the console and not over the
network — `PermitRootLogin prohibit-password` and `PermitEmptyPasswords no` see
to the second half of that.

For an image that is going somewhere with no console attached, three things can
be set on the `make disk-image` command line, because they are the three that
cannot be arranged afterwards without booting it somewhere first:

```sh
make disk-image \
    SOWA_IMAGE_HOSTNAME=sowa \
    SOWA_IMAGE_SSH_KEY_FILE=~/.ssh/id_ed25519.pub \
    SOWA_IMAGE_ROOT_PASSWORD=hunter2
```

| variable | what it does |
| --- | --- |
| `SOWA_IMAGE_HOSTNAME` | writes `/etc/hostname` |
| `SOWA_IMAGE_SSH_KEY` | one public key, written to `/root/.ssh/authorized_keys` |
| `SOWA_IMAGE_SSH_KEY_FILE` | the same, read from a file |
| `SOWA_IMAGE_ROOT_PASSWORD` | sets root's password (console and serial only; sshd still refuses passwords for root) |
| `SOWA_IMAGE_SIZE_MB` | the size of the whole disk, in MiB, instead of the computed one |
| `SOWA_IMAGE_ESP_SIZE_MB` | the size of the EFI System Partition (default 64, minimum 34) |
| `SOWA_IMAGE_SEED` | what the disk signature and filesystem UUID are derived from |

A password given here is hashed on the build host with `openssl passwd -6` and
appears in that shell's history and in the built image; it is a convenience for
an image nobody else will boot, not a way to ship one.

## Identifiers, and why they are not random

The MBR disk signature and the root filesystem's UUID are derived from what is
being built — the distribution, the version, the architecture, the kernel
version and `SOURCE_DATE_EPOCH` — rather than drawn from `/dev/urandom`, so that
building the same tree twice produces the same image. Linux derives `PARTUUID`
from the disk signature, and that is what `/etc/fstab` and the kernel command
line name.

The cost is that two of these images attached to one machine claim the same
`PARTUUID`, and that machine has no way to tell which root was meant.
`SOWA_IMAGE_SEED=anything-else` is how the second one is told to be somebody
else.

## How it is built without root

The build runs as an ordinary user — `make check` refuses to run as root — so
there is no mount, no loop device and no `losetup` anywhere in this stage:

- the ext4 root is created by `mke2fs -d`, which copies a directory into a
  filesystem image without mounting it;
- the ownership that copy would otherwise take from the build user comes from
  `fakeroot`, which answers `stat(2)` with what a `chown -R 0:0` would have done
  had it been root. The assembled tree is all-root by design — the squashfs is
  built with `-all-root` and the tarballs with `--owner=0` — so this is the
  ownership every other artifact ships, not a decision the disk image makes;
- the ESP is `mkfs.fat` on a file, filled with `mmd` and `mcopy`;
- the partition table is `sfdisk` on a file;
- GRUB's BIOS boot chain is assembled by copying two ranges of bytes out of
  `boot.img` and `grub-mkimage`'s `core.img`. `grub-bios-setup` would do the
  same thing, and cannot be used: it insists on identifying the block device the
  files it is given live on, which is a privileged read of the build host's own
  disk.

The two GRUB images are self-contained — every module either needs is compiled
into it — which is why there is no `/boot/grub/i386-pc` directory in the image
to keep in step with them. The host's `grub-mkimage` builds them, everything
else in the tree is cross-compiled, and a GRUB only ever loads modules from its
own build.

The tree `mke2fs` copies is a hard-linked copy of `work/rootfs` with this
image's `/etc/fstab`, boot menu and runlevel link added, so the artifact every
other stage is cut from is left exactly as it was.

## What it is not

There is no cloud-init in it, no metadata service is contacted, and nothing is
reconfigured per boot. An image that is booted somewhere that expects to inject
a key through a metadata service will boot fine and will not have the key. The
one thing this image does that a plain install does not is grow into its disk.
