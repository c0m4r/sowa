#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# libpcap is the portable interface to Linux's packet socket and BPF filter
# compiler.  tcpdump is its first consumer here, but the headers and pkg-config
# metadata are kept because the image carries a native compiler.
#
# Remote capture is deliberately disabled.  It adds a network daemon and a
# second attack surface to a library whose local Linux capture path needs none.
# libnl, D-Bus, Bluetooth, RDMA and netmap are all absent from the sysroot; the
# explicit refusals keep configure from discovering a similarly named host
# library while cross-compiling.

libpcap_source="$(prepare_source libpcap)"
build_tree="${BUILD_DIR}/libpcap"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage libpcap)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
"${libpcap_source}/configure" \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-pcap=linux \
    --disable-remote \
    --without-libnl \
    --disable-usb \
    --disable-netmap \
    --disable-bluetooth \
    --disable-dbus \
    --disable-rdma
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

libpcap_version="$(source_version libpcap)"
library="${pkgdir}/usr/lib64/libpcap.so.${libpcap_version}"
[[ -f "${library}" ]] || die "libpcap did not install its shared library"
"${TARGET}-strip" "${library}"
rm -f "${pkgdir}/usr/lib64/libpcap.a"

[[ "$(readlink "${pkgdir}/usr/lib64/libpcap.so.1")" == "libpcap.so.${libpcap_version}" ]] \
    || die "/usr/lib64/libpcap.so.1 is not a link to libpcap.so.${libpcap_version}"
[[ "$(readlink "${pkgdir}/usr/lib64/libpcap.so")" == libpcap.so.1 ]] \
    || die "/usr/lib64/libpcap.so is not a link to libpcap.so.1"
"${TARGET}-readelf" -d "${library}" | grep -q 'SONAME.*libpcap\.so\.1' \
    || die "libpcap carries no soname; tcpdump could not record its dependency"
[[ ! -e "${pkgdir}/usr/lib64/libpcap.a" ]] \
    || die "libpcap installed a static library; the image ships none"
[[ -f "${pkgdir}/usr/include/pcap/pcap.h" ]] \
    || die "libpcap did not install pcap/pcap.h"
[[ -x "${pkgdir}/usr/bin/pcap-config" ]] \
    || die "libpcap did not install pcap-config"
pkgconfig_file="${pkgdir}/usr/lib64/pkgconfig/libpcap.pc"
[[ -f "${pkgconfig_file}" ]] || die "libpcap did not install libpcap.pc"
grep -qE '^libdir="?/usr/lib64"?$' "${pkgconfig_file}" \
    || die "libpcap.pc does not point at /usr/lib64"
[[ -f "${pkgdir}/usr/share/man/man1/pcap-config.1" ]] \
    || die "the pcap-config.1 manual page was not installed"
for page in pcap.3pcap pcap_open_live.3pcap; do
    [[ -f "${pkgdir}/usr/share/man/man3/${page}" ]] \
        || die "the ${page} manual page was not installed"
done
if "${TARGET}-readelf" -d "${library}" | grep -qE 'RPATH|RUNPATH'; then
    die "libpcap carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${library}" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "libpcap was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "libpcap installed files containing the build path: ${leaked}"
pkg_merge libpcap
log "installed libpcap ${libpcap_version}"
