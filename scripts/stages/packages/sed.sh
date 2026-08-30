#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

sed_source="$(prepare_source sed)"
build_tree="${BUILD_DIR}/sed"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage sed)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
"${sed_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-acl \
    --without-selinux
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/bin/sed"
[[ -x "${pkgdir}/usr/bin/sed" ]] || die "sed was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/sed" | grep -q 'libc.so.6'
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/sed" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "sed was not built with the cross compiler"
pkg_merge sed
log "installed sed $(source_version sed)"
