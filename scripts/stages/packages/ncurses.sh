#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

ncurses_source="$(prepare_source ncurses)"
build_tree="${BUILD_DIR}/ncurses"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage ncurses)"

build_triplet="$(sh "${ncurses_source}/config.guess")"
target_configure_env
cd "${build_tree}"
"${ncurses_source}/configure" \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-build-cc=gcc \
    --with-shared \
    --without-normal \
    --without-debug \
    --without-ada \
    --without-cxx \
    --without-cxx-binding \
    --without-tests \
    --enable-widec \
    --enable-pc-files \
    --with-pkg-config-libdir=/usr/lib64/pkgconfig \
    --with-termlib \
    --with-tic-path=/usr/bin/tic
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

ln -sfn libncursesw.so "${pkgdir}/usr/lib64/libncurses.so"
ln -sfn libncursesw.so "${pkgdir}/usr/lib64/libcurses.so"
ln -sfn ncursesw.pc "${pkgdir}/usr/lib64/pkgconfig/ncurses.pc"

[[ -f "${pkgdir}/usr/lib64/libncursesw.so.6.6" ]] \
    || die "ncurses wide-character shared library was not installed"
[[ -n "$(find "${pkgdir}/usr/share/terminfo" -type f -name linux -print -quit)" ]] \
    || die "ncurses did not install the Linux terminfo entry"
"${TARGET}-readelf" -d "${pkgdir}/usr/lib64/libncursesw.so.6.6" \
    | grep -q 'libtinfow.so.6'
pkg_merge ncurses
log "installed ncurses $(source_version ncurses) with wide-character support"
