#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

grep_source="$(prepare_source grep)"
build_tree="${BUILD_DIR}/grep"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage grep)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# "grep -P" is refused rather than left to chance: PCRE2 is built inside the
# nginx stage as a private static library and is not part of the image, so a
# grep that had found one would be a grep the repository could not reproduce.
"${grep_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-perl-regexp \
    --without-libsigsegv
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/bin/grep"
[[ -x "${pkgdir}/usr/bin/grep" ]] || die "grep was not installed"
# egrep and fgrep are shipped as the wrapper scripts upstream now installs; they
# print a deprecation warning and call grep, which is what the manual describes.
for program in egrep fgrep; do
    [[ -f "${pkgdir}/usr/bin/${program}" ]] || die "grep did not install ${program}"
done
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/grep" | grep -q 'libc.so.6'
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/grep" | grep -q 'libpcre'; then
    die "grep links PCRE2; the image has no such library"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/grep" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "grep was not built with the cross compiler"
pkg_merge grep
log "installed grep $(source_version grep)"
