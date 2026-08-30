#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# OpenVPN, the TLS-based VPN. It is the older of the two tunnels the image
# carries and the one that is entirely userspace: the kernel provides
# /dev/net/tun and nothing else, and everything above it - the handshake, the
# key exchange, the data channel - happens in this daemon. That is what makes
# it worth having next to WireGuard rather than instead of it. It speaks to
# every existing OpenVPN server, it runs over TCP as well as UDP, it can be
# pushed routes and DNS by the peer, and it authenticates with X.509 rather
# than with a public key that has to be exchanged out of band.
#
# The cost is a much larger program with much more to configure, and a data
# path that crosses into userspace and back for every packet.

openvpn_source="$(prepare_source openvpn)"
build_tree="${BUILD_DIR}/openvpn"
reset_build_dir "${build_tree}"
# Built in a copy of the source rather than beside it. OpenVPN's ASSERT and its
# debug messages carry __FILE__, so an out-of-tree build - where configure
# spells srcdir absolutely - would put the builder's home directory into
# /usr/sbin/openvpn. In-tree those paths are relative, which is also how chrony,
# Git and Wget are built.
cp -a "${openvpn_source}/." "${build_tree}/"
pkgdir="$(pkg_stage openvpn)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"

# The switches, in the order they matter.
#
# --with-crypto-library=openssl picks the backend the rest of the image already
# links. mbedTLS and wolfSSL are the alternatives and would each mean a second
# TLS stack in a distribution that has settled on one.
#
# --disable-dco turns off data channel offload. It is on by default on Linux
# and would be the faster path - the kernel's ovpn module moving packets
# without waking the daemon - but it is reached through libnl-genl-3, which is
# a library the sysroot does not have and which exists for nothing else. This
# is the one switch here that gives something up rather than declining what the
# image cannot use, and it is the line to revisit if libnl is ever packaged.
#
# --disable-lzo and --disable-lz4 refuse the two compression libraries. Neither
# is in the sysroot, and link-layer compression inside a TLS tunnel is what
# VORACLE attacks; upstream has deprecated it and disables it by default at
# both ends. A peer that insists on it can still be met with --comp-lzo stub.
#
# --disable-plugin-auth-pam drops the one plugin that needs a library the image
# does not have. The down-root plugin is kept: it needs nothing, and it is what
# lets a tunnel started as root run its --down script after --user has dropped
# privilege.
#
# --disable-dns-updown-by-default stops the daemon from running a DNS hook for
# every server that pushes a resolver. Upstream picks the hook by platform, and
# on Linux that is unconditionally the systemd-resolved script; the image has
# no systemd-resolved and no resolvconf, so the default has to be off. The
# script itself is removed below rather than shipped dead.
#
# --disable-unit-tests declines the cmocka suite, which is not in the sysroot,
# and which a cross build could not run in any case.
#
# RST2MAN and RST2HTML are pinned empty so configure does not find the host's
# docutils and regenerate openvpn.8 from its reStructuredText sources. The
# tarball ships the built manual pages; regenerating them would make the
# package depend on what the builder happens to have installed.
#
# IFCONFIG, ROUTE and IPROUTE are pinned for the same reason from the other
# direction: configure looks for those three programs on the build host and
# compiles the paths it finds into the binary. This build uses sitnl - OpenVPN
# talks to the kernel over netlink and calls none of them - but host-specific
# paths have no business inside a Sowa binary.
RST2MAN='' RST2HTML='' \
    IFCONFIG=/usr/sbin/ifconfig \
    ROUTE=/usr/sbin/route \
    IPROUTE=/usr/sbin/ip \
    SYSTEMD_ASK_PASSWORD='' \
    ./configure \
    --prefix=/usr \
    --sbindir=/usr/sbin \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --docdir=/usr/share/doc/openvpn \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-crypto-library=openssl \
    --disable-dco \
    --disable-lzo \
    --disable-lz4 \
    --disable-plugin-auth-pam \
    --disable-dns-updown-by-default \
    --disable-unit-tests \
    --disable-static
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

