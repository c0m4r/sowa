#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# The prebuilt disk image: the assembled root filesystem laid down as a
# partitioned, bootable disk that can be written to a drive with dd, attached to
# a virtual machine, or handed to a hosting provider that takes disk images.
#
# It is the same result "make run-install" produces by booting the ISO and
# running sowa-setup onto a blank disk, made without booting anything: the same
# MBR label, the same FAT EFI System Partition and ext4 root, the same GRUB on
# both firmwares, and the same kernel command line. sowa-setup remains the way
# to install onto a machine's own disk, with its own partition sizes and its own
# password; this is the way to get a running system without an install at all.
#
# Two artifacts, and both of them compressed: the raw .img, which is what dd and
# most hypervisors want, and the .qcow2 that QEMU and libvirt prefer, each also
# published as a .xz. The uncompressed pair is kept because "make
# run-disk-image" boots it and because writing to a disk should not have to
# decompress 2 GiB first if the file is already there.
#
# Everything here runs unprivileged, which is the constraint that decides how it
# is built. There is no mount, no loop device and no root:
#
#   - the ext4 root is created by "mke2fs -d", which copies a directory into a
#     filesystem image without mounting it;
#   - the ownership that copy would otherwise take from the build user comes
#     from fakeroot, which answers stat(2) with what a "chown -R 0:0" would have
#     done had it been root. The tree is all-root by design - the squashfs is
#     built with -all-root and the tarballs with --owner=0 - so this is the same
#     ownership every other artifact ships, not a decision made here;
#   - the ESP is created by mkfs.fat on a file and filled by mtools;
#   - the partition table is written by sfdisk on a file;
#   - GRUB's BIOS boot chain is assembled from grub-mkimage's output by copying
#     two ranges of bytes, which is what grub-bios-setup would have done. It
#     cannot be used here: it insists on identifying the block device the files
#     it is given live on, and that is a privileged read of the build host's own
#     disk.
#
# What it is deliberately not: an image with a cloud-init in it. There is no
# metadata service to ask, no key to fetch and no per-boot reconfiguration. The
# one thing it does do on first boot is grow into the disk it was written to -
# see /etc/init.d/growroot, which this image is the only one to ship enabled.

require_command fakeroot
require_command mke2fs
require_command mkfs.fat
require_command mmd
require_command mcopy
require_command sfdisk
require_command grub-mkimage
require_command qemu-img
require_command xz
require_command du
require_command od

[[ -d "${ROOTFS_DIR}" ]] || die "root filesystem is missing; run 'make image' first"
[[ -f "${ROOTFS_DIR}/boot/vmlinuz" ]] \
    || die "the kernel is missing from the root filesystem; run 'make image' first"
[[ -x "${ROOTFS_DIR}/sbin/init" ]] || die "sowa-init is missing; run 'make rootfs'"
[[ -x "${ROOTFS_DIR}/etc/rc.d/init.d/growroot" ]] \
    || die "the growroot service is missing from the root filesystem; run 'make rootfs'"

grub_libdir="$(host_grub_libdir)"
[[ -d "${grub_libdir}/x86_64-efi" ]] \
    || die "GRUB x86_64-efi platform files not found in ${grub_libdir}; a disk image that only boots on BIOS is not worth shipping"

# ---------------------------------------------------------------------------
# Identifiers
#
# The MBR disk signature is what the root partition is named by: Linux derives
# PARTUUID from it, as SSSSSSSS-NN, and that is what /etc/fstab and the kernel
# command line use - not a device name, which depends on where the disk ends up
# (/dev/vda on a virtio machine, /dev/sda on SATA, /dev/nvme0n1 on NVMe), and
# not a filesystem UUID, which the kernel cannot resolve without an initramfs
# and this image has none.
#
# Both it and the filesystem UUID are derived from what is being built rather
# than drawn from /dev/urandom, so that building the same tree twice produces
# the same image. The cost is that two of these images attached to one machine
# claim the same PARTUUID; SOWA_IMAGE_SEED is how the second one is told to be
# somebody else.
kernel_version="$(source_version linux)"
seed="$(printf '%s' \
    "${SOWA_IMAGE_SEED:-${DISTRO_NAME}|${DISTRO_VERSION}|${ARTIFACT_ARCH}|${kernel_version}|${SOURCE_DATE_EPOCH}}" \
    | sha256sum | cut -c1-32)"
