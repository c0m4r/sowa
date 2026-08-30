#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# json-c is a hard dependency of syslog-ng 4.12. It is kept as a shared
# package because syslog-ng's core and loadable JSON module both use it; a
# private archive linked into only one of them would not provide one coherent
# set of json_object symbols to the other.

require_command cmake

source_tree="$(prepare_source json-c)"
build_tree="${BUILD_DIR}/json-c"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage json-c)"

target_configure_env
cmake -S "${source_tree}" -B "${build_tree}" \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="${TARGET}-gcc" \
    -DCMAKE_AR="${TARGET}-ar" \
    -DCMAKE_RANLIB="${TARGET}-ranlib" \
    -DCMAKE_STRIP="${TARGET}-strip" \
    -DCMAKE_FIND_ROOT_PATH="${SYSROOT}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_STATIC_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_APPS=OFF \
    -DENABLE_THREADING=ON \
    -DDISABLE_EXTRA_LIBS=ON \
    -DDISABLE_WERROR=ON
cmake --build "${build_tree}" --parallel "${JOBS}"
DESTDIR="${pkgdir}" cmake --install "${build_tree}"

library="$(find "${pkgdir}/usr/lib64" -maxdepth 1 -type f \
    -name 'libjson-c.so.*' -print -quit)"
[[ -n "${library}" ]] || die "json-c did not install its shared library"
[[ -L "${pkgdir}/usr/lib64/libjson-c.so.5" ]] \
    || die "json-c did not install its ABI soname"
[[ ! -e "${pkgdir}/usr/lib64/libjson-c.a" ]] \
    || die "json-c installed a static library"
[[ -f "${pkgdir}/usr/include/json-c/json.h" ]] \
    || die "json-c did not install json.h"
pkgconfig_file="${pkgdir}/usr/lib64/pkgconfig/json-c.pc"
[[ -f "${pkgconfig_file}" ]] || die "json-c did not install json-c.pc"
grep -qx "Version: $(source_version json-c)" "${pkgconfig_file}" \
    || die "json-c.pc carries the wrong version"

"${TARGET}-strip" --strip-unneeded "${library}"
needed="$("${TARGET}-readelf" -d "${library}")"
while IFS= read -r dependency; do
    case "${dependency}" in
        libm.so.6 | libc.so.6 | ld-linux-x86-64.so.2) ;;
        *) die "json-c needs ${dependency}, which the image does not ship" ;;
    esac
done < <(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' <<< "${needed}")
if grep -qE 'RPATH|RUNPATH' <<< "${needed}"; then
    die "json-c carries a run-time library path"
fi
symbols="$("${TARGET}-nm" -D --defined-only "${library}")"
grep -qE ' T json_tokener_parse(@|$)' <<< "${symbols}" \
    || die "json-c does not export json_tokener_parse"
cross_gcc_version="$("${CC}" -dumpfullversion)"
compiler_comment="$("${TARGET}-readelf" -p .comment "${library}")"
grep -q "GCC: (GNU) ${cross_gcc_version}" <<< "${compiler_comment}" \
    || die "json-c was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "json-c carries a build path: ${leaked}"

pkg_merge json-c
log "installed json-c $(source_version json-c)"
