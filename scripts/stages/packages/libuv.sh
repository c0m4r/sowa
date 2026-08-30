#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# libuv, the asynchronous I/O library.
#
# It is here for BIND, which requires it and offers no way to build without it:
# every socket named is listening on, and every query dig sends, goes through a
# libuv event loop. BIND 9.20 checks for it through pkg-config and stops if it
# is not there, so this is the first of the three stages that exist only to put
# a dependency in the sysroot ahead of packages/bind.
#
# Two things about the source distribution need saying. libuv ships no
# configure script - the release tarball is the git tree, and autogen.sh
# generates one - so this stage needs the autotools on the build host, the way
# packages/mtr does. And autogen.sh writes into the directory it runs in, which
# is why the checksum-verified source is copied and the copy is built: the
# unpacked source under work/sources is shared with every later build and has
# to stay as it was unpacked.
#
# Building in that copy rather than beside it is also what keeps the build path
# out of the library. libuv's assertions quote __FILE__ and its build system
# never defines NDEBUG, so an out-of-tree build would spell every one of those
# paths absolutely and pkg_merge would reject the result. NDEBUG is defined
# here anyway - a release build of a library should not be checking its own
# invariants at every call - which removes the strings rather than shortening
# them.

require_command libtoolize
require_command aclocal
require_command autoconf
require_command automake

libuv_source="$(prepare_source libuv)"
build_tree="${BUILD_DIR}/libuv"
reset_build_dir "${build_tree}"
cp -a "${libuv_source}/." "${build_tree}/"
pkgdir="$(pkg_stage libuv)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# autogen.sh runs libtoolize, aclocal, autoconf and automake in that order. It
# has to run before target_configure_env's CC matters, and it does: none of
# those four compiles anything.
./autogen.sh
export CPPFLAGS="-DNDEBUG"
./configure \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-static \
    --disable-silent-rules
# libuv has no --disable-rpath, so the generated libtool is edited instead.
# Left alone it records RUNPATH=/usr/lib64 in the library, which is the
# loader's own default search path said twice.
sed -i -e 's|^hardcode_libdir_flag_spec=.*|hardcode_libdir_flag_spec=""|' \
    -e 's|^runpath_var=LD_RUN_PATH|runpath_var=|' libtool
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

# libtool leaves a .la beside the library. There is no libtool on the target to
# read it, and it names the staging directory by absolute path.
rm -f "${pkgdir}"/usr/lib64/*.la

library="$(find "${pkgdir}/usr/lib64" -type f -name 'libuv.so.1*' -print -quit)"
[[ -n "${library}" ]] || die "the libuv shared library was not installed"
"${TARGET}-strip" "${library}"

for link in libuv.so libuv.so.1; do
    [[ -L "${pkgdir}/usr/lib64/${link}" ]] \
        || die "the ${link} symbolic link is missing; nothing could link against libuv"
done
[[ ! -e "${pkgdir}/usr/lib64/libuv.a" ]] \
    || die "libuv installed a static library; the image ships none"
[[ -f "${pkgdir}/usr/include/uv.h" ]] || die "uv.h was not installed"
# BIND finds this library through pkg-config and nothing else, so a missing or
# misdirected .pc file is a build that stops three stages later.
pkgconfig_file="${pkgdir}/usr/lib64/pkgconfig/libuv.pc"
[[ -f "${pkgconfig_file}" ]] || die "the libuv pkg-config file was not installed"
grep -q '^libdir=/usr/lib64$' "${pkgconfig_file}" \
    || die "libuv.pc does not point at /usr/lib64"
# BIND 9.20 asks for libuv >= 1.37.0. The .pc file is where that comparison is
# made, so the version in it is worth reading back rather than assuming.
libuv_version="$(source_version libuv)"
grep -qx "Version: ${libuv_version}" "${pkgconfig_file}" \
    || die "libuv.pc does not declare version ${libuv_version}"
"${TARGET}-readelf" -d "${library}" | grep -q 'SONAME.*libuv\.so\.1' \
    || die "libuv carries no soname; nothing could record a dependency on it"
# The entry point of the event loop, read back from the library: a libuv that
# does not export this is not one BIND can be linked against.
"${TARGET}-nm" -D --defined-only "${library}" | grep -qE ' T uv_run(@|$)' \
    || die "libuv does not export uv_run"
if "${TARGET}-readelf" -d "${library}" | grep -qE 'RPATH|RUNPATH'; then
    die "libuv carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${library}" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "libuv was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "libuv installed files containing the build path: ${leaked}"
pkg_merge libuv
log "installed libuv ${libuv_version}"
