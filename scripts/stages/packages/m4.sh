#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GNU m4, the macro processor autoconf is written in.
#
# This is here for the same reason binutils and GCC are: the image compiles
# programs, and the great majority of what anyone would compile on it arrives as
# an autotools tree. autoconf is useless without m4 - it is not a dependency in
# the ordinary sense but the language its own sources are written in - so the
# two arrive together, m4 first.
#
# m4 has one optional library, libsigsegv, which it uses to turn a stack
# overflow in a deeply recursive macro into a diagnostic instead of a crash.
# The image does not carry it, so it is refused by name rather than left for
# configure to find in the build host's /usr/lib.

m4_source="$(prepare_source m4)"
build_tree="${BUILD_DIR}/m4"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage m4)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
"${m4_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-rpath \
    --without-libsigsegv-prefix
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

[[ -x "${pkgdir}/usr/bin/m4" ]] || die "m4 was not installed"
"${TARGET}-strip" "${pkgdir}/usr/bin/m4"
[[ -f "${pkgdir}/usr/share/man/man1/m4.1" ]] \
    || die "the m4 manual page was not installed"
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/m4" | grep -q 'libsigsegv'; then
    die "m4 links libsigsegv; the image has no such library"
fi
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/m4" | grep -qE 'RPATH|RUNPATH'; then
    die "m4 carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/m4" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "m4 was not built with the cross compiler"
pkg_merge m4
log "installed GNU m4 $(source_version m4)"
