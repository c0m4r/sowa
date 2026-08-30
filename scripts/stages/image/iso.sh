#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

require_command grub-mkrescue
require_command xorriso

kernel_version="$(source_version linux)"
kernel="${ARTIFACT_DIR}/vmlinuz-${kernel_version}-${ARTIFACT_ARCH}"
initramfs="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.cpio.xz"
squashfs="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.sfs"
[[ -f "${kernel}" ]] || die "kernel artifact missing; run 'make kernel'"
[[ -f "${initramfs}" ]] || die "initramfs artifact missing; run 'make image'"
[[ -f "${squashfs}" ]] || die "squashfs artifact missing; run 'make image'"

# Locate the GRUB platform module tree so a BIOS-only fallback can name it.
grub_libdir="$(host_grub_libdir)"

# A hybrid BIOS+UEFI ISO needs the GRUB EFI platform files plus mtools, which
# grub-mkrescue uses to build the UEFI El Torito FAT image. When either is
# missing, fall back to a BIOS-only image rather than failing.
uefi=0
if [[ -d "${grub_libdir}/x86_64-efi" ]] && command -v mformat >/dev/null 2>&1; then
    uefi=1
elif [[ ! -d "${grub_libdir}/x86_64-efi" ]]; then
    log "warning: GRUB x86_64-efi platform files not found; building a BIOS-only ISO"
else
    log "warning: mtools not found; building a BIOS-only ISO without UEFI boot"
fi

staging="${BUILD_DIR}/iso"
reset_build_dir "${staging}"

# /boot is what the firmware and boot loader read; everything under the base
# directory is the payload, which early userspace finds for itself once Linux
# is running.
#
#   /boot/vmlinuz                     the kernel
#   /boot/initramfs.img               liveinit, and nothing else
#   /boot/grub/grub.cfg               the menu
#   /boot/grub/loopback.cfg           for a GRUB that boots this ISO from a file
#   /sowa/<id>.id                     the marker that identifies this medium
#   /sowa/x86_64/root.sfs             the root filesystem
#   /sowa/x86_64/root.sfs.sha256      what checksum=y verifies it against
#   /sowa/pkglist.x86_64.txt          what is in it, for a reader
basedir="${DISTRO_NAME}"
mkdir -p "${staging}/boot/grub" "${staging}/${basedir}/${PKG_ARCH}"
install -m 0644 "${kernel}" "${staging}/boot/vmlinuz"
install -m 0644 "${initramfs}" "${staging}/boot/initramfs.img"
install -m 0644 "${squashfs}" "${staging}/${basedir}/${PKG_ARCH}/root.sfs"

# The medium's identity is the payload checksum rather than a build timestamp:
# two Sowa media are then the same medium exactly when they carry the same root
# filesystem, and a reproducible build has no timestamp identity to vary.
medium_id="$(live_medium_id "${squashfs}")"
: > "${staging}/${basedir}/${medium_id}.id"
# sha256sum records the path it was given, and liveinit reads the first field
# only; the name is rewritten anyway so that the file describes the medium
# rather than the build directory it came from.
printf '%s  root.sfs\n' "$(cut -d' ' -f1 < "${squashfs}.sha256")" \
    > "${staging}/${basedir}/${PKG_ARCH}/root.sfs.sha256"

# What is in the image, in one file someone can read without mounting it.
while IFS= read -r package; do
    printf '%s %s\n' "${package}" "$(package_version "${package}")"
done < <(image_package_names) | sort \
    > "${staging}/${basedir}/pkglist.${PKG_ARCH}.txt"

# An ISO9660 volume id is limited to 32 characters of [A-Z0-9_].
volid="$(printf '%s_%s' "${DISTRO_NAME}" "${DISTRO_VERSION}" \
    | tr '[:lower:].-' '[:upper:]__' | cut -c1-32)"

# The kernel command line, shared by every entry and by loopback.cfg. It names
# the medium by the identity above rather than by device or label, so a machine
# with a second copy of the medium plugged into it - or with a disk that has
# had the ISO unpacked onto it - boots the one it was actually started from.
#
# The consoles: the entry names both, so the kernel log reaches the serial line
# and the display. Their order still decides /dev/console - it is whichever
# "console=" comes last - and that only matters to init's own messages and to
# the single-user shell, both of which follow it. The prompt does not:
# /etc/inittab gives every console a getty of its own.
cmdline="sowa.basedir=${basedir} sowa.id=${medium_id} copytoram=auto"
cmdline+=" console=tty0 console=ttyS0,115200 panic=-1"

