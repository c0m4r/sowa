#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# tcpdump is deliberately an ordinary executable that requires root for live
# capture.  Opening a packet socket requires CAP_NET_RAW and administering
# promiscuous mode can require
# CAP_NET_ADMIN; granting either through a setuid bit would expose its large
# packet decoder to every local account.  Operators who need a capture run it
# through sudo or as root, and offline pcap decoding works unprivileged.

tcpdump_source="$(prepare_source tcpdump)"
build_tree="${BUILD_DIR}/tcpdump"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage tcpdump)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
# tcpdump asks pkg-config for libpcap.  Limit that query to the target sysroot
# so a host libpcap cannot silently satisfy it when the staged copy is missing.
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
"${tcpdump_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-local-libpcap \
    --without-crypto \
    --without-cap-ng
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

program="${pkgdir}/usr/bin/tcpdump"
[[ -x "${program}" ]] || die "tcpdump did not install"
"${TARGET}-strip" "${program}"
chmod 0755 "${program}"
[[ "$(stat -c '%a' "${program}")" == 755 ]] \
    || die "tcpdump must be an ordinary executable"
# Upstream installs a byte-for-byte versioned duplicate beside the command.
# It has no loader or compatibility purpose, so carrying it would waste image
# space and make the package own a second name for the same executable.
rm -f "${pkgdir}/usr/bin/tcpdump.$(source_version tcpdump)"
[[ ! -e "${pkgdir}/usr/bin/tcpdump.$(source_version tcpdump)" ]] \
    || die "tcpdump's redundant versioned executable was not removed"
[[ -f "${pkgdir}/usr/share/man/man1/tcpdump.1" ]] \
    || die "the tcpdump manual page was not installed"
"${TARGET}-readelf" -d "${program}" | grep -q 'libpcap\.so\.1' \
    || die "tcpdump is not linked against the staged libpcap"
if "${TARGET}-readelf" -d "${program}" | grep -qE 'RPATH|RUNPATH'; then
    die "tcpdump carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${program}" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "tcpdump was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "tcpdump installed files containing the build path: ${leaked}"
pkg_merge tcpdump
log "installed tcpdump $(source_version tcpdump)"