disk_signature="${seed:0:8}"
[[ "${disk_signature}" != 00000000 ]] || die "the derived disk signature is zero; set SOWA_IMAGE_SEED"
esp_partuuid="${disk_signature}-01"
root_partuuid="${disk_signature}-02"
# A UUID in the shape a version 4 one has, so that nothing reading it has to
# wonder: the variant and version nibbles are fixed and the rest is the seed.
root_uuid="${seed:0:8}-${seed:8:4}-4${seed:12:3}-8${seed:15:3}-${seed:18:12}"

# ---------------------------------------------------------------------------
# Geometry
#
# The image is as small as the tree it carries plus room to work in, rounded up
# to a whole GiB, because it is a file people download and write to a disk. It
# does not have to be the size of the disk it ends up on: growroot extends the
# root partition and the filesystem into whatever is left at the first boot.
esp_mib="${SOWA_IMAGE_ESP_SIZE_MB:-64}"
[[ "${esp_mib}" =~ ^[0-9]+$ ]] || die "SOWA_IMAGE_ESP_SIZE_MB must be a whole number of MiB"
# mkfs.fat -F32 needs 65525 clusters, which no smaller ESP can provide.
((esp_mib >= 34)) || die "SOWA_IMAGE_ESP_SIZE_MB must be at least 34"

# Two answers to "how big is the tree", and the larger of them is used. du
# reports what the tree occupies on the build host's filesystem, which is what
# ext4 will need for the same files - except on a host that compresses or
# deduplicates them, where it reports less than the bytes exist; --apparent-size
# reports the bytes and ignores the block rounding that 25000 small files pay.
# Neither is an upper bound on its own.
tree_mib="$(du -sm "${ROOTFS_DIR}" | cut -f1)"
tree_apparent_mib="$(du -sm --apparent-size "${ROOTFS_DIR}" | cut -f1)"
((tree_apparent_mib <= tree_mib)) || tree_mib="${tree_apparent_mib}"
# The tree, plus a quarter of it for ext4's own metadata - the journal, the
# inode tables, the 5% reserved blocks - plus 128 MiB of somewhere to work
# before the filesystem is grown.
root_minimum_mib=$((tree_mib + tree_mib / 4 + 128))
minimum_mib=$((1 + esp_mib + root_minimum_mib))
default_mib=$(((minimum_mib + 1023) / 1024 * 1024))
total_mib="${SOWA_IMAGE_SIZE_MB:-${default_mib}}"
[[ "${total_mib}" =~ ^[0-9]+$ ]] || die "SOWA_IMAGE_SIZE_MB must be a whole number of MiB"
((total_mib >= minimum_mib)) \
    || die "SOWA_IMAGE_SIZE_MB=${total_mib} is too small for a ${tree_mib} MiB system and a ${esp_mib} MiB ESP; it needs at least ${minimum_mib}"

# Sectors, because that is what a partition table is written in. The first
# partition starts at 1 MiB, which is both the alignment every disk since
# 4K-native wants and the gap GRUB's BIOS core image is embedded in.
esp_start=2048
esp_sectors=$((esp_mib * 2048))
root_start=$((esp_start + esp_sectors))
root_sectors=$((total_mib * 2048 - root_start))
root_mib=$((root_sectors / 2048))

log "disk image: ${total_mib} MiB total, ${esp_mib} MiB ESP, ${root_mib} MiB ext4 root for a ${tree_mib} MiB system"

staging="${BUILD_DIR}/disk-image"
reset_build_dir "${staging}"

