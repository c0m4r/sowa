#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GNU inetutils, for four of the programs in it: ping, ping6, hostname and
# telnet.
#
# inetutils is a collection of about thirty programs, most of them r-command era
# network tools nothing should be running in 2026. This stage builds four and
# refuses the rest by name. Three of the refusals are load bearing rather than
# tidy:
#
#   traceroute - inetutils has one, and it is a toy next to the real thing.
#                Sowa answers that name with a placeholder pointing at mtr, so a
#                /usr/bin/traceroute installed here would both shadow that and
#                collide with it on a path two packages claim.
#   logger     - util-linux already installs /usr/bin/logger and owns it, the
#                same conflict the procps stage avoids with --disable-kill.
#   whois      - inetutils' whois is a fork of Marco d'Itri's from around 2005
#                with the server tables frozen into static headers: it still
#                falls back to whois.networksolutions.com and knows none of the
#                gTLDs added since. The image takes the maintained upstream of
#                that same program as its own package instead.
#
# telnet is kept because it is the genuine BSD article - the tn3270 code is
# still in it - it links no library the others do not, and every network device
# with a serial console still expects someone to have it.
#
# The alternative for ping was iputils, which is meson-only; meson is not a host
# requirement and taking it on for one binary is a bad trade. inetutils is
# autotools, needs no library the sysroot does not already have, and its
# hostname supports -f, -i and -s.

inetutils_source="$(prepare_source inetutils)"
build_tree="${BUILD_DIR}/inetutils"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage inetutils)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# --disable-servers and --disable-clients switch the whole collection off, and
# the three --enable switches turn back on what this package exists for. The
# individual --disable switches after them are not redundant: they name the
# programs whose absence something else in the image depends on, so that a
# future inetutils that reclassifies one of them out of "clients" cannot quietly
# start installing it.
#
# PAM and IDN are refused because the image has neither, and would otherwise be
# picked up from the build host's headers rather than from the sysroot.
"${inetutils_source}/configure" \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-rpath \
    --disable-servers \
    --disable-clients \
    --enable-ping \
    --enable-ping6 \
    --enable-hostname \
    --enable-telnet \
    --disable-traceroute \
    --disable-logger \
    --disable-ifconfig \
    --disable-dnsdomainname \
    --disable-whois \
    --disable-talk \
    --disable-libls \
    --without-pam \
    --without-idn \
    --without-wrap
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

for program in ping ping6 hostname telnet; do
    [[ -f "${pkgdir}/usr/bin/${program}" ]] || die "inetutils did not install ${program}"
    "${TARGET}-strip" "${pkgdir}/usr/bin/${program}"
done
# Every mode here is set by this stage rather than taken from the install.
#
# ping and ping6 open a SOCK_RAW unconditionally, so each is setuid root or it
# is a program that prints "Operation not permitted" to every user but one.
# inetutils knows that and installs them with "-o root -m 4755" from its own
# install-ping-hook - which cannot work in an unprivileged build, and the hook
# is written with a leading "-" so make ignores the failure. What it leaves
# behind is mode 0600: not setuid, and not executable by anyone at all.
#
# So the modes are assigned explicitly, after the strip that would have cleared
# the setuid bit anyway, and then read back. pkg_tree_manifest records what it
# finds here, so this is the point where the shipped mode is decided.
for raw_socket_program in ping ping6; do
    chmod 4755 "${pkgdir}/usr/bin/${raw_socket_program}"
    [[ "$(stat -c '%a' "${pkgdir}/usr/bin/${raw_socket_program}")" == 4755 ]] \
        || die "${raw_socket_program} must be setuid root to open a raw socket"
done
for ordinary_program in hostname telnet; do
    chmod 0755 "${pkgdir}/usr/bin/${ordinary_program}"
    [[ "$(stat -c '%a' "${pkgdir}/usr/bin/${ordinary_program}")" == 755 ]] \
        || die "${ordinary_program} should be an ordinary executable"
done
for page in ping.1 ping6.1 hostname.1 telnet.1; do
    [[ -f "${pkgdir}/usr/share/man/man1/${page}" ]] \
        || die "the ${page} manual page was not installed"
done
# The refusals, checked rather than trusted. Each of these is a path that either
# belongs to another package or is answered by a placeholder.
for refused in traceroute logger ifconfig dnsdomainname whois talk ftp \
    rcp rexec rlogin rsh tftp; do
    [[ ! -e "${pkgdir}/usr/bin/${refused}" ]] \
        || die "inetutils installed ${refused}, which this image gets from somewhere else"
done
if compgen -G "${pkgdir}/usr/sbin/*" > /dev/null; then
    die "inetutils installed a server; only ping, ping6 and hostname belong here"
fi
for unwanted in libpam libidn libwrap libreadline; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/ping" | grep -q "${unwanted}"; then
        die "ping links ${unwanted}; the image has no such library"
    fi
done
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/ping" | grep -qE 'RPATH|RUNPATH'; then
    die "ping carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/ping" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "inetutils was not built with the cross compiler"
pkg_merge inetutils
log "installed GNU inetutils $(source_version inetutils) (ping, ping6, hostname, telnet)"
