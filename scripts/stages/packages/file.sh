#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# file(1) and libmagic.
#
# This is built twice. The magic database ships as a directory of text
# fragments and is compiled into the single magic.mgc file that file(1) mmaps
# at startup, and the program that compiles it is file(1) itself - so a cross
# build has to produce a file(1) that runs on the build machine before it can
# produce the database for the one that runs on the target. Upstream's own
# answer is the FILE_COMPILE variable, which the magic Makefile consults
# whenever it is cross-compiling; the host tree below exists only to have
# something to point it at. Nothing from that tree is installed.
#
# The compression libraries are the other half of the stage. file reads inside
# a compressed file to name what is in it, and configure looks for zlib, bzip2,
# xz, zstd and lzip and quietly does without whichever it cannot find. Four of
# those five are in this sysroot and one is not, so all five are answered by
# name rather than left to what the sysroot happens to contain.

file_source="$(prepare_source file)"
pkgdir="$(pkg_stage file)"

# The host pass. Built before target_configure_env is called, so it uses the
# build machine's own compiler and libraries; --disable-shared keeps it from
# producing a libmagic that would have to be found at run time, and every
# optional library is refused because this file(1) never has to read a
# compressed file - it only has to compile magic.
host_tree="${BUILD_DIR}/file-host"
reset_build_dir "${host_tree}"
cd "${host_tree}"
"${file_source}/configure" \
    --disable-shared \
    --disable-zlib \
    --disable-bzlib \
    --disable-xzlib \
    --disable-zstdlib \
    --disable-lzlib \
    --disable-libseccomp \
    --disable-silent-rules
make -j"${JOBS}"
file_compile="${host_tree}/src/file"
[[ -x "${file_compile}" ]] || die "the host file(1) was not built; magic.mgc needs it"
# Ask it rather than trust the build: this binary has to run here, and its whole
# purpose is to be executed by the target build a moment from now.
"${file_compile}" --version >/dev/null \
    || die "the host file(1) does not run on this machine"

build_tree="${BUILD_DIR}/file"
reset_build_dir "${build_tree}"
# Built in a copy of the source rather than beside it, for the reason the wget
# stage is: libmagic reports an internal error with __FILE__, and an out-of-tree
# build - where configure spells srcdir absolutely - compiles the builder's home
# directory into five of the object files. In tree those paths are relative.
cp -a "${file_source}/." "${build_tree}/"
build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# --disable-libseccomp is not a preference. The sandbox file(1) installs around
# itself is compiled from a syscall list, and the image has no libseccomp to
# link in any case; leaving it to autodetection would make the result depend on
# whether the build host has the development headers.
./configure \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-static \
    --disable-silent-rules \
    --enable-zlib \
    --enable-bzlib \
    --enable-xzlib \
    --enable-zstdlib \
    --disable-lzlib \
    --disable-libseccomp
# file has no --disable-rpath, so the libtool configure generated is edited
# instead. Left alone it records RUNPATH=/usr/lib64 in everything it links,
# which is both redundant - that is the loader's own default search path - and
# the kind of thing that later shadows a library the image meant to override.
sed -i -e 's|^hardcode_libdir_flag_spec=.*|hardcode_libdir_flag_spec=""|' \
    -e 's|^runpath_var=LD_RUN_PATH|runpath_var=|' libtool
make -j"${JOBS}" FILE_COMPILE="${file_compile}"
make DESTDIR="${pkgdir}" FILE_COMPILE="${file_compile}" install

[[ -x "${pkgdir}/usr/bin/file" ]] || die "file was not installed"
"${TARGET}-strip" "${pkgdir}/usr/bin/file"
find "${pkgdir}/usr/lib64" -name 'libmagic.so.*.*' -exec "${TARGET}-strip" {} +
# The database is the package. A file(1) without it starts and then calls every
# input "data", which is a failure that looks like an answer.
magic_db="${pkgdir}/usr/share/misc/magic.mgc"
[[ -s "${magic_db}" ]] || die "magic.mgc was not compiled; file would identify nothing"
[[ -f "${pkgdir}/usr/share/man/man1/file.1" ]] \
    || die "the file manual page was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/file" | grep -q 'libmagic.so' \
    || die "file is not linked against the shared libmagic"
for required in libz.so.1 libbz2.so.1 liblzma.so.5 libzstd.so.1; do
    "${TARGET}-readelf" -d "${pkgdir}/usr/lib64/libmagic.so" \
        | grep -q "${required}" \
        || die "libmagic was built without ${required}; it could not read inside a compressed file"
done
for unwanted in liblz.so libseccomp; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/lib64/libmagic.so" | grep -q "${unwanted}"; then
        die "libmagic links ${unwanted}; the image has no such library"
    fi
done
for linked in usr/bin/file usr/lib64/libmagic.so; do
    if "${TARGET}-readelf" -d "${pkgdir}/${linked}" | grep -qE 'RPATH|RUNPATH'; then
        die "/${linked} carries a run-time library path"
    fi
done
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/file" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "file was not built with the cross compiler"
# The host tree's paths reach the target build through FILE_COMPILE, so check
# that none of them were written into anything being shipped.
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "file installed files containing the build path: ${leaked}"
pkg_merge file
log "installed file $(source_version file)"
