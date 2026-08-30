#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# ncdu 1.x is the maintained C implementation.  ncdu 2.x needs Zig, which is
# intentionally not part of the host toolchain for this one terminal program.

ncdu_source="$(prepare_source ncdu)"
build_tree="${BUILD_DIR}/ncdu"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage ncdu)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
# ncdu uses pkg-config when it is available.  Without this target-only search
# path it asks the build host for ncursesw, whose flags omit Sowa's separate
# terminfo library; the final link then fails on cbreak(3).  The target .pc
# file supplies both -lncursesw and -ltinfow.
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
"${ncdu_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}"
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

program="${pkgdir}/usr/bin/ncdu"
[[ -x "${program}" ]] || die "ncdu did not install"
"${TARGET}-strip" "${program}"
[[ -f "${pkgdir}/usr/share/man/man1/ncdu.1" ]] \
    || die "ncdu did not install its manual page"
"${TARGET}-readelf" -d "${program}" | grep -q 'libncursesw\.so\.6' \
    || die "ncdu was built without ncurses"
"${TARGET}-readelf" -d "${program}" | grep -q 'libtinfow\.so\.6' \
    || die "ncdu was built without libtinfow"
if "${TARGET}-readelf" -d "${program}" | grep -qE 'RPATH|RUNPATH'; then
    die "ncdu carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${program}" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "ncdu was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "ncdu installed files containing the build path: ${leaked}"
pkg_merge ncdu
log "installed ncdu $(source_version ncdu)"
