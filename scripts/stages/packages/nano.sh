#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

nano_source="$(prepare_source nano)"
build_tree="${BUILD_DIR}/nano"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage nano)"

build_triplet="$(sh "${nano_source}/config.guess")"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
"${nano_source}/configure" \
    --prefix=/usr \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-libmagic \
    --enable-utf8
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/bin/nano"
[[ -x "${pkgdir}/usr/bin/nano" ]] || die "nano was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/nano" | grep -q 'libncursesw.so.6'
[[ -f "${pkgdir}/usr/share/nano/sh.nanorc" ]] \
    || die "nano syntax definitions were not installed"
pkg_merge nano
log "installed GNU nano $(source_version nano)"