# ---------------------------------------------------------------------------
# The tree that goes into the filesystem
#
# A hard-linked copy of the assembled root filesystem, which costs directory
# entries and no data blocks, plus the handful of files that describe this
# particular disk. It is a copy because every other artifact is cut from
# ROOTFS_DIR and none of them wants an /etc/fstab that names this image's
# partitions - and it is hard-linked rather than duplicated because 980 MiB of
# copying to add six files would be absurd.
#
# The consequence of the links is that a file must never be edited in place
# here: writing through a link writes into the assembled tree. stage_file
# removes first and writes second, which breaks the link instead of following
# it, and is the only way anything in this stage puts a file into the tree.
tree="${staging}/root"
log "linking the root filesystem into ${tree}"
cp -al "${ROOTFS_DIR}" "${tree}"

stage_file() {
    local path="${tree}$1"
    local mode="$2"
    mkdir -p "$(dirname "${path}")"
    rm -f "${path}"
    cat > "${path}"
    chmod "${mode}" "${path}"
}

# What is mounted at boot. Root is named by PARTUUID for the reasons given where
# the disk signature is derived; the ESP is listed so that "mount /boot/efi"
# works without arguments, and noauto because nothing on it is read after the
# firmware has read it.
log "writing /etc/fstab"
stage_file /etc/fstab 0644 <<EOF
# <file system>            <mount point>  <type>  <options>          <dump> <pass>
PARTUUID=${root_partuuid}  /              ext4    defaults            0      1
PARTUUID=${esp_partuuid}   /boot/efi      vfat    defaults,noauto     0      2
EOF
mkdir -p "${tree}/boot/efi"

# The one service this image turns on. See /etc/init.d/growroot: the image is
# smaller than the disk it will be written to, and this is what makes it stop
# being smaller. S01 puts it ahead of every other service, so that whatever they
# write is written into the grown filesystem.
log "enabling the growroot service"
ln -sfn ../init.d/growroot "${tree}/etc/rc.d/rc3.d/S01growroot"
for level in 2 4 5; do
    ln -sfn ../init.d/growroot "${tree}/etc/rc.d/rc${level}.d/S01growroot"
done

# Optional, and off unless the environment asks: an image that is going to be
# written to a machine with no screen and no serial console is an image nobody
# can log into, since sshd is "PermitRootLogin prohibit-password" and root has
# no key. These are the three things that cannot be arranged after the fact
# without booting it somewhere first.
if [[ -n "${SOWA_IMAGE_HOSTNAME:-}" ]]; then
    log "setting the hostname to ${SOWA_IMAGE_HOSTNAME}"
    printf '%s\n' "${SOWA_IMAGE_HOSTNAME}" | stage_file /etc/hostname 0644
fi
if [[ -n "${SOWA_IMAGE_ROOT_PASSWORD:-}" ]]; then
    require_command openssl
    log "setting the root password"
    # yescrypt is what libxcrypt prefers and what shadow's own tools would
    # write, but OpenSSL cannot produce one; -6 is SHA-512 crypt, which
    # libxcrypt reads everywhere. The salt is random, so an image built with a
    # password is not bit-identical to the next one built with the same one.
    hash="$(openssl passwd -6 "${SOWA_IMAGE_ROOT_PASSWORD}")"
    [[ -n "${hash}" ]] || die "openssl produced no password hash"
    # Read the file, then write it: awk and stage_file would otherwise run at the
    # same time, and stage_file's first act is to unlink what awk is reading.
    shadow="$(awk -v hash="${hash}" 'BEGIN { FS = OFS = ":" }
        $1 == "root" { $2 = hash } { print }' "${tree}/etc/shadow")"
    printf '%s\n' "${shadow}" \
        | stage_file /etc/shadow "$(stat -c %a "${tree}/etc/shadow")"
fi
ssh_key="${SOWA_IMAGE_SSH_KEY:-}"
if [[ -n "${SOWA_IMAGE_SSH_KEY_FILE:-}" ]]; then
    [[ -f "${SOWA_IMAGE_SSH_KEY_FILE}" ]] \
        || die "SOWA_IMAGE_SSH_KEY_FILE names no file: ${SOWA_IMAGE_SSH_KEY_FILE}"
    ssh_key="$(cat "${SOWA_IMAGE_SSH_KEY_FILE}")"
fi
if [[ -n "${ssh_key}" ]]; then
    log "authorising an SSH key for root"
    printf '%s\n' "${ssh_key}" | stage_file /root/.ssh/authorized_keys 0600
    chmod 0700 "${tree}/root/.ssh"
