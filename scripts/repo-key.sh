#!/usr/bin/env bash
#
# Creates the Ed25519 key pair that signs the binary package repository.
#
# The private half is written outside the checkout, since a key committed to the
# repository it protects secures nothing. The public half is installed into the
# root filesystem overlay, so every image built afterwards can verify an index
# and every image built before it cannot be tricked into accepting one.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_command openssl

readonly PUBLIC_KEY="${REPO_PUBLIC_KEY}"

force=0
case "${1:-}" in
    '') ;;
    --force) force=1 ;;
    *) die "usage: $0 [--force]" ;;
esac

if [[ -f "${REPO_KEY}" && "${force}" != 1 ]]; then
    log "a repository key already exists at ${REPO_KEY}"
    log "its public half belongs at ${PUBLIC_KEY}"
    log "pass --force to replace it, which invalidates every image already built"
    exit 0
fi

if [[ -f "${REPO_KEY}" ]]; then
    log "warning: replacing ${REPO_KEY}; images built with the old public key"
    log "warning: will refuse indexes signed with the new one"
fi

install -d -m 0700 "$(dirname "${REPO_KEY}")"
umask 077
openssl genpkey -algorithm ed25519 -out "${REPO_KEY}.tmp"
mv "${REPO_KEY}.tmp" "${REPO_KEY}"
chmod 0600 "${REPO_KEY}"
umask 022

install -d -m 0755 "$(dirname "${PUBLIC_KEY}")"
openssl pkey -in "${REPO_KEY}" -pubout -out "${PUBLIC_KEY}"
chmod 0644 "${PUBLIC_KEY}"

log "private key: ${REPO_KEY} (back this up; it cannot be recovered)"
log "public key:  ${PUBLIC_KEY} (commit it, then rebuild the image)"
