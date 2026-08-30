#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

diffutils_source="$(prepare_source diffutils)"
build_tree="${BUILD_DIR}/diffutils"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage diffutils)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# The gnulib copy in diffutils 3.12 works out a cross-compilation guess for
# strcasecmp ("guessing yes" everywhere but Solaris and Cygwin) and then aborts
# with "cannot run test program while cross compiling" before it ever uses it.
# The answer for glibc is stated here instead; it is the same one the macro
# would have guessed.
gl_cv_func_strcasecmp_works=yes \
"${diffutils_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --without-libsigsegv
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

for program in cmp diff diff3 sdiff; do
    "${TARGET}-strip" "${pkgdir}/usr/bin/${program}"
    [[ -x "${pkgdir}/usr/bin/${program}" ]] \
        || die "diffutils did not install ${program}"
done
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/diff" | grep -q 'libc.so.6'
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/diff" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "diff was not built with the cross compiler"
pkg_merge diffutils
log "installed diffutils $(source_version diffutils)"