fi

# ---------------------------------------------------------------------------
# GRUB
#
# Two self-contained boot images, one per firmware, each with every module it
# needs compiled into it. That is why there is no /boot/grub/i386-pc directory
# in this image and nothing to keep in step with it: the modules a GRUB loads
# have to be the same build as its core, and the core here is built by the
# host's grub-mkimage while everything else in the tree is cross-compiled. What
# GRUB reads from the filesystem at boot is its menu, and nothing else.
#
# The embedded configuration is what finds the menu. It looks for the root
# filesystem by UUID rather than trusting a device name, since (hd0,msdos2) is
# only right when the firmware happens to enumerate this disk first - and it
# names that device anyway, first, because "search --set" leaves the variable
# alone when it finds nothing and a guess is better than no root at all.
#
# It is three plain commands because that is all it can be: this runs before the
# normal module is loaded, in a parser that has no "if" and answers one with
# "Unknown command `if'" on the console of every boot.
grub_modules=(part_msdos ext2 search search_fs_uuid configfile normal linux
    echo test serial terminal all_video)
early_config="${staging}/early.cfg"
cat > "${early_config}" <<EOF
set root=hd0,msdos2
search --no-floppy --fs-uuid --set=root ${root_uuid}
set prefix=(\$root)/boot/grub
EOF

log "building the GRUB core image for BIOS"
grub-mkimage --format=i386-pc --directory="${grub_libdir}/i386-pc" \
    --config="${early_config}" --prefix=/boot/grub \
    --output="${staging}/core.img" biosdisk "${grub_modules[@]}"
log "building the GRUB boot image for UEFI"
grub-mkimage --format=x86_64-efi --directory="${grub_libdir}/x86_64-efi" \
    --config="${early_config}" --prefix=/boot/grub \
    --output="${staging}/bootx64.efi" "${grub_modules[@]}"

# The menu. It is sowa-setup's, with a second entry: an image somebody else
# wrote to a disk is more likely to need a root shell than a machine whose owner
# was sitting at the installer.
#
# The serial probe is guarded because naming a terminal GRUB never registered is
# an error, and GRUB's ns8250 driver only registers a port that reads back
# something other than 0xff - which a machine with no UART does not. The video
# lines are the ISO's: gfxpayload=keep is what makes Linux inherit the mode GRUB
# set instead of leaving the firmware's, which on UEFI is the difference between
# a framebuffer console and a blank screen.
log "writing the boot menu"
cmdline="root=PARTUUID=${root_partuuid} rw console=tty0 console=ttyS0,115200 panic=-1"
stage_file /boot/grub/grub.cfg 0644 <<EOF
set default=0
set timeout=5

insmod all_video
set gfxmode=${ISO_GFXMODE}
set gfxpayload=keep

if serial --unit=0 --speed=115200; then
    terminal_input serial console
    terminal_output serial console
fi

menuentry "${DISTRO_NAME^} Linux ${DISTRO_VERSION}" --id sowa {
    linux /boot/vmlinuz ${cmdline} init=/sbin/init
}

# A root shell instead of the default runlevel, for a machine that cannot be
# reinstalled from a medium because nobody is standing next to it.
menuentry "${DISTRO_NAME^} Linux ${DISTRO_VERSION} (single user)" --id sowa-single {
    linux /boot/vmlinuz ${cmdline} single
}
EOF

# ---------------------------------------------------------------------------
# The ext4 root
#
# mke2fs -d takes the ownership of every file from the tree it is copying, and
# the tree belongs to whoever ran the build, so the whole of it runs under
# fakeroot: the chown records root:root for every path in fakeroot's database
# and mke2fs reads it back from there. Nothing on the disk is changed by it -
# the build stays unprivileged - and the result is the same all-root tree the
# squashfs and the tarballs ship.
#
# orphan_file and metadata_csum_seed are off for the reason sowa-setup turns
# them off: e2fsprogs 1.47 enables both by default and GRUB 2.12's ext2 driver
# can read neither, so a root filesystem with them on is one GRUB drops to a
# rescue prompt in front of.
root_image="${staging}/root.ext4"
log "creating the ext4 root filesystem (${root_mib} MiB)"
truncate -s $((root_sectors * 512)) "${root_image}"
fakeroot -- bash -s -- "${tree}" "${root_image}" "${root_uuid}" \
    "${DISTRO_NAME}-root" <<'INNER'
