#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

iproute2_source="$(prepare_source iproute2)"
build_tree="${BUILD_DIR}/iproute2"
reset_build_dir "${build_tree}"
# iproute2 has no out-of-tree build, so the checksum-verified unpacked source is
# copied and built from the copy.
cp -a "${iproute2_source}/." "${build_tree}/"
pkgdir="$(pkg_stage iproute2)"

target_configure_env
# Everything iproute2 can optionally link against - libmnl, libelf, libcap,
# libbpf, SELinux, Berkeley DB, and xtables - is deliberately absent. Probe an
# empty pkg-config directory rather than the host or sysroot: the latter can
# retain packages from later stages during an incremental build.
empty_pkgconfig_dir="${build_tree}/empty-pkgconfig"
mkdir -p "${empty_pkgconfig_dir}"
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${empty_pkgconfig_dir}"
export PKG_CONFIG_PATH=
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
./configure --prefix=/usr --libdir=/usr/lib64 --libbpf_force off

# The top-level Makefile assigns CC unconditionally, which overrides both the
# environment and the CC that ./configure wrote into config.mk; only a
# command-line assignment survives it. HOSTCC defaults to CC and must not, or
# the few build-time helpers would be compiled for the target and then run.
# Sowa keeps its 64-bit libraries in /usr/lib64 and its programs in /usr/sbin
# rather than in the historical /sbin, and LIBDIR is compiled in, so the same
# assignments have to be repeated for the install.
make_options=(
    CC="${CC}"
    HOSTCC=gcc
    AR="${AR}"
    PREFIX=/usr
    LIBDIR=/usr/lib64
    SBINDIR=/usr/sbin
    MANDIR=/usr/share/man
)
make -j"${JOBS}" "${make_options[@]}"
make "${make_options[@]}" DESTDIR="${pkgdir}" install

# ip, tc and their siblings are installed beside shell wrappers such as routel
# and ifcfg, so ask the cross binutils what each file is instead of assuming.
while IFS= read -r program; do
    "${TARGET}-readelf" -h "${program}" > /dev/null 2>&1 || continue
    "${TARGET}-strip" "${program}"
done < <(find "${pkgdir}/usr/sbin" -type f)

for program in ip ss tc bridge genl nstat; do
    [[ -x "${pkgdir}/usr/sbin/${program}" ]] \
        || die "iproute2 did not install ${program}"
done
# netstat was traditionally provided by net-tools. Keep its familiar entry
# point without carrying a separate implementation; ss is its replacement.
ln -s ss "${pkgdir}/usr/sbin/netstat"
[[ "$(readlink "${pkgdir}/usr/sbin/netstat")" == ss ]] \
    || die "netstat is not linked to ss"
ln -s ss.8 "${pkgdir}/usr/share/man/man8/netstat.8"
[[ "$(readlink "${pkgdir}/usr/share/man/man8/netstat.8")" == ss.8 ]] \
    || die "the netstat manual page is not linked to ss.8"
[[ -f "${pkgdir}/usr/share/iproute2/rt_tables" ]] \
    || die "the iproute2 route table names were not installed"
[[ -f "${pkgdir}/usr/share/man/man8/ip.8" ]] \
    || die "the ip manual page was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/ip" | grep -q 'libc.so.6'
# The build host is x86_64 too, so a binary that had been compiled with the
# host's own gcc would pass every other check here and only be noticed once the
# image was booted. The cross compiler's version is pinned; the host's is not.
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/sbin/ip" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "ip was not built with the cross compiler"
pkg_merge iproute2
log "installed iproute2 $(source_version iproute2)"
