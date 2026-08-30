#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

require_command perl
curl_source="$(prepare_source curl)"
build_tree="${BUILD_DIR}/curl"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage curl)"

build_triplet="$(sh "${curl_source}/config.guess")"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
"${curl_source}/configure" \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-openssl="${SYSROOT}/usr" \
    --with-zlib \
    --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
    --without-ca-path \
    --without-brotli \
    --without-zstd \
    --without-libpsl \
    --without-libidn2 \
    --without-nghttp2 \
    --without-libssh2 \
    --without-libssh \
    --without-libgsasl \
    --disable-ldap \
    --disable-ldaps \
    --disable-docs \
    --disable-manual
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

# pkg-config must expose the sysroot while linking, but its absolute build path
# must not survive in target development metadata.
metadata_files=(
    "${pkgdir}/usr/bin/curl-config"
    "${pkgdir}/usr/lib64/libcurl.la"
    "${pkgdir}/usr/lib64/pkgconfig/libcurl.pc"
)
CURL_BUILD_SYSROOT="${SYSROOT}" perl -pi -e \
    's/\Q$ENV{CURL_BUILD_SYSROOT}\E//g' "${metadata_files[@]}"

libcurl="$(find "${pkgdir}/usr/lib64" -type f -name 'libcurl.so.*' -print -quit)"
[[ -n "${libcurl}" ]] || die "libcurl shared library was not installed"
"${TARGET}-strip" "${pkgdir}/usr/bin/curl" "${libcurl}"

[[ -x "${pkgdir}/usr/bin/curl" ]] || die "curl was not installed"
[[ -f "${pkgdir}/usr/include/curl/curl.h" ]] || die "curl headers were not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/curl" | grep -q 'libcurl.so.4'
"${TARGET}-readelf" -d "${libcurl}" | grep -q 'libssl.so.3'
"${TARGET}-readelf" -d "${libcurl}" | grep -q 'libcrypto.so.3'
"${TARGET}-readelf" -d "${libcurl}" | grep -q 'libz.so.1'
if grep -Fq "${SYSROOT}" "${metadata_files[@]}"; then
    die "curl development metadata contains the build sysroot"
fi
pkg_merge curl
log "installed curl $(source_version curl)"
