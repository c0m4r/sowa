#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

htop_source="$(prepare_source htop)"
build_tree="${BUILD_DIR}/htop"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage htop)"

build_triplet="$(sh "${htop_source}/build-aux/config.guess")"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
export CURSES_CFLAGS=-D_DEFAULT_SOURCE
export CURSES_LIBS='-lncursesw -ltinfow'
cd "${build_tree}"
"${htop_source}/configure" \
    --prefix=/usr \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-curses=ncursesw6 \
    --enable-unicode \
    --enable-affinity \
    --enable-capabilities=no \
    --enable-delayacct=no \
    --enable-sensors=no \
    --enable-demangling=no \
    --without-libunwind
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/bin/htop"
[[ -x "${pkgdir}/usr/bin/htop" ]] || die "htop was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/htop" | grep -q 'libncursesw.so.6'
pkg_merge htop
log "installed htop $(source_version htop)"
