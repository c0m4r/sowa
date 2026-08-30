#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# XZ Utils: xz and liblzma, plus the lzma-compatible names that are the only
# thing left of LZMA Utils, which is where the image's "lzma" comes from.

xz_source="$(prepare_source xz)"
build_tree="${BUILD_DIR}/xz"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage xz)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# The static library is left out for the same reason the rest of the image has
# none: nothing links one, and a second copy of the compressor is not free.
"${xz_source}/configure" \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-static \
    --disable-doc \
    --enable-threads=posix
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/bin/xz" "${pkgdir}/usr/bin/xzdec" \
    "${pkgdir}/usr/bin/lzmadec" "${pkgdir}/usr/bin/lzmainfo"
find "${pkgdir}/usr/lib64" -name 'liblzma.so.*.*' -exec "${TARGET}-strip" {} +

[[ -x "${pkgdir}/usr/bin/xz" ]] || die "xz was not installed"
# The compatibility names are what makes this package "lzma" as well as "xz",
# and the scripts are what a shell reaches for.
for program in unxz xzcat lzma unlzma lzcat; do
    [[ -e "${pkgdir}/usr/bin/${program}" ]] || die "xz did not install ${program}"
done
for script in xzdiff xzgrep xzless xzmore lzdiff lzgrep lzless lzmore; do
    [[ -x "${pkgdir}/usr/bin/${script}" ]] || die "xz did not install ${script}"
done
[[ -f "${pkgdir}/usr/lib64/liblzma.so.5" || -L "${pkgdir}/usr/lib64/liblzma.so.5" ]] \
    || die "liblzma was not installed"
[[ -f "${pkgdir}/usr/include/lzma.h" ]] || die "lzma.h was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/xz" | grep -q 'liblzma.so.5' \
    || die "xz is not linked against the shared liblzma"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/xz" | grep -q 'libpthread\|libc.so.6'
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/xz" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "xz was not built with the cross compiler"
pkg_merge xz
log "installed XZ Utils $(source_version xz)"
