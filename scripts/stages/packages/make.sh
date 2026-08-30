#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

make_source="$(prepare_source make)"
build_tree="${BUILD_DIR}/make"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage make)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# Guile would make make scriptable and would also make a base system's build
# tool depend on a Scheme interpreter that is not in the image.
"${make_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --without-guile
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/bin/make"
[[ -x "${pkgdir}/usr/bin/make" ]] || die "make was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/make" | grep -q 'libc.so.6'
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/make" | grep -q 'libguile'; then
    die "make links Guile; the image has no such library"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/make" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "make was not built with the cross compiler"
pkg_merge make
log "installed make $(source_version make)"
