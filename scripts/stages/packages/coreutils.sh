#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

coreutils_source="$(prepare_source coreutils)"
build_tree="${BUILD_DIR}/coreutils"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage coreutils)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"

# Two programs are deliberately not installed:
#
#   kill    util-linux already provides it, and two /usr/bin entries for one
#           name cannot both belong to the image
#   uptime  procps-ng installs one, and the same rule applies: one name, one
#           /usr/bin entry, one package that owns it
#
# OpenSSL is refused as well. It would only accelerate the digest programs, and
# it is worth more that the base utilities depend on nothing but glibc: cksum,
# md5sum and the sha*sums use the implementations coreutils carries.
"${coreutils_source}/configure" \
    --prefix=/usr \
    --libexecdir=/usr/libexec \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-acl \
    --disable-xattr \
    --disable-libcap \
    --without-openssl \
    --without-selinux \
    --enable-no-install-program=kill,uptime
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

while IFS= read -r program; do
    "${TARGET}-readelf" -h "${program}" > /dev/null 2>&1 || continue
    "${TARGET}-strip" "${program}"
done < <(find "${pkgdir}/usr/bin" -type f)
[[ -f "${pkgdir}/usr/libexec/coreutils/libstdbuf.so" ]] \
    && "${TARGET}-strip" --strip-unneeded "${pkgdir}/usr/libexec/coreutils/libstdbuf.so"

# The shipped inittab and /etc/passwd name some of these by path, and the rc
# scripts run most of the rest before anyone can log in, so a missing one is a
# boot failure rather than a missing tool.
for program in cat chmod chown cp date dd df echo env false head install ln ls \
    mkdir mknod mktemp mv printf pwd readlink realpath rm rmdir sha256sum sleep \
    sort stat stty sync tail tee test timeout touch tr true uname wc whoami '['; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] \
        || die "coreutils did not install ${program}"
done
for program in kill uptime; do
    [[ ! -e "${pkgdir}/usr/bin/${program}" ]] \
        || die "coreutils installed ${program}, which another package owns"
done
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/ls" | grep -q 'libc.so.6'
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/sha256sum" | grep -q 'libcrypto'; then
    die "the digest programs link OpenSSL; the base utilities are meant to need only glibc"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/ls" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "ls was not built with the cross compiler"
pkg_merge coreutils
log "installed coreutils $(source_version coreutils)"