cat > "${staging}/boot/grub/grub.cfg" <<EOF
set timeout=5

# The mode GRUB sets for itself and, because of gfxpayload, the one Linux
# inherits rather than resetting. Without these the kernel comes up on whatever
# the firmware left behind - 1024x768 on QEMU's default VGA - and the console is
# a quarter of a 1080p screen. "all_video" is what makes the video drivers
# available to ask; gfxmode is a fallback list, so a display that cannot do the
# first entry drops to the next instead of failing to boot.
insmod all_video
set gfxmode=${ISO_GFXMODE}
set gfxpayload=keep

# The probe below is about GRUB, not about Linux. GRUB's ns8250 driver only
# registers a port whose line status register reads back something other than
# 0xff, which a floating ISA bus does not, so "serial" fails on a machine with
# no UART - a laptop booted from a USB stick - and succeeds under QEMU, where
# "make run-iso" drives the whole boot over ttyS0. Naming a terminal GRUB never
# registered is an error, which is why the terminal lines are inside the test
# rather than beside it.
if serial --unit=0 --speed=115200; then
    terminal_input serial console
    terminal_output serial console
fi

menuentry "${DISTRO_NAME^} Linux ${DISTRO_VERSION}" --id sowa {
    linux /boot/vmlinuz ${cmdline} checksum=y
    initrd /boot/initramfs.img
}

# The escape hatch for slow or already independently verified media. Integrity
# checking is the default because a successful boot should not silently depend
# on corrupt squashfs blocks that happen not to have been read yet. This check
# detects damage only: the checksum is stored on the same medium, so release
# authenticity comes from the signed external release manifest.
menuentry "${DISTRO_NAME^} Linux ${DISTRO_VERSION} (skip medium verification)" --id sowa-noverify {
    linux /boot/vmlinuz ${cmdline}
    initrd /boot/initramfs.img
}

# A root shell instead of the default runlevel. "single" is not a parameter
# liveinit claims, so it is passed through to /sbin/init the way the kernel
# would have passed it had there been no initramfs at all.
menuentry "${DISTRO_NAME^} Linux ${DISTRO_VERSION} (single user)" --id sowa-single {
    linux /boot/vmlinuz ${cmdline} checksum=y single
    initrd /boot/initramfs.img
}
EOF

# Booting the ISO as a file. A GRUB on some other system loopback-mounts the
# image, sources this, and gets a menu entry that tells liveinit where the file
# is rather than which device to look at - which is the only way to boot an
# image that is not a medium of its own.
#
#   menuentry "Sowa" {
#       set isofile=/sowa.iso
#       loopback loop $isofile
#       configfile (loop)/boot/grub/loopback.cfg
#   }
cat > "${staging}/boot/grub/loopback.cfg" <<EOF
menuentry "${DISTRO_NAME^} Linux ${DISTRO_VERSION} (from \${iso_path})" --id sowa-loopback {
    linux /boot/vmlinuz ${cmdline} checksum=y img_loop="\${iso_path}"
    initrd /boot/initramfs.img
}
EOF

mkrescue_args=(
    --product-name="${DISTRO_NAME^} Linux"
    --product-version="${DISTRO_VERSION}"
)
if ((uefi)); then
    log "building a hybrid BIOS/UEFI ISO"
else
    # Restrict grub-mkrescue to the BIOS platform so it does not attempt (and
    # fail) the UEFI image when mtools or the EFI modules are unavailable.
    mkrescue_args+=(-d "${grub_libdir}/i386-pc")
fi

iso="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.iso"
temporary="${iso}.tmp.$$"
trap 'rm -f "${temporary}"' EXIT
log "create ${iso}"
grub-mkrescue "${mkrescue_args[@]}" -o "${temporary}" "${staging}" -- -volid "${volid}"
[[ -s "${temporary}" ]] || die "grub-mkrescue produced no ISO output"
mv "${temporary}" "${iso}"
trap - EXIT
write_sha256_manifest "${iso}"
log "bootable ISO ready: ${iso} ($(($(stat -c %s "${iso}") / 1048576)) MiB)"
log "medium id ${medium_id}"
# Booting it costs the writable layer plus what is being read, not the size of
# the tree: the root filesystem is mounted from the medium rather than unpacked
# into memory. Said here because this is the artifact that gets written to a
# USB stick and carried to some other machine, and that machine's memory is the
# one thing about it this build cannot check.
log "it needs at least $(live_ram_stream_mib) MiB of RAM; with $(live_ram_copytoram_mib "${squashfs}") MiB it copies itself to RAM and frees the medium"
