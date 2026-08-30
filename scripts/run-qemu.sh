#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_command qemu-system-x86_64

# How much memory the guest gets by default.
#
# The live medium mounts its root filesystem rather than unpacking it, so this
# no longer has to stay ahead of the size of the tree: 2 GiB is comfortably
# above the floor 'make image' prints, and low enough that the default boot is
# the one most machines will do - streaming from the medium rather than copying
# it to RAM, which liveinit only does with the image plus 2 GiB to spare.
#
# The recovery image is the exception. It is still a single cpio of the entire
# root filesystem, unpacked into a ramfs that cannot be reclaimed, so it needs
# several times the tree before it has any working space at all; too little is
# not a clean failure but a boot that continues on a truncated tree.
default_memory=2048M
if [[ "${1:-}" == --recovery ]]; then
    default_memory=4096M
fi

# User-mode networking keeps every QEMU target unprivileged. Incoming
# connections need an explicit forward: SSH gets its long-standing 2222:22
# default, and SOWA_QEMU_FORWARD adds arbitrary mappings in the compact form
# HOST:GUEST[/tcp|/udp] (or just PORT when both sides use the same port).
# All forwards are host-only unless SOWA_QEMU_BIND names another IPv4 address.
qemu_bind="${SOWA_QEMU_BIND:-127.0.0.1}"
if [[ ! "${qemu_bind}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    die "SOWA_QEMU_BIND must be an IPv4 address (got '${qemu_bind}')"
fi
IFS=. read -r -a qemu_bind_octets <<< "${qemu_bind}"
for octet in "${qemu_bind_octets[@]}"; do
    ((10#${octet} <= 255)) \
        || die "SOWA_QEMU_BIND must be an IPv4 address (got '${qemu_bind}')"
done

qemu_netdev="user,model=virtio-net-pci"
declare -A qemu_forwarded_ports=()

add_qemu_forward() {
    local spec="$1" host_port guest_port protocol key

    if [[ ! "${spec}" =~ ^([0-9]{1,5})(:([0-9]{1,5}))?(/(tcp|udp))?$ ]]; then
        die "invalid QEMU forward '${spec}'; use HOST:GUEST[/tcp|/udp] or PORT"
    fi
    host_port="$((10#${BASH_REMATCH[1]}))"
    guest_port="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
    guest_port="$((10#${guest_port}))"
    protocol="${BASH_REMATCH[5]:-tcp}"
    ((host_port >= 1 && host_port <= 65535 \
        && guest_port >= 1 && guest_port <= 65535)) \
        || die "QEMU forward ports must be between 1 and 65535 (got '${spec}')"

    key="${protocol}:${host_port}"
    [[ -z "${qemu_forwarded_ports[${key}]:-}" ]] \
        || die "QEMU ${protocol} host port ${host_port} is forwarded more than once"
    qemu_forwarded_ports["${key}"]=1
    qemu_netdev+=",hostfwd=${protocol}:${qemu_bind}:${host_port}-:${guest_port}"
}

# Set SOWA_SSH_PORT=0 to drop the SSH forward, or to another host port if 2222
# is taken. It uses the same validation and duplicate detection as extra ports.
ssh_port="${SOWA_SSH_PORT:-2222}"
if [[ "${ssh_port}" != 0 ]]; then
    add_qemu_forward "${ssh_port}:22/tcp"
fi

qemu_extra_forwards="${SOWA_QEMU_FORWARD:-}"
qemu_extra_forwards="${qemu_extra_forwards//,/ }"
read -r -a qemu_extra_forwards <<< "${qemu_extra_forwards}"
for qemu_forward in "${qemu_extra_forwards[@]}"; do
    add_qemu_forward "${qemu_forward}"
done

qemu_common=(
    -machine accel=kvm:tcg
    -m "${SOWA_QEMU_MEM:-${default_memory}}"
    -smp "${SOWA_QEMU_CPUS:-1}"
    -nic "${qemu_netdev}"
    -no-reboot
)

# Headless on the serial line by default. The kernel draws its boot logo on the
# video console, which -nographic discards, so SOWA_QEMU_DISPLAY=gtk (or sdl)
# opens a window to watch it on; the serial console stays on stdio either way.
# One penguin is drawn per online CPU, so SOWA_QEMU_CPUS=4 gets four of them.
#
# A minimal QEMU install often has no display backend compiled in at all, and
# QEMU's own error names the backend but not the fix, so check the build up
# front. SOWA_QEMU_VNC=:0 is the way out that needs no UI backend, since the
# VNC server is part of the base build: point a viewer at that display and the
# boot logo is there.
require_display_backend() {
    local want="$1" available
    available="$(qemu-system-x86_64 -display help | tail -n +2)"
    grep -qxF "${want}" <<< "${available}" && return 0
    die "QEMU has no '${want}' display backend (this build offers:" \
        "$(tr '\n' ' ' <<< "${available}")). Install the matching UI backend" \
        "or set SOWA_QEMU_VNC=:0 and attach a VNC viewer instead."
}

# The size of the guest's screen, when there is one. QEMU's default video device
# is the Bochs-style "std" VGA, and it comes up at 1024x768 - a quarter of a
# 1080p monitor by area, which is what the window looks like. The mode is a
# property of the emulated card rather than anything Linux chose, so it is set
# here and not on the kernel command line, and the framebuffer console follows
# it: at the 8x16 console font, 1920x1080 is a 240x67 text screen.
#
# This is deliberately not the same question as how big the *window* is. Scaling
# a 1024x768 guest up to fill the monitor is the other answer, and QEMU can do
# it - SOWA_QEMU_DISPLAY=gtk,zoom-to-fit=on - but it interpolates, so the text
# ends up soft. Giving the guest the pixels keeps them sharp.
#
# SOWA_QEMU_VIDEO=none leaves the card at its own default.
video_mode="${SOWA_QEMU_VIDEO:-1920x1080}"
qemu_video=()
if [[ "${video_mode}" != none ]]; then
    [[ "${video_mode}" =~ ^([0-9]+)x([0-9]+)$ ]] \
        || die "SOWA_QEMU_VIDEO must look like 1920x1080, or be 'none' (got '${video_mode}')"
    # "-vga none" drops the card QEMU adds by itself, and the card is then added
    # back with the mode as a property of the device. Setting it with -global
    # instead looks equivalent and is not: -global only reaches a device the
    # machine creates by that name, and QEMU answers a miss with "warning:
    # global VGA.xres=1920 not used" on stderr and carries on booting at the
    # default size.
    qemu_video=(
        -vga none
        -device "VGA,xres=${BASH_REMATCH[1]},yres=${BASH_REMATCH[2]}"
    )
fi

if [[ -n "${SOWA_QEMU_DISPLAY:-}" ]]; then
    require_display_backend "${SOWA_QEMU_DISPLAY%%,*}"
    qemu_common+=(-display "${SOWA_QEMU_DISPLAY}" -serial mon:stdio "${qemu_video[@]}")
elif [[ -n "${SOWA_QEMU_VNC:-}" ]]; then
    qemu_common+=(-display none -vnc "${SOWA_QEMU_VNC}" -serial mon:stdio "${qemu_video[@]}")
else
    # -nographic still leaves a VGA card in the machine, but nothing draws it, so
    # setting its mode would only be a way to get a warning about an unused
    # -global on a QEMU build with the device compiled out.
    qemu_common+=(-nographic)
fi

disk_image="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}-disk.img"
disk_size="${SOWA_DISK_SIZE:-12G}"

ensure_disk_image() {
    if [[ ! -f "${disk_image}" ]]; then
        log "creating blank ${disk_size} disk image ${disk_image}"
        truncate -s "${disk_size}" "${disk_image}"
    fi
}

find_ovmf() {
    local name candidate
    for name in OVMF_CODE.4m.fd OVMF_CODE.fd; do
        for candidate in "/usr/share/edk2-ovmf/x64/${name}" \
            "/usr/share/ovmf/x64/${name}" "/usr/share/OVMF/${name}"; do
            [[ -f "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
        done
    done
    return 1
}

case "${1:-}" in
    "")
        # The live payload without the boot loader: QEMU hands the kernel and
        # the initramfs to the machine directly and the ISO is attached as a
        # read-only disk for liveinit to find, which is the short way round
        # when the thing being changed is liveinit rather than GRUB. The medium
        # is still named by its id, so this boots the image it was given rather
        # than whatever else happens to be attached.
        #
        # A disk rather than a CD-ROM, which is the other half of why this
        # target is worth having beside "make run-iso": it is what a stick
        # written with dd looks like, and copytoram=auto declines to copy from
        # an optical drive. Whether it copies here depends on the memory - the
        # image plus 2 GiB - so SOWA_QEMU_MEM is how that path gets exercised.
        kernel="${ARTIFACT_DIR}/vmlinuz-$(source_version linux)-${ARTIFACT_ARCH}"
        initramfs="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.cpio.xz"
        squashfs="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.sfs"
        iso="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.iso"
        [[ -f "${kernel}" ]] || die "kernel artifact missing; run 'make kernel'"
        [[ -f "${initramfs}" ]] || die "initramfs artifact missing; run 'make image'"
        [[ -f "${squashfs}" ]] || die "squashfs artifact missing; run 'make image'"
        [[ -f "${iso}" ]] || die "ISO artifact missing; run 'make iso'"
        exec qemu-system-x86_64 "${qemu_common[@]}" \
            -kernel "${kernel}" \
            -initrd "${initramfs}" \
            -drive "file=${iso},format=raw,if=virtio,readonly=on" \
            -append "sowa.basedir=${DISTRO_NAME} sowa.id=$(live_medium_id "${squashfs}") copytoram=auto console=tty0 console=ttyS0 panic=-1"
        ;;
    --recovery)
        kernel="${ARTIFACT_DIR}/vmlinuz-$(source_version linux)-${ARTIFACT_ARCH}"
        initramfs="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}-recovery.cpio.xz"
        [[ -f "${kernel}" ]] || die "kernel artifact missing; run 'make kernel'"
        [[ -f "${initramfs}" ]] || die "recovery initramfs missing; run 'make recovery-image'"
        exec qemu-system-x86_64 "${qemu_common[@]}" \
            -kernel "${kernel}" \
            -initrd "${initramfs}" \
            -append 'console=tty0 console=ttyS0 rdinit=/init single panic=-1'
        ;;
    --iso)
        iso="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.iso"
        [[ -f "${iso}" ]] || die "ISO artifact missing; run 'make iso'"
        # GRUB on the ISO owns the kernel command line; boot from the CD-ROM.
        exec qemu-system-x86_64 "${qemu_common[@]}" \
            -cdrom "${iso}" \
            -boot d
        ;;
    --install)
        # Boot the ISO with a blank disk attached so sowa-setup can install onto
        # it. The disk is IDE so it is bootable by both SeaBIOS and OVMF later.
        iso="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.iso"
        [[ -f "${iso}" ]] || die "ISO artifact missing; run 'make iso'"
        ensure_disk_image
        exec qemu-system-x86_64 "${qemu_common[@]}" \
            -cdrom "${iso}" \
            -drive "file=${disk_image},format=raw,if=ide" \
            -boot d
        ;;
    --disk)
        # Boot the installed disk on legacy BIOS (SeaBIOS).
        [[ -f "${disk_image}" ]] || die "disk image missing; run 'make run-install' first"
        exec qemu-system-x86_64 "${qemu_common[@]}" \
            -drive "file=${disk_image},format=raw,if=ide" \
            -boot c
        ;;
    --disk-uefi)
        # Boot the installed disk on UEFI firmware (OVMF).
        [[ -f "${disk_image}" ]] || die "disk image missing; run 'make run-install' first"
        ovmf_code="$(find_ovmf)" || die "OVMF firmware not found; install edk2-ovmf"
        ovmf_vars_src="${ovmf_code/OVMF_CODE/OVMF_VARS}"
        ovmf_vars="${ARTIFACT_DIR}/ovmf-vars.fd"
        [[ -f "${ovmf_vars_src}" ]] || die "OVMF variable template not found: ${ovmf_vars_src}"
        cp -f "${ovmf_vars_src}" "${ovmf_vars}"
        exec qemu-system-x86_64 "${qemu_common[@]}" \
            -drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}" \
            -drive "if=pflash,format=raw,file=${ovmf_vars}" \
            -drive "file=${disk_image},format=raw,if=ide" \
            -boot c
        ;;
    --disk-image | --disk-image-uefi)
        # The prebuilt disk image, booted the way somebody who downloaded it
        # would boot it: nothing is handed to the machine but the disk, and GRUB
        # inside it does the rest. snapshot=on is what keeps this a test rather
        # than a use - QEMU writes to a temporary file it discards on exit, so
        # the artifact is still the artifact afterwards, and the first boot's
        # growroot has nothing to grow into because the virtual disk is exactly
        # as large as the image.
        prebuilt="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.img"
        [[ -f "${prebuilt}" ]] || die "disk image missing; run 'make disk-image' first"
        qemu_disk=(-drive "file=${prebuilt},format=raw,if=ide,snapshot=on" -boot c)
        if [[ "$1" == --disk-image-uefi ]]; then
            ovmf_code="$(find_ovmf)" || die "OVMF firmware not found; install edk2-ovmf"
            ovmf_vars_src="${ovmf_code/OVMF_CODE/OVMF_VARS}"
            ovmf_vars="${ARTIFACT_DIR}/ovmf-vars.fd"
            [[ -f "${ovmf_vars_src}" ]] || die "OVMF variable template not found: ${ovmf_vars_src}"
            cp -f "${ovmf_vars_src}" "${ovmf_vars}"
            qemu_disk=(
                -drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}"
                -drive "if=pflash,format=raw,file=${ovmf_vars}"
                "${qemu_disk[@]}"
            )
        fi
        exec qemu-system-x86_64 "${qemu_common[@]}" "${qemu_disk[@]}"
        ;;
    *) die "usage: $0 [--recovery|--iso|--install|--disk|--disk-uefi|--disk-image|--disk-image-uefi]" ;;
esac
