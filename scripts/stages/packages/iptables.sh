#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

iptables_source="$(prepare_source iptables)"
build_tree="${BUILD_DIR}/iptables"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage iptables)"

build_triplet="$(sh "${iptables_source}/build-aux/config.guess")"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
# The legacy setsockopt interface, not the nftables one: iptables-nft needs
# libmnl and libnftnl in the image and nf_tables in the kernel, where the legacy
# tables need neither. CONFIG_NETFILTER_XTABLES_LEGACY and the *_IPTABLES_LEGACY
# tables in config/kernel-x86_64.fragment are the other half of this decision.
# libnfnetlink and libnetfilter_conntrack are likewise absent from the sysroot,
# so the connlabel extension is turned off by name rather than by detection.
"${iptables_source}/configure" \
    --prefix=/usr \
    --sbindir=/usr/sbin \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --mandir=/usr/share/man \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-xtlibdir=/usr/lib64/xtables \
    --disable-nftables \
    --disable-libnfnetlink \
    --disable-connlabel \
    --disable-static
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

# The multicall binary sits beside the symbolic links that select its personality
# and beside iptables-apply, which is a shell script.
while IFS= read -r program; do
    "${TARGET}-readelf" -h "${program}" > /dev/null 2>&1 || continue
    "${TARGET}-strip" "${program}"
done < <(find "${pkgdir}/usr/sbin" "${pkgdir}/usr/lib64" -type f)

[[ -x "${pkgdir}/usr/sbin/xtables-legacy-multi" ]] \
    || die "iptables did not install the legacy multicall binary"
for name in iptables iptables-save iptables-restore ip6tables ip6tables-save \
    ip6tables-restore; do
    [[ -L "${pkgdir}/usr/sbin/${name}" ]] \
        || die "iptables did not link ${name} to the legacy multicall binary"
done
libxtables="$(find "${pkgdir}/usr/lib64" -maxdepth 1 -type f \
    -name 'libxtables.so.*' -print -quit)"
[[ -n "${libxtables}" ]] || die "libxtables was not installed"
[[ -n "$(find "${pkgdir}/usr/lib64/xtables" -name 'libxt_*.so' -print -quit)" ]] \
    || die "the xtables extensions were not installed"
# These parse the matches used by Sowa's default IPv4 and IPv6 rules: conntrack
# state, the TCP port for SSH, the UDP port DHCPv6 replies arrive on, and the
# two ICMP personalities, which ip6tables loads implicitly for "-p ipv6-icmp".
for extension in libxt_conntrack.so libxt_tcp.so libxt_udp.so libipt_icmp.so \
    libip6t_icmp6.so; do
    [[ -f "${pkgdir}/usr/lib64/xtables/${extension}" ]] \
        || die "iptables did not install ${extension}, which the default firewall needs"
done
# A build that had found libnftnl would install the nft personality as well, and
# this kernel has no nf_tables to answer it.
[[ ! -e "${pkgdir}/usr/sbin/xtables-nft-multi" ]] \
    || die "iptables unexpectedly built the nftables personality"
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/xtables-legacy-multi" \
    | grep -q 'libxtables.so'
pkg_merge iptables
log "installed iptables $(source_version iptables)"
