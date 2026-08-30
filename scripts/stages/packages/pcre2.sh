#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# PCRE2 is a shared package because GLib and syslog-ng both link its 8-bit
# library. Building it once avoids two private copies of the same matching
# engine and makes an ABI/security update invalidate both consumers.

source_tree="$(prepare_source pcre2)"
build_tree="${BUILD_DIR}/pcre2-shared"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage pcre2)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"

"${source_tree}/configure" \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --mandir=/usr/share/man \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --enable-shared \
    --disable-static \
    --enable-pcre2-8 \
    --disable-pcre2-16 \
    --disable-pcre2-32 \
    --enable-unicode \
    --enable-jit \
    --disable-pcre2grep-libz \
    --disable-pcre2grep-libbz2 \
    --disable-pcre2test-libreadline
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

library="$(find "${pkgdir}/usr/lib64" -maxdepth 1 -type f \
    -name 'libpcre2-8.so.*' -print -quit)"
[[ -n "${library}" ]] || die "PCRE2 did not install its shared 8-bit library"
[[ -f "${pkgdir}/usr/lib64/libpcre2-8.so.0" ]] \
    || die "PCRE2 did not install its ABI soname"
[[ -f "${pkgdir}/usr/include/pcre2.h" ]] \
    || die "PCRE2 did not install pcre2.h"
[[ -f "${pkgdir}/usr/lib64/pkgconfig/libpcre2-8.pc" ]] \
    || die "PCRE2 did not install libpcre2-8.pc"

while IFS= read -r shared_library; do
    "${TARGET}-strip" --strip-unneeded "${shared_library}"
done < <(find "${pkgdir}/usr/lib64" -maxdepth 1 -type f -name '*.so.*')
find "${pkgdir}" -name '*.la' -delete
for program in pcre2grep pcre2test; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] \
        || die "PCRE2 did not install ${program}"
    "${TARGET}-strip" "${pkgdir}/usr/bin/${program}"
done

needed="$("${TARGET}-readelf" -d "${library}")"
while IFS= read -r dependency; do
    case "${dependency}" in
        libc.so.6) ;;
        *) die "PCRE2 needs ${dependency}, which the image does not ship" ;;
    esac
done < <(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' <<< "${needed}")
if grep -qE 'RPATH|RUNPATH' <<< "${needed}"; then
    die "PCRE2 carries a run-time library path"
fi
symbols="$("${TARGET}-nm" -D --defined-only "${library}")"
grep -qE ' [TW] pcre2_compile_8(@|$)' <<< "${symbols}" \
    || die "PCRE2 does not export its 8-bit compiler"

cross_gcc_version="$("${CC}" -dumpfullversion)"
compiler_comment="$("${TARGET}-readelf" -p .comment "${library}")"
grep -q "GCC: (GNU) ${cross_gcc_version}" <<< "${compiler_comment}" \
    || die "PCRE2 was not built with the cross compiler"

leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "PCRE2 carries a build path: ${leaked}"

pkg_merge pcre2
log "installed PCRE2 $(source_version pcre2)"
