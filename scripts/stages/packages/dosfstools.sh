#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

dosfstools_source="$(prepare_source dosfstools)"
build_tree="${BUILD_DIR}/dosfstools"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage dosfstools)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# Compat symlinks provide mkfs.vfat/mkfs.msdos and fsck.vfat alongside the
# canonical mkfs.fat, matching what other tooling expects on the target.
"${dosfstools_source}/configure" \
    --prefix=/usr \
    --sbindir=/usr/sbin \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --enable-compat-symlinks \
    --without-udev
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/sbin/mkfs.fat" "${pkgdir}/usr/sbin/fsck.fat"

[[ -x "${pkgdir}/usr/sbin/mkfs.fat" ]] || die "mkfs.fat was not installed"
[[ -e "${pkgdir}/usr/sbin/mkfs.vfat" ]] || die "mkfs.vfat symlink was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/mkfs.fat" | grep -q 'libc.so.6'
pkg_merge dosfstools
log "installed dosfstools $(source_version dosfstools)"
