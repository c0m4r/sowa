#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

nic_source="$(prepare_source nic)"
nic_version="$(source_version nic)"
build_tree="${BUILD_DIR}/nic"
reset_build_dir "${build_tree}"
cp -a "${nic_source}/." "${build_tree}/"
pkgdir="$(pkg_stage nic)"

# nic is Go with no module dependencies, and the only Go program the image still
# carries. It is built static, with the build identity and paths trimmed out,
# and with the module proxy shut off so the build cannot reach the network for
# something the lock did not pin.
# Upstream's Makefile does the same thing, but its ldflags leave the build ID
# in, so the go build line is spelled out here instead.
go_cache="${BUILD_DIR}/go-cache"
mkdir -p "${go_cache}"
(
    cd "${build_tree}"
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH="${GOARCH}" \
    GOCACHE="${go_cache}" \
    GOTOOLCHAIN=local \
    GOPROXY=off \
    go build -buildvcs=false -mod=readonly -trimpath \
        -ldflags="-s -w -buildid= -X main.version=${nic_version}" \
        -o nic .
)

install -D -m 0755 "${build_tree}/nic" "${pkgdir}/usr/sbin/nic"
# The shipped configuration is Sowa's own, not upstream's example: it restores
# the default IPv4 and IPv6 firewall policies, brings eth0 up and asks for an
# IPv4 lease. It is private because a WiFi password would live in it.
install -D -m 0600 "${PROJECT_ROOT}/config/nic.conf" "${pkgdir}/etc/nic.conf"
install -D -m 0644 "${PROJECT_ROOT}/config/nic.rules.v4" \
    "${pkgdir}/etc/nic.rules.v4"
install -D -m 0644 "${PROJECT_ROOT}/config/nic.rules.v6" \
    "${pkgdir}/etc/nic.rules.v6"
# The configuration ends with "include nic.d/*.conf", so the directory has to
# exist; the examples for it are documentation, not configuration, and are
# installed as such. Upstream's own nic.conf goes with them: it is the annotated
# reference for every form the shipped one does not use.
install -d -m 0755 "${pkgdir}/etc/nic.d"
install -D -m 0644 "${build_tree}/README.md" "${pkgdir}/usr/share/doc/nic/README.md"
install -D -m 0644 "${build_tree}/examples/nic.conf" \
    "${pkgdir}/usr/share/doc/nic/nic.conf"
install -D -m 0644 "${build_tree}/examples/complex.conf" \
    "${pkgdir}/usr/share/doc/nic/complex.conf"
for family in v4 v6; do
    install -D -m 0644 "${build_tree}/examples/nic.rules.${family}" \
        "${pkgdir}/usr/share/doc/nic/nic.rules.${family}"
done
while IFS= read -r example; do
    install -D -m 0644 "${example}" \
        "${pkgdir}/usr/share/doc/nic/nic.d/$(basename "${example}")"
done < <(find "${build_tree}/examples/nic.d" -type f -name '*.conf' -print)

[[ -x "${pkgdir}/usr/sbin/nic" ]] || die "nic was not installed"
[[ -f "${pkgdir}/etc/nic.conf" ]] || die "the nic configuration was not installed"
for family in v4 v6; do
    [[ -f "${pkgdir}/etc/nic.rules.${family}" ]] \
        || die "the IPv${family#v} firewall rules were not installed"
done
[[ "$(stat -c '%a' "${pkgdir}/etc/nic.conf")" == 600 ]] \
    || die "/etc/nic.conf must not be world readable; it can hold a WiFi password"
# The configuration is ours, so nothing upstream keeps it parseable across a
# version bump. The new firewall directives read their files while parsing;
# point a temporary validation copy at the staged files rather than at the
# build host's /etc.
validation_config="${build_tree}/nic.sowa.conf"
sed -e "s|/etc/nic.rules.v4|${pkgdir}/etc/nic.rules.v4|" \
    -e "s|/etc/nic.rules.v6|${pkgdir}/etc/nic.rules.v6|" \
    "${pkgdir}/etc/nic.conf" > "${validation_config}"
"${build_tree}/nic" show --config="${validation_config}" > /dev/null \
    || die "the shipped /etc/nic.conf is not valid for nic ${nic_version}"
"${TARGET}-readelf" -h "${pkgdir}/usr/sbin/nic" | grep -q 'Advanced Micro Devices X86-64' \
    || die "nic was not built for the target architecture"
if "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/nic" 2>/dev/null | grep -q 'NEEDED'; then
    die "nic is dynamically linked; it is meant to be a static binary"
fi
pkg_merge nic
log "installed nic ${nic_version}"