set -Eeuo pipefail
tree="$1"
image="$2"
uuid="$3"
label="$4"
chown -R 0:0 "${tree}"
# hash_seed is set from the same UUID for the same reason the UUID is set at
# all: mke2fs would otherwise invent one, and an image that differs from build
# to build in bytes nothing reads is an image nobody can check.
mke2fs -q -F -t ext4 \
    -O '^orphan_file,^metadata_csum_seed' \
    -L "${label}" -U "${uuid}" \
    -E "root_owner=0:0,hash_seed=${uuid}" \
    -d "${tree}" "${image}"
INNER

# ---------------------------------------------------------------------------
# The EFI System Partition
#
# EFI/BOOT/BOOTX64.EFI is the removable-media path, which is the one every
# firmware boots without being told to: no NVRAM entry, nothing to register, and
# it survives being written to a different machine. That is what sowa-setup's
# "grub-install --removable" writes as well.
esp_image="${staging}/esp.fat"
log "creating the EFI System Partition (${esp_mib} MiB)"
truncate -s $((esp_sectors * 512)) "${esp_image}"
# --invariant keeps mkfs.fat from stamping the volume with the time of day and a
# serial number drawn from it. mtools is told the same thing the only way it
# takes it: by the timestamp on the file being copied in.
mkfs.fat -F32 -n "${DISTRO_NAME^^}_ESP" --invariant "${esp_image}" > /dev/null
touch -d "@${SOURCE_DATE_EPOCH}" "${staging}/bootx64.efi"
MTOOLS_SKIP_CHECK=1 mmd -i "${esp_image}" ::/EFI ::/EFI/BOOT
MTOOLS_SKIP_CHECK=1 mcopy -i "${esp_image}" "${staging}/bootx64.efi" ::/EFI/BOOT/BOOTX64.EFI

# ---------------------------------------------------------------------------
# The disk
image="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.img"
temporary="${staging}/disk.img"
log "assembling ${image}"
truncate -s "${total_mib}"M "${temporary}"
# type ef is the EFI System Partition and type 83 is Linux; the boot flag on
# root is what a BIOS that refuses a disk with no active partition looks for.
# label-id sets the disk signature the PARTUUIDs above were derived from.
sfdisk --no-tell-kernel --quiet "${temporary}" <<EOF
label: dos
label-id: 0x${disk_signature}
unit: sectors

start=${esp_start}, size=${esp_sectors}, type=ef
start=${root_start}, size=${root_sectors}, type=83, bootable
EOF
# conv=sparse keeps the holes in both filesystem images from being written out
# as zeros, which is what keeps the artifact a sparse file; conv=notrunc keeps
# dd from throwing away everything after what it wrote, the partition table
# included.
dd if="${esp_image}" of="${temporary}" bs=512 seek="${esp_start}" \
    conv=notrunc,sparse status=none
dd if="${root_image}" of="${temporary}" bs=512 seek="${root_start}" \
    conv=notrunc,sparse status=none

# ---------------------------------------------------------------------------
# GRUB's BIOS boot chain, which is three files and two rules.
#
# boot.img is the 512-byte master boot record. Its job is to read the sector
# whose number is stored in it and jump into it; grub-mkimage's core.img is what
# lives there, and the "embedding area" it goes in is the gap between the master
# boot record and the first partition - 2047 sectors at a 1 MiB alignment.
#
# Neither file needs patching, which is worth saying because grub-bios-setup
# patches both and this does not. boot.img is shipped with the kernel sector
# already set to 1 (boot.S: "kernel_sector: .long 1") and the boot drive already
# 0xff, which means "the drive the BIOS booted from"; core.img is shipped by
# grub-mkimage with the block list in its first sector already describing itself
# at sector 2 for its own length. Sector 1 is where core.img is written, so
# every one of those values is already the truth. They are checked rather than
# trusted: a GRUB whose layout differs from this is a GRUB this cannot install,
# and an unbootable image is not a thing to find out about later.
boot_img="${grub_libdir}/i386-pc/boot.img"
core_img="${staging}/core.img"
[[ -f "${boot_img}" ]] || die "GRUB's boot.img is missing from ${grub_libdir}/i386-pc"
[[ "$(stat -c %s "${boot_img}")" == 512 ]] || die "GRUB's boot.img is not 512 bytes"

