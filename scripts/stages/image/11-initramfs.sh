#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"
# shellcheck source=../../lib/archive.sh
source "${PROJECT_ROOT}/scripts/lib/archive.sh"

require_command mksquashfs
require_command cpio
require_command xz

[[ -d "${ROOTFS_DIR}" ]] || die "root filesystem is missing"

# The live medium is two files: the root filesystem as a squashfs, and a
# one-megabyte initramfs whose only job is to find it and mount it. That split
# is the whole point of this stage. Sowa used to pack the root filesystem
# itself into the initramfs, which meant the kernel unpacked the entire tree
# into a ramfs whose pages can never be reclaimed - close to a gigabyte
# resident before the system had done anything, and a quiet, partial boot on a
# machine that could not spare it. Here the tree stays compressed and is read
# through the page cache, which the kernel is free to evict.

# Embed the kernel in the image so the live system carries its own /boot/vmlinuz.
# sowa-setup copies it to the target disk, and the installed system boots it
# directly (root= on the disk) with no on-disk initramfs.
kernel="${ARTIFACT_DIR}/vmlinuz-$(source_version linux)-${ARTIFACT_ARCH}"
[[ -f "${kernel}" ]] || die "kernel artifact missing; run 'make kernel'"
install -D -m 0644 "${kernel}" "${ROOTFS_DIR}/boot/vmlinuz"

# The kernel is a package like any other: it is staged here, where it enters the
# image, so 'make packages' can publish it and an installed system can replace
# /boot/vmlinuz without a new image.
kernel_pkgdir="$(pkg_stage linux)"
install -D -m 0644 "${kernel}" "${kernel_pkgdir}/boot/vmlinuz"
# The kernel's licence, into both trees for the one reason the other packages
# need it in only one: this stage runs after the root filesystem has been
# assembled, so the staging tree is what the manifest is cut from while the
# image is what the archive is cut from, and the two have to agree.
pkg_install_licenses linux "${kernel_pkgdir}"
pkg_install_licenses linux "${ROOTFS_DIR}"
pkg_check_licenses linux "${kernel_pkgdir}"
pkg_check_licenses linux "${ROOTFS_DIR}"
pkg_tree_manifest "${kernel_pkgdir}" "${PKG_META_DIR}/linux.files"
pkg_db_write "${ROOTFS_DIR}" linux "${PKG_META_DIR}/linux.files"

# ---------------------------------------------------------------- liveinit

# The initramfs is one static binary, so the C library it is linked against has
# to be in the tree rather than beside it. Everything else in this repository
# builds against the sysroot dynamically; this is the one thing that cannot,
# because there is nowhere in a one-megabyte image for a loader to look.
liveinit_source="${PROJECT_ROOT}/src/liveinit"
liveinit_build="${BUILD_DIR}/liveinit"
[[ -f "${liveinit_source}/liveinit.c" ]] \
    || die "the live init sources are missing from ${liveinit_source}"
reset_build_dir "${liveinit_build}"
cp -a "${liveinit_source}/." "${liveinit_build}/"

initramfs_root="${BUILD_DIR}/initramfs"
reset_build_dir "${initramfs_root}"

(
    target_configure_env
    # A "make" run in src/liveinit leaves a host binary behind, and a host
    # binary is indistinguishable from a cross-compiled one by name alone.
    make -C "${liveinit_build}" clean
    # LIVE_ARCH is the architecture directory liveinit looks in on the medium,
    # and it is compiled in rather than passed on the command line: the binary
    # ships on the medium it describes. It comes from PKG_ARCH so that this and
    # the directory the ISO stage creates cannot drift apart.
    make -C "${liveinit_build}" VERSION="${DISTRO_VERSION}" \
        LIVE_ARCH="${PKG_ARCH}" -j"${JOBS}"
    make -C "${liveinit_build}" DESTDIR="${initramfs_root}" BINDIR=/ install
)

[[ -f "${initramfs_root}/init" ]] || die "liveinit was not installed as /init"
"${TARGET}-strip" "${initramfs_root}/init"
"${TARGET}-readelf" -h "${initramfs_root}/init" \
    | grep -q 'Advanced Micro Devices X86-64' \
    || die "liveinit was not built for the target architecture"
# A dynamically linked /init would look identical to the check above and fail
# at boot with nothing on the console, because the loader it asks for is on the
# filesystem it has not mounted yet.
if "${TARGET}-readelf" -l "${initramfs_root}/init" | grep -q 'INTERP'; then
    die "liveinit is dynamically linked; it must be static"
fi

# The mount points liveinit needs before it can mount anything: it puts proc,
# sysfs and devtmpfs on the first three, its own tmpfs on /run, and the live
# root filesystem on /new_root.
mkdir -p "${initramfs_root}"/{dev,proc,sys,run,new_root}

