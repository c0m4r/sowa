#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

e2fsprogs_source="$(prepare_source e2fsprogs)"
build_tree="${BUILD_DIR}/e2fsprogs"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage e2fsprogs)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
# blkid and libuuid come from util-linux, so the probes have to find that one
# and no other: without PKG_CONFIG_LIBDIR pinned to the sysroot, e2fsprogs
# would ask the build host's pkg-config where blkid is.
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
# e2fsprogs' own libraries (libext2fs, libe2p, libss, libcom_err) are linked
# statically into the tools, so those add nothing to the target but the
# binaries themselves. libblkid and libuuid are the exception: e2fsprogs
# carries a copy of each, util-linux is where they actually come from, and two
# packages installing one blkid - or one uuid/uuid.h - is what the image's
# ownership split refuses. Asking for the external ones is also what stops the
# private copies, findfs and the second blkid(8) from being built at all.
# mke2fs reads /etc/mke2fs.conf for the ext4 feature profile, so keep
# sysconfdir at /etc.
"${e2fsprogs_source}/configure" \
    --prefix=/usr \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-libblkid \
    --disable-libuuid \
    --disable-fsck \
    --disable-defrag \
    --disable-e2initrd-helper \
    --without-crond-dir \
    --disable-uuidd \
    --disable-fuse2fs \
    --disable-elf-shlibs \
    --disable-testio-debug
make -j"${JOBS}"
# Place the essential tools under /usr rather than the historical /sbin and /lib.
make DESTDIR="${pkgdir}" install \
    root_sbindir=/usr/sbin root_bindir=/usr/bin root_libdir=/usr/lib64

# e2scrub's upstream cron entry assumes LVM and systemd, neither of which is
# part of Sowa.  Ensure an earlier install cannot leave it behind either.
rm -f "${pkgdir}/etc/cron.d/e2scrub_all"
grep -q '^HAVE_CROND = disabled$' MCONFIG \
    || die "e2fsprogs did not disable its unsupported e2scrub cron schedule"

for binary in mke2fs e2fsck tune2fs dumpe2fs resize2fs; do
    target_binary="${pkgdir}/usr/sbin/${binary}"
    [[ -f "${target_binary}" ]] && "${TARGET}-strip" "${target_binary}"
done

[[ -x "${pkgdir}/usr/sbin/mke2fs" ]] || die "mke2fs was not installed"
[[ -e "${pkgdir}/usr/sbin/mkfs.ext4" ]] || die "mkfs.ext4 was not installed"
[[ -f "${pkgdir}/etc/mke2fs.conf" ]] || die "mke2fs.conf was not installed"
# The private blkid was declined above; these are util-linux's to install.
for program in blkid findfs uuidgen; do
    [[ ! -e "${pkgdir}/usr/sbin/${program}" && ! -e "${pkgdir}/usr/bin/${program}" ]] \
        || die "e2fsprogs built ${program}; util-linux owns that name"
done
[[ ! -e "${pkgdir}/usr/include/blkid/blkid.h" ]] \
    || die "e2fsprogs installed its own blkid headers; util-linux owns them"
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/mke2fs" | grep -q 'libc.so.6'
for library in libblkid.so.1 libuuid.so.1; do
    "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/mke2fs" | grep -q "${library}" \
        || die "mke2fs was not linked against util-linux's ${library}"
done
pkg_merge e2fsprogs
log "installed e2fsprogs $(source_version e2fsprogs)"
