#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# The IANA name registries glibc resolves names out of: /etc/services,
# /etc/protocols, /etc/rpc and /etc/ethertypes. Nothing is compiled here - the
# pinned netbase source is four data files and its packaging, and the data files
# are what Sowa wants.
#
# They are not optional the way a manual page is. getaddrinfo(3) accepts a
# service *name* where a port number would do, and resolves it through NSS
# "services", which is "files", which is this file: without it, getaddrinfo
# returns EAI_SERVICE - "Servname not supported for ai_socktype" - before a
# packet is sent. Programs that name a numeric port never notice, which is why
# curl, wget and OpenSSH worked on an image that had no /etc/services at all.
# Guile does not: (guix build download) resolves a URL by handing getaddrinfo
# the URI *scheme*, so every download GNU Guix makes - substitutes and source
# tarballs alike - failed on a Sowa system until this stage existed.
#
# The curated files contain 365 service names that are actually used rather
# than all 11,500 registry entries, which matters in an image loaded into RAM.

source_dir="$(prepare_source netbase)"
version="$(source_version netbase)"
pkgdir="$(pkg_stage netbase)"

install -d -m 0755 "${pkgdir}/etc"
for file in services protocols rpc ethertypes; do
    [[ -s "${source_dir}/etc/${file}" ]] \
        || die "netbase ${version} has no etc/${file}"
    install -m 0644 "${source_dir}/etc/${file}" "${pkgdir}/etc/${file}"
done

# A services file that parses is one thing; one that answers the question the
# system actually asks is another. These are the names Sowa's own programs
# resolve - https for sowa-pkg and Guix, domain for a resolver, ssh for a
# machine that is administered over the network - and a file that had lost any
# of them would be a file that looks installed and does not work.
for entry in 'ssh 22/tcp' 'domain 53/udp' 'domain 53/tcp' 'http 80/tcp' \
    'ntp 123/udp' 'https 443/tcp'; do
    read -r name port <<< "${entry}"
    grep -qE "^${name}[[:space:]]+${port}([[:space:]]|$)" "${pkgdir}/etc/services" \
        || die "netbase ${version} does not map ${name} to ${port}"
done
# The format is "name port/protocol [aliases]", and a line that does not parse
# is a line glibc skips silently, so the whole file is checked rather than the
# handful of entries above.
awk 'NF && $1 !~ /^#/ && $2 !~ /^[0-9]+\/(tcp|udp|ddp|sctp|dccp)$/ {
        printf "unparsable services entry: %s\n", $0 > "/dev/stderr"; bad = 1
     }
     END { exit bad }' "${pkgdir}/etc/services" \
    || die "netbase ${version} has a malformed etc/services"

pkg_merge netbase
log "installed netbase ${version}: $(grep -cvE '^[[:space:]]*(#|$)' \
    "${pkgdir}/etc/services") service names, $(grep -cvE '^[[:space:]]*(#|$)' \
    "${pkgdir}/etc/protocols") protocols"
