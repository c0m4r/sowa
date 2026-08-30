#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

libxcrypt_source="$(prepare_source libxcrypt)"
build_tree="${BUILD_DIR}/libxcrypt"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage libxcrypt)"

build_triplet="$(sh "${libxcrypt_source}/build-aux/m4-autogen/config.guess")"
target_configure_env
cd "${build_tree}"
# glibc 2.44 no longer builds libcrypt, so crypt(3) comes from libxcrypt.
# sha512crypt reads the $6$ tokens shadow's passwd writes; yescrypt and bcrypt cover
# anything that grows them later, with yescrypt the gensalt default. The hash
# set is listed explicitly rather than through the "strong" keyword: that group
# also drags in the gost_yescrypt and sm3_yescrypt national variants, which
# nothing here needs and which do not compile under GCC 16 with upstream's
# -Werror. Nothing in the image was ever linked against glibc's libcrypt.so.1,
# so the obsolete ABI is left out and only libcrypt.so.2 is installed.
"${libxcrypt_source}/configure" \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --enable-hashes=yescrypt,bcrypt,bcrypt_a,bcrypt_y,sha512crypt,sha256crypt,md5crypt \
    --enable-obsolete-api=no \
    --disable-static \
    --disable-failure-tokens \
    --disable-valgrind
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

library="$(find "${pkgdir}/usr/lib64" -type f -name 'libcrypt.so.2*' -print -quit)"
[[ -n "${library}" ]] || die "libxcrypt shared library was not installed"
"${TARGET}-strip" "${library}"

[[ -f "${pkgdir}/usr/include/crypt.h" ]] || die "crypt.h was not installed"
"${TARGET}-readelf" -d "${library}" | grep -q 'libc.so.6'
"${TARGET}-nm" -D --defined-only "${library}" | grep -qE ' T crypt(@|$)'
pkg_merge libxcrypt
log "installed libxcrypt $(source_version libxcrypt)"