bytes_at() {
    od --address-radix=n --format=x1 --skip-bytes="$2" --read-bytes="$3" "$1" \
        | tr -d ' \n'
}

core_bytes="$(stat -c %s "${core_img}")"
core_sectors=$(((core_bytes + 511) / 512))
((core_sectors + 1 <= esp_start)) \
    || die "the GRUB core image needs ${core_sectors} sectors and only $((esp_start - 1)) fit before the first partition"
# 0x5c is boot.S's kernel_sector, a little-endian 64-bit sector number; 0x64 is
# its boot_drive.
[[ "$(bytes_at "${boot_img}" 92 8)" == 0100000000000000 ]] \
    || die "GRUB's boot.img does not read its next sector from sector 1"
[[ "$(bytes_at "${boot_img}" 100 1)" == ff ]] \
    || die "GRUB's boot.img does not boot from the BIOS boot drive"
# The block list is the last 12 bytes of core.img's first sector: an 8-byte
# start sector, a 2-byte length in sectors, and the segment to load it at.
[[ "$(bytes_at "${core_img}" 500 8)" == 0200000000000000 ]] \
    || die "the GRUB core image does not continue at sector 2"
expected_length="$(printf '%02x%02x' $(((core_sectors - 1) & 255)) $(((core_sectors - 1) >> 8)))"
[[ "$(bytes_at "${core_img}" 508 2)" == "${expected_length}" ]] \
    || die "the GRUB core image's block list does not describe its own length"

log "installing GRUB for BIOS into the master boot record and the ${esp_start} sector gap"
dd if="${core_img}" of="${temporary}" bs=512 seek=1 conv=notrunc status=none
# Two ranges of boot.img, and the gap between them is the point. Bytes 0x00-0x02
# are the jump, bytes 0x5a-0x1b7 are the code; 0x03-0x59 is the BIOS parameter
# block, which a disk that is not itself FAT-formatted leaves as it found it,
# and 0x1b8 onwards is the disk signature and the partition table sfdisk just
# wrote. Copying the whole sector would destroy both.
dd if="${boot_img}" of="${temporary}" bs=1 count=3 conv=notrunc status=none
dd if="${boot_img}" of="${temporary}" bs=1 skip=90 seek=90 count=350 \
    conv=notrunc status=none

# ---------------------------------------------------------------------------
# The artifacts
mv "${temporary}" "${image}"
qcow2="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.qcow2"
log "converting to ${qcow2}"
rm -f "${qcow2}"
qemu-img convert -f raw -O qcow2 "${image}" "${qcow2}"

# Both artifacts, compressed, and both kept: the .xz is what gets published and
# what a "curl | xz -d | dd" writes from, and the file beside it is what "make
# run-disk-image" boots and what a hypervisor is pointed at directly.
for artifact in "${image}" "${qcow2}"; do
    log "compressing $(basename "${artifact}")"
    xz --keep --force "${artifact}"
    write_sha256_manifest "${artifact}.xz"
done

log "disk image ready:"
for artifact in "${image}" "${image}.xz" "${qcow2}" "${qcow2}.xz"; do
    # Two figures for the raw image and one for everything else: it is a sparse
    # file, so what it costs to keep is not what it says it is.
    log "  $(basename "${artifact}"): $(($(stat -c %s "${artifact}") / 1048576)) MiB apparent, $(($(stat -c %b "${artifact}") * 512 / 1048576)) MiB on disk"
done
log "write it with: xz -dc $(basename "${image}").xz | dd of=/dev/sdX bs=4M oflag=direct status=progress"
log "root is PARTUUID=${root_partuuid}; it grows into the disk it is written to at the first boot"