initramfs="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.cpio.xz"
legacy_initramfs="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.cpio.gz"
temporary="${initramfs}.tmp.$$"
trap 'rm -f "${temporary}"' EXIT
log "create ${initramfs}"
# Linux's initramfs decoder supports CRC32, not XZ's default CRC64. This
# changes only the stream check; the compression preset and threading remain
# XZ defaults.
(
    cd "${initramfs_root}"
    find . -print0 \
        | sort -z \
        | cpio --null --create --format=newc --owner=0:0 --reproducible 2>/dev/null \
        | xz_compress_default --check=crc32 > "${temporary}"
)
# The temporary name ends in .tmp.<pid>, so test it on stdin instead of asking
# xz to infer a suffix from the filename.
xz_test_stream < "${temporary}"
xz_stream_uses_check CRC32 "${temporary}" \
    || die "the initramfs XZ stream does not use the kernel-supported CRC32 check"
mv "${temporary}" "${initramfs}"
trap - EXIT
write_sha256_manifest "${initramfs}"
rm -f "${legacy_initramfs}" "${legacy_initramfs}.sha256"

# ---------------------------------------------------------------- squashfs

# /init belongs to the boot image rather than to the root filesystem, and the
# recovery image (which is still a single cpio of the whole tree) leaves one
# behind. Removing it here keeps the squashfs the same whichever targets were
# built before it.
rm -f "${ROOTFS_DIR}/init"

squashfs="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}.sfs"
temporary="${squashfs}.tmp.$$"
trap 'rm -f "${temporary}"' EXIT

compressor_options=()
case "${SFS_COMPRESSOR}" in
    # The x86 BCJ filter rewrites relative call and jump targets into absolute
    # ones before compression, which makes the same instruction sequence
    # compress the same way wherever it appears. On a tree that is mostly
    # binaries it is worth several percent for nothing.
    xz) compressor_options=(-Xbcj x86) ;;
    zstd) compressor_options=(-Xcompression-level 19) ;;
esac

# Timestamps are not passed on the command line: mksquashfs reads
# SOURCE_DATE_EPOCH out of the environment itself, and refuses to run at all if
# it is given both ("SOURCE_DATE_EPOCH and command line options can't be used
# at the same time"). The environment is the better of the two anyway - it is
# where the rest of this build's timestamps already come from, and it *clamps*
# rather than flattens, so a file older than the epoch keeps the date its
# upstream tarball gave it instead of every file in the image claiming to have
# been created on the same afternoon.
#
# It only does that from 4.5 onwards. 4.4 ignores the variable without saying
# so, which would produce an image whose timestamps - and therefore whose
# SHA-256, and therefore whose medium id - changed on every build.
squashfs_tools_version="$(mksquashfs -version | sed -n '1s/.*version \([0-9][0-9.]*\).*/\1/p')"
[[ "$(printf '4.5\n%s\n' "${squashfs_tools_version}" | sort -V | sed -n 1p)" == 4.5 ]] \
    || die "squashfs-tools 4.5 or newer is required (found ${squashfs_tools_version:-an unreadable version}): older versions ignore SOURCE_DATE_EPOCH"

log "create ${squashfs} (${SFS_COMPRESSOR}, ${SFS_BLOCK_SIZE} blocks)"
# -all-root because the tree is assembled by an unprivileged build and every
# file in it is owned by whoever ran the build; the image's own ownership is
# recorded in the package database, not in the build user's uid. That, the
# timestamps above and the sorted, deterministic ordering mksquashfs uses by
# default are what make the same tree produce the same image.
mksquashfs "${ROOTFS_DIR}" "${temporary}" \
    -comp "${SFS_COMPRESSOR}" "${compressor_options[@]}" \
    -b "${SFS_BLOCK_SIZE}" \
    -all-root -no-xattrs -noappend -no-progress -quiet \
    -processors "${JOBS}"
[[ -s "${temporary}" ]] || die "mksquashfs produced no output"
mv "${temporary}" "${squashfs}"
trap - EXIT
write_sha256_manifest "${squashfs}"

# What the medium costs and what booting it costs. The second figure is the one
# that used to be a hard requirement and is now a threshold: below it the live
# system streams the root filesystem from the medium instead of copying it, and
# it still boots.
unpacked_mib="$(($(du -sk "${ROOTFS_DIR}" | cut -f1) / 1024))"
log "root filesystem: ${unpacked_mib} MiB of files in $(($(stat -c %s "${squashfs}") / 1048576)) MiB of squashfs"
log "the live system streams it from the medium; give the machine at least $(live_ram_stream_mib) MiB"
log "at $(live_ram_copytoram_mib "${squashfs}") MiB or more it copies the image to RAM and the medium can be removed"
