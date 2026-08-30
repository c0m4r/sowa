#!/usr/bin/env bash
#
# Creates the Ed25519 key pair that signs release artifact manifests.
#
# This is deliberately not the package-repository key. Repository metadata is
# short-lived and signed whenever packages are published; a release key is the
# offline root for ISO, installer, disk and rootfs artifacts that may be copied
# between mirrors for years. Compromising one must not compromise the other.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_command openssl
require_command readlink

readonly RELEASE_PRIVATE_KEY="${RELEASE_KEY:-${HOME}/.config/sowa/release-ed25519.key}"
readonly RELEASE_PUBLIC="${RELEASE_PUBLIC_KEY:-${PROJECT_ROOT}/keys/sowa-release.pub}"

force=0
case "${1:-}" in
    '') ;;
    --force) force=1 ;;
    *) die "usage: $0 [--force]" ;;
esac

private_real="$(readlink -m -- "${RELEASE_PRIVATE_KEY}")"
public_real="$(readlink -m -- "${RELEASE_PUBLIC}")"
case "${private_real}/" in
    "${PROJECT_ROOT}/"*)
        die "the release private key must live outside the checkout: ${RELEASE_PRIVATE_KEY}"
        ;;
esac
[[ "${private_real}" != "${public_real}" ]] \
    || die "the release private and public key paths must be different"

install_public_half() {
    local temporary="${RELEASE_PUBLIC}.tmp.$$"
    install -d -m 0755 "$(dirname -- "${RELEASE_PUBLIC}")"
    openssl pkey -in "${RELEASE_PRIVATE_KEY}" -pubout -out "${temporary}"
    chmod 0644 "${temporary}"
    mv "${temporary}" "${RELEASE_PUBLIC}"
}

public_matches_private() {
    cmp -s <(openssl pkey -in "${RELEASE_PRIVATE_KEY}" -pubout) \
        "${RELEASE_PUBLIC}"
}

if [[ -e "${RELEASE_PRIVATE_KEY}" || -L "${RELEASE_PRIVATE_KEY}" ]]; then
    [[ -f "${RELEASE_PRIVATE_KEY}" && ! -L "${RELEASE_PRIVATE_KEY}" ]] \
        || die "the release private key is not a regular file: ${RELEASE_PRIVATE_KEY}"
    if ((force == 0)); then
        chmod 0600 "${RELEASE_PRIVATE_KEY}"
        if [[ ! -e "${RELEASE_PUBLIC}" && ! -L "${RELEASE_PUBLIC}" ]]; then
            install_public_half
        else
            [[ -f "${RELEASE_PUBLIC}" && ! -L "${RELEASE_PUBLIC}" ]] \
                || die "the release public key is not a regular file: ${RELEASE_PUBLIC}"
            public_matches_private \
                || die "${RELEASE_PUBLIC} does not belong to ${RELEASE_PRIVATE_KEY}; pass --force only if rotating both"
        fi
        log "a release key already exists at ${RELEASE_PRIVATE_KEY}"
        log "its matching public half is at ${RELEASE_PUBLIC}"
        exit 0
    fi
    log "warning: replacing ${RELEASE_PRIVATE_KEY} and ${RELEASE_PUBLIC}"
    log "warning: old release manifests will need the old public key forever"
elif [[ -e "${RELEASE_PUBLIC}" || -L "${RELEASE_PUBLIC}" ]]; then
    ((force == 1)) \
        || die "${RELEASE_PUBLIC} exists without its private key; restore the private key or pass --force to rotate"
fi

install -d -m 0700 "$(dirname -- "${RELEASE_PRIVATE_KEY}")"
private_temporary="${RELEASE_PRIVATE_KEY}.tmp.$$"
trap 'rm -f "${private_temporary}"' EXIT
umask 077
openssl genpkey -algorithm ed25519 -out "${private_temporary}"
mv "${private_temporary}" "${RELEASE_PRIVATE_KEY}"
chmod 0600 "${RELEASE_PRIVATE_KEY}"
umask 022
trap - EXIT

install_public_half
public_matches_private || die "the generated release key pair does not match"

fingerprint="$(openssl pkey -pubin -in "${RELEASE_PUBLIC}" -outform DER \
    | sha256sum | cut -d' ' -f1)"
log "private key: ${RELEASE_PRIVATE_KEY} (keep offline and back it up)"
log "public key:  ${RELEASE_PUBLIC} (commit and publish independently)"
log "fingerprint: sha256:${fingerprint}"
