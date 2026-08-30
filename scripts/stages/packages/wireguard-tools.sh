#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# wireguard-tools: wg and wg-quick.
#
# WireGuard itself is not here. It is in the kernel - CONFIG_WIREGUARD in the
# configuration fragment - and a WireGuard interface is a network device the
# kernel drives from start to finish. What this package installs is the two
# programs that configure it: wg, which speaks the generic netlink protocol the
# module exposes, and wg-quick, a Bash script that reads an interface
# description and issues the ip(8) and wg commands it implies.
#
# That division is the whole reason WireGuard sits beside OpenVPN rather than
# replacing it. There is no daemon, nothing in the data path outside the
# kernel, and a peer is a public key and a list of addresses rather than an
# X.509 chain - but also no negotiation, no pushed configuration, and no TCP.
#
# The build is a plain Makefile with no configure step, so what would normally
# be a configure argument is a make variable here. Four of them have to be set
# rather than left alone: the Makefile decides whether to install wg-quick, its
# completions and a systemd unit by looking for /usr/bin/bash, a completions
# directory and a unit directory *on the build host*, which would make package
# contents depend on that host's installed files.

wireguard_source="$(prepare_source wireguard-tools)"
build_tree="${BUILD_DIR}/wireguard-tools"
reset_build_dir "${build_tree}"
cp -a "${wireguard_source}/." "${build_tree}/"
pkgdir="$(pkg_stage wireguard-tools)"

target_configure_env
cd "${build_tree}/src"

# WIREGUARD_TOOLS_VERSION is what "wg --version" prints, and the Makefile takes
# it from "git describe" - which answers nothing in an unpacked tarball, so an
# unset version is a wg that will not say which one it is. The value comes from
# the source lock, where every other version in this distribution comes from.
#
# RUNSTATEDIR is compiled in and is where wg looks for the socket a userspace
# implementation would leave behind. The Makefile still defaults to /var/run;
# Sowa mounts a tmpfs on /run and rc.sysinit does not create the compatibility
# symlink, so the default would name a directory that is not there.
#
# CFLAGS is deliberately not passed here. The Makefile builds its own with
# "+=" - the language standard, _GNU_SOURCE, and the -DRUNSTATEDIR above are
# all appended to it - and a CFLAGS given on the make command line replaces all
# of that rather than adding to it, which is a compile that fails on the first
# use of RUNSTATEDIR. Upstream's -O3 default stands.
make -j"${JOBS}" \
    WIREGUARD_TOOLS_VERSION="$(source_version wireguard-tools)" \
    RUNSTATEDIR=/run
make install \
    DESTDIR="${pkgdir}" \
    PREFIX=/usr \
    SYSCONFDIR=/etc \
    BINDIR=/usr/bin \
    MANDIR=/usr/share/man \
    BASHCOMPDIR=/usr/share/bash-completion/completions \
    RUNSTATEDIR=/run \
    WITH_WGQUICK=yes \
    WITH_BASHCOMPLETION=yes \
    WITH_SYSTEMDUNITS=no

"${TARGET}-strip" "${pkgdir}/usr/bin/wg"

[[ -x "${pkgdir}/usr/bin/wg" ]] || die "wg was not installed"
[[ -x "${pkgdir}/usr/bin/wg-quick" ]] || die "wg-quick was not installed"
[[ -f "${pkgdir}/usr/share/man/man8/wg.8" ]] || die "the wg manual page was not installed"
[[ -f "${pkgdir}/usr/share/man/man8/wg-quick.8" ]] \
    || die "the wg-quick manual page was not installed"
[[ -f "${pkgdir}/usr/share/bash-completion/completions/wg" ]] \
    || die "the wg completion was not installed"
[[ -f "${pkgdir}/usr/share/bash-completion/completions/wg-quick" ]] \
    || die "the wg-quick completion was not installed"
# Upstream's own mode for this directory. The files in it are private keys.
[[ "$(stat -c '%a' "${pkgdir}/etc/wireguard")" == 700 ]] \
    || die "/etc/wireguard must be readable only by root; it holds private keys"
# The Makefile writes a unit directory into the package whenever it finds one on
# the build host, which on a systemd host is exactly what would happen.
[[ ! -d "${pkgdir}/usr/lib/systemd" ]] \
    || die "wireguard-tools installed systemd units; the image has no systemd"
# wg-quick is Bash, not sh, and it says so. The image has Bash at /bin/bash.
head -n 1 "${pkgdir}/usr/bin/wg-quick" | grep -q '^#!/bin/bash$' \
    || die "wg-quick does not start with the interpreter the image provides"
# "wg --version" prints this string, and the Makefile silently leaves it empty
# when there is no git repository to describe - which is every build from a
# tarball. The binary cannot be run here, so the compiled-in string is looked
# for instead.
grep -qF "$(source_version wireguard-tools)" "${pkgdir}/usr/bin/wg" \
    || die "wg does not carry its version string; the version was not passed to the build"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/wg" | grep -q 'libc.so.6'
# wg talks to the kernel over netlink with a copy of libmnl compiled into it, so
# it should link nothing but the C library.
for unwanted in libmnl libnl-3 libcrypto libssl; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/wg" | grep -q "${unwanted}"; then
        die "wg links ${unwanted}; it is built to need nothing but libc"
    fi
done
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/wg" | grep -qE 'RPATH|RUNPATH'; then
    die "wg carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/wg" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "wg was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "wireguard-tools installed files containing the build path: ${leaked}"
pkg_merge wireguard-tools
log "installed wireguard-tools $(source_version wireguard-tools)"
