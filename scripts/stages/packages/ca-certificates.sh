#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

require_command openssl
bundle="$(locked_download_path ca-certificates)"
certificate_count="$(grep -c '^-----BEGIN CERTIFICATE-----$' "${bundle}")"
((certificate_count > 0)) || die "Mozilla CA bundle contains no certificates"
openssl crl2pkcs7 -nocrl -certfile "${bundle}" \
    | openssl pkcs7 -print_certs -noout >/dev/null

pkgdir="$(pkg_stage ca-certificates)"
install -d -m 0755 "${pkgdir}/etc/ssl/certs"
install -m 0644 "${bundle}" "${pkgdir}/etc/ssl/certs/ca-certificates.crt"
ln -sfn certs/ca-certificates.crt "${pkgdir}/etc/ssl/cert.pem"
ln -sfn ca-certificates.crt "${pkgdir}/etc/ssl/certs/ca-bundle.crt"

[[ -s "${pkgdir}/etc/ssl/certs/ca-certificates.crt" ]] \
    || die "Mozilla CA bundle was not installed"
[[ -L "${pkgdir}/etc/ssl/cert.pem" ]] \
    || die "OpenSSL default CA bundle link was not installed"
pkg_merge ca-certificates
log "installed ${certificate_count} Mozilla CA certificates ($(source_version ca-certificates))"