# The DNS hook upstream installs on Linux drives systemd-resolved through
# resolvectl and busctl. Neither is in the image and neither ever will be, so
# the script would be a program that cannot run, reachable by name from any
# configuration that says --dns-updown. It is removed with the empty directory
# it came in.
rm -f "${pkgdir}/usr/libexec/openvpn/dns-updown"
rmdir "${pkgdir}/usr/libexec/openvpn" "${pkgdir}/usr/libexec" 2>/dev/null || true
rm -f "${pkgdir}"/usr/lib64/openvpn/plugins/*.la

# 430K of HTML that says exactly what openvpn.8 and openvpn-examples.5 say, in
# a format nothing in the image can render, and a README for the TLS backend
# this build did not use.
rm -f "${pkgdir}"/usr/share/doc/openvpn/*.html \
    "${pkgdir}/usr/share/doc/openvpn/README.mbedtls"

# Where tunnels are configured. The init script starts one openvpn for each
# .conf file it finds here, so this directory is the whole of the service's
# configuration. It is private because an OpenVPN configuration usually is a
# secret - inline <key> blocks and static keys live in these files - and a
# tunnel that cannot read its own certificate fails loudly, while a key
# readable by every account on the machine does not.
install -d -m 0700 "${pkgdir}/etc/openvpn"

"${TARGET}-strip" "${pkgdir}/usr/sbin/openvpn"
# The plugins are stripped too, and not only for size: libtool builds them with
# debugging information, and the compilation directory recorded there is the
# one this stage built in.
while IFS= read -r plugin; do
    "${TARGET}-strip" --strip-unneeded "${plugin}"
done < <(find "${pkgdir}/usr/lib64/openvpn/plugins" -type f -name '*.so')

[[ -x "${pkgdir}/usr/sbin/openvpn" ]] || die "the openvpn daemon was not installed"
[[ -f "${pkgdir}/usr/share/man/man8/openvpn.8" ]] \
    || die "the openvpn manual page was not installed"
[[ -f "${pkgdir}/usr/lib64/openvpn/plugins/openvpn-plugin-down-root.so" ]] \
    || die "the down-root plugin was not installed"
[[ -d "${pkgdir}/etc/openvpn" ]] || die "/etc/openvpn was not created"
[[ "$(stat -c '%a' "${pkgdir}/etc/openvpn")" == 700 ]] \
    || die "/etc/openvpn must be readable only by root; it holds key material"
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/openvpn" | grep -q 'libssl.so.3' \
    || die "openvpn was built without OpenSSL; it could not complete a TLS handshake"
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/openvpn" | grep -q 'libcrypto.so.3'
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/openvpn" | grep -q 'libcap-ng.so.0' \
    || die "openvpn was built without libcap-ng; it could not keep CAP_NET_ADMIN across --user"
# A library the image does not carry is a daemon that will not start, and one
# it carries for something else is a dependency nobody declared. libnl is the
# DCO path that was turned off, and the compression libraries are the ones
# whose absence is deliberate rather than accidental.
for unwanted in libnl-3 libnl-genl libpam liblzo2 liblz4 libmbedtls libwolfssl libsystemd libselinux; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/openvpn" | grep -q "${unwanted}"; then
        die "openvpn links ${unwanted}; the image has no such library"
    fi
done
if "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/openvpn" | grep -qE 'RPATH|RUNPATH'; then
    die "openvpn carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/sbin/openvpn" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "openvpn was not built with the cross compiler"
# Not just the binary: "openvpn --version" prints the compile-time options, and
# configure compiles in the paths of several helper programs. Any of them that
# named the build host would be published with the package.
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "openvpn installed files containing the build path: ${leaked}"
pkg_merge openvpn
log "installed OpenVPN $(source_version openvpn)"
