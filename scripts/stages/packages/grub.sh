#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

grub_source="$(prepare_source grub)"
build_triplet="$(gcc -dumpmachine)"
# Both platforms install into one staging tree, so the package carries the
# BIOS and UEFI module sets together, exactly as the image does.
pkgdir="$(pkg_stage grub)"

# GRUB 2.14 generates grub-core/extra_deps.lst into the build tree from the
# Makefile's EXTRA_DEPS variable. GRUB 2.12 instead read a static copy out of the
# source tree that its release tarball omitted, so this stage used to create an
# empty one there. That leftover breaks 2.14: these are out-of-tree builds, so
# make's VPATH search finds the source-tree copy, considers the prerequisite
# satisfied and never runs the rule that writes the build-tree copy - while the
# syminfo.lst recipe cats the bare relative name, which resolves only in the
# build tree. Extracted sources are cached, so clear a stale copy rather than
# assuming a fresh unpack.
rm -f "${grub_source}/grub-core/extra_deps.lst"

# GRUB's utility programs (grub-install, grub-probe, grub-mkimage, ...) run on
# the Sowa target and are built with the cross toolchain (--host). Each boot
# platform is a separate configure+build sharing one DESTDIR: BIOS i386-pc needs
# 32-bit freestanding modules, UEFI x86_64-efi needs 64-bit ones. The image
# toolchain is the same cross gcc; -m32 selects the 32-bit code model for BIOS.
#
# --disable-liblzma keeps the build independent of stage order. GRUB's configure
# links a system liblzma whenever it finds one, but only to serve an explicit
# "-C xz" core compression: the i386-pc default is GRUB's own bundled LZMA
# encoder and x86_64-efi carries no decompressor at all, so nothing installed
# here needs it. xz is stage 48 and this is stage 23, so a clean build never
# sees liblzma while a rebuild of this stage alone does, and that difference
# would silently change which libraries the shipped grub-install links.
#
# -fno-reorder-blocks-and-partition is required, not a tuning choice. GCC 16
# splits cold basic blocks into their own .text.unlikely sections, and the
# default linker script emits those ahead of .text: a "terminate_arg.cold" stub
# landed at the base of kernel.img and pushed _start to base+0x2b. The i386-pc
# decompressor jumps to the image base unconditionally, so the BIOS core image
# executed the stub instead of GRUB and the machine died before "Welcome to
# GRUB!". Keeping every function in one piece keeps _start at the base.
readonly GRUB_TARGET_CFLAGS="-std=gnu11 -Os -fno-reorder-blocks-and-partition"

# Where the BIOS images are linked, which 2.14 gets wrong on its own. Its
# configure asks AX_CHECK_LINK_FLAG whether the linker accepts
# "-Wl,--image-base,0x400000" and uses that instead of "-Wl,-Ttext" when it
# does. GNU ld accepts it for ELF output - it is a PE option, and this is only
# the right question when GRUB is built with a PE toolchain - but the two mean
# different things: -Ttext puts the .text section at the address, --image-base
# puts the whole image there and .text lands after the ELF header and program
# headers, 0x74 further on. Every i386-pc image is then linked 0x74 above where
# it is loaded, and grub-install refuses the kernel with "is miscompiled: its
# start address is 0x9074 instead of 0x9000: ld.gold bug?" - on the installed
# machine, since the BIOS core image is assembled by grub-install rather than
# here. The answer to the probe is what has to change, so its cached result is
# supplied below and configure takes the -Wl,-Ttext branch. Only i386-pc is
# affected: the EFI kernel is a relocatable link that grub-mkimage lays out.
readonly GRUB_IMAGE_BASE_PROBE=ax_cv_check_ldflags___Wl___image_base_0x400000

