#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

require_command perl
openssl_source="$(prepare_source openssl)"
build_tree="${BUILD_DIR}/openssl"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage openssl)"

cd "${build_tree}"
perl "${openssl_source}/Configure" linux-x86_64 \
    --prefix=/usr \
    --openssldir=/etc/ssl \
    --libdir=lib64 \
    --cross-compile-prefix="${TARGET}-" \
    shared \
    no-docs \
    no-tests
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install_sw install_ssldirs

"${TARGET}-strip" "${pkgdir}/usr/bin/openssl"
"${TARGET}-strip" "${pkgdir}/usr/lib64/libcrypto.so.3" \
    "${pkgdir}/usr/lib64/libssl.so.3"
while IFS= read -r library; do
    "${TARGET}-strip" "${library}"
done < <(find "${pkgdir}/usr/lib64/engines-3" \
    "${pkgdir}/usr/lib64/ossl-modules" -type f -name '*.so' -print)

[[ -x "${pkgdir}/usr/bin/openssl" ]] || die "OpenSSL was not installed"
[[ -f "${pkgdir}/usr/lib64/libcrypto.so.3" ]] \
    || die "OpenSSL libcrypto shared library was not installed"
[[ -f "${pkgdir}/usr/lib64/libssl.so.3" ]] \
    || die "OpenSSL libssl shared library was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/openssl" | grep -q 'libssl.so.3'
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/openssl" | grep -q 'libcrypto.so.3'
pkg_merge openssl
log "installed OpenSSL $(source_version openssl)"
