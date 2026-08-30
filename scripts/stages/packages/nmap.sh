#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Nmap is a scanner, not a desktop application.  Zenmap and Ndiff are Python
# programs built by the host Python, so leave both out; Nmap, Ncat and Nping
# are the target-native command-line tools this image supplies.
#
# The source tree also carries copies of libpcap, PCRE2 and zlib as fallbacks.
# They would make the command work, but make second copies invisible to other
# programs built on the self-hosting image. The dependency driver stages all
# three shared libraries first and the configured target compiler must find
# them. In particular, PCRE2 entered the image after this stage was first
# written: without a dependency edge, an incremental build found it while a
# clean build absorbed the bundled copy. Do not pass --with-libpcre or
# --with-libz paths here: upstream appends DIR/lib, whereas Sowa's ABI libraries
# live in DIR/lib64. The target include and linker flags below are unambiguous,
# and the post-build checks reject either bundled fallback.

nmap_source="$(prepare_source nmap)"
build_tree="${BUILD_DIR}/nmap"
reset_build_dir "${build_tree}"
cp -a "${nmap_source}/." "${build_tree}/"
pkgdir="$(pkg_stage nmap)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
# Nmap configures its bundled libssh2 recursively.  libssh2's libtool macro
# otherwise searches the build host's /usr/lib first, selects its libgcrypt,
# and leaves the resulting static archive with an unrecorded host dependency.
# Put the target library directory first so the recursive configure selects
# the image's OpenSSL and the final Nmap link gets its crypto dependency from
# OPENSSL_LIBS after libssh2.a.
export LDFLAGS="-L${SYSROOT}/usr/lib64"
# libssh2's generated configure still scans the build host's default /usr/lib
# before LDFLAGS.  Its library macro occurs only in the bundled copy, so teach
# that copy's default probe directory about Sowa's lib64 ABI before recursing.
sed -i "s#eval additional_libdir=\\\\\\\"\\\$libdir\\\\\\\"#additional_libdir='${SYSROOT}/usr/lib64'#" \
    "${build_tree}/libssh2/configure"
cd "${build_tree}"
./configure \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-rpath \
    --without-zenmap \
    --without-ndiff
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

for program in nmap ncat nping; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] \
        || die "Nmap did not install ${program}"
    [[ -f "${pkgdir}/usr/share/man/man1/${program}.1" ]] \
        || die "Nmap did not install the ${program}(1) manual page"
done
[[ -d "${pkgdir}/usr/share/nmap/scripts" ]] \
    || die "Nmap did not install its NSE script database"
[[ -f "${pkgdir}/usr/share/nmap/nmap-services" ]] \
    || die "Nmap did not install its service database"
config_header="${build_tree}/nmap_config.h"
[[ -f "${config_header}" ]] || die "Nmap did not generate nmap_config.h"
! grep -q '^#define PCAP_INCLUDED 1$' "${config_header}" \
    || die "Nmap built its bundled libpcap instead of the staged library"
! grep -q '^#define PCRE_INCLUDED 1$' "${config_header}" \
    || die "Nmap built its bundled PCRE2 instead of the staged library"
! grep -q '^#define ZLIB_INCLUDED 1$' "${config_header}" \
    || die "Nmap built its bundled zlib instead of the staged library"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/nmap" | grep -q 'libpcap\.so\.1' \
    || die "Nmap is not linked against the staged libpcap"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/nmap" | grep -q 'libssl\.so\.3' \
    || die "Nmap was built without the image's OpenSSL support"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/nmap" | grep -q 'libpcre2-8\.so\.0' \
    || die "Nmap is not linked against the staged PCRE2"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/nmap" | grep -q 'libz\.so\.1' \
    || die "Nmap is not linked against the staged zlib"
for program in nmap ncat nping; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/${program}" | grep -qE 'RPATH|RUNPATH'; then
        die "${program} carries a run-time library path"
    fi
done
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/nmap" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "Nmap was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "Nmap installed files containing the build path: ${leaked}"
pkg_keep_staged nmap
log "staged Nmap $(source_version nmap) for the repository"