build_platform() {
    local platform="$1" cpu="$2" target_cc="$3"
    local tree="${BUILD_DIR}/grub-${platform}"
    reset_build_dir "${tree}"
    (
        cd "${tree}"
        target_configure_env
        "${grub_source}/configure" \
            --prefix=/usr \
            --sysconfdir=/etc \
            --build="${build_triplet}" \
            --host="${TARGET}" \
            --target="${cpu}" \
            --with-platform="${platform}" \
            --disable-werror \
            --disable-nls \
            --disable-efiemu \
            --disable-grub-mkfont \
            --disable-grub-mount \
            --disable-device-mapper \
            --disable-libzfs \
            --disable-liblzma \
            BUILD_CC=gcc \
            "${GRUB_IMAGE_BASE_PROBE}=no" \
            CFLAGS="-std=gnu11 -O2" \
            TARGET_CC="${target_cc}" \
            TARGET_CFLAGS="${GRUB_TARGET_CFLAGS}" \
            TARGET_OBJCOPY="${TARGET}-objcopy" \
            TARGET_STRIP="${TARGET}-strip" \
            TARGET_NM="${TARGET}-nm" \
            TARGET_RANLIB="${TARGET}-ranlib"
        make -j"${JOBS}"
        make DESTDIR="${pkgdir}" install
    )
}

build_platform pc i386 "${TARGET}-gcc -m32"

# Both ways the BIOS kernel image can come out at the wrong address, checked
# here because nothing else in the build looks: the core image the machine
# actually boots is assembled by grub-install on the installed system, so a
# kernel.img linked wrong leaves this stage, the packages and the ISO all
# green and fails at the end of an installation.
#
# The entry point has to be at the start of the loaded image, which is what the
# cold-block ordering broke, and the loaded image has to be at the address the
# link was asked for, which is what --image-base broke. Only the first was
# checked before, and the two move together under the second - a whole image
# shifted up by the ELF headers still has its entry at its own base - so the
# link address is read back out of the generated Makefile and compared too.
# That is the same comparison grub-install makes before it will write a core
# image, made here, where the fix is.
verify_pc_entry_point() {
    local kernel="${BUILD_DIR}/grub-pc/grub-core/kernel.exec"
    local makefile="${BUILD_DIR}/grub-pc/grub-core/Makefile"
    local entry base link_address
    entry="$("${TARGET}-readelf" -h "${kernel}" | awk '/Entry point/ { print $NF }')"
    base="$("${TARGET}-readelf" -l "${kernel}" | awk '$1 == "LOAD" { print $3; exit }')"
    # The commented-out variants for the other platforms all begin with "#".
    link_address="$(awk '/^kernel_exec_LDFLAGS/ { print $NF }' "${makefile}")"
    link_address="${link_address##*,}"
    [[ "${link_address}" == 0x* ]] \
        || die "the i386-pc kernel link address is not in ${makefile}"
    [[ "$(( entry ))" -eq "$(( base ))" ]] \
        || die "i386-pc kernel entry ${entry} is not at the image base ${base}; the BIOS core image would not boot"
    [[ "$(( entry ))" -eq "$(( link_address ))" ]] \
        || die "i386-pc kernel entry ${entry} is not the link address ${link_address}; grub-install would call it miscompiled and install no boot loader"
}
verify_pc_entry_point

build_platform efi x86_64 "${TARGET}-gcc"

for binary in grub-install grub-probe grub-mkimage grub-bios-setup \
    grub-mkrelpath grub-editenv grub-mkstandalone; do
    target_binary="${pkgdir}/usr/sbin/${binary}"
    [[ -f "${target_binary}" ]] && "${TARGET}-strip" "${target_binary}"
    target_binary="${pkgdir}/usr/bin/${binary}"
    [[ -f "${target_binary}" ]] && "${TARGET}-strip" "${target_binary}"
done

grub_install="$(command -v true)"
for candidate in "${pkgdir}/usr/sbin/grub-install" "${pkgdir}/usr/bin/grub-install"; do
    [[ -x "${candidate}" ]] && grub_install="${candidate}"
done
[[ "${grub_install}" != "$(command -v true)" ]] || die "grub-install was not installed"
[[ -f "${pkgdir}/usr/lib/grub/i386-pc/boot.img" ]] \
    || die "GRUB i386-pc (BIOS) platform was not built"
[[ -f "${pkgdir}/usr/lib/grub/x86_64-efi/moddep.lst" ]] \
    || die "GRUB x86_64-efi (UEFI) platform was not built"
"${TARGET}-readelf" -d "${grub_install}" | grep -q 'libc.so.6'
pkg_merge grub
log "installed GRUB $(source_version grub) for i386-pc and x86_64-efi"
