#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# bzip2 and bunzip2, and libbz2, which unzip is then built against so it can
# read bzip2-compressed zip members.
#
# bzip2 has no configure script and its Makefile hardcodes "gcc", so the cross
# compiler is passed on the command line and the shared library is built by the
# second makefile upstream ships for it. The default "all" target runs the test
# suite, which would execute freshly cross-compiled target binaries on the build
# host; the programs are therefore named explicitly instead.

bzip2_source="$(prepare_source bzip2)"
build_tree="${BUILD_DIR}/bzip2"
reset_build_dir "${build_tree}"
cp -a "${bzip2_source}/." "${build_tree}/"
pkgdir="$(pkg_stage bzip2)"

version="$(source_version bzip2)"
target_configure_env
cd "${build_tree}"

# The shared library first: its makefile also links a bzip2 against it, which is
# the binary the image ships, so that a fix in libbz2 reaches bzip2 too.
make -f Makefile-libbz2_so -j"${JOBS}" CC="${CC}" \
    CFLAGS="-Wall -Winline -O2 -g -D_FILE_OFFSET_BITS=64 -fPIC"
make -j"${JOBS}" CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" \
    libbz2.a bzip2 bzip2recover
make install PREFIX="${pkgdir}/usr"

# bzip2's makefile predates both conventions the rest of the image follows: it
# knows only $(PREFIX)/lib for libraries and $(PREFIX)/man for manual pages,
# where Sowa has /usr/lib64 and /usr/share/man.
install -d -m 0755 "${pkgdir}/usr/lib64"
mv "${pkgdir}/usr/lib/libbz2.a" "${pkgdir}/usr/lib64/libbz2.a"
rmdir "${pkgdir}/usr/lib"
install -d -m 0755 "${pkgdir}/usr/share"
mv "${pkgdir}/usr/man" "${pkgdir}/usr/share/man"
install -m 0755 "libbz2.so.${version}" "${pkgdir}/usr/lib64/libbz2.so.${version}"
ln -s "libbz2.so.${version}" "${pkgdir}/usr/lib64/libbz2.so.1.0"
ln -s libbz2.so.1.0 "${pkgdir}/usr/lib64/libbz2.so.1"
ln -s libbz2.so.1.0 "${pkgdir}/usr/lib64/libbz2.so"
# The statically linked bzip2 the plain makefile produced is replaced by the
# one linked against that library.
install -m 0755 bzip2-shared "${pkgdir}/usr/bin/bzip2"
ln -sf bzip2 "${pkgdir}/usr/bin/bunzip2"
ln -sf bzip2 "${pkgdir}/usr/bin/bzcat"

"${TARGET}-strip" "${pkgdir}/usr/bin/bzip2" "${pkgdir}/usr/bin/bzip2recover" \
    "${pkgdir}/usr/lib64/libbz2.so.${version}"
for program in bzip2 bunzip2 bzcat bzip2recover bzdiff bzgrep bzmore; do
    [[ -e "${pkgdir}/usr/bin/${program}" ]] || die "bzip2 did not install ${program}"
done
[[ -f "${pkgdir}/usr/include/bzlib.h" ]] || die "bzlib.h was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/bzip2" | grep -q 'libbz2.so.1.0' \
    || die "the installed bzip2 is not the one linked against libbz2"
"${TARGET}-readelf" -d "${pkgdir}/usr/lib64/libbz2.so.${version}" | grep -q 'libc.so.6'
"${TARGET}-readelf" -h "${pkgdir}/usr/bin/bzip2" \
    | grep -q 'Advanced Micro Devices X86-64' \
    || die "bzip2 was not built for the target architecture"
pkg_merge bzip2
log "installed bzip2 ${version}"
