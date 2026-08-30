#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

zlib_source="$(prepare_source zlib)"
build_tree="${BUILD_DIR}/zlib"
reset_build_dir "${build_tree}"
cp -a "${zlib_source}/." "${build_tree}/"
pkgdir="$(pkg_stage zlib)"

target_configure_env
export CHOST="${TARGET}"
cd "${build_tree}"
./configure \
    --prefix=/usr \
    --libdir=/usr/lib64
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/lib64/libz.so.1.3.2"
[[ -f "${pkgdir}/usr/lib64/libz.so.1.3.2" ]] \
    || die "zlib shared library was not installed"
[[ -f "${pkgdir}/usr/include/zlib.h" ]] || die "zlib headers were not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/lib64/libz.so.1.3.2" | grep -q 'libc.so.6'
pkg_merge zlib
log "installed zlib $(source_version zlib)"
