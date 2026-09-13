#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

rsync_source="$(prepare_source rsync)"
build_tree="${BUILD_DIR}/rsync"
reset_build_dir "${build_tree}"
# Keep __FILE__ relative, and use the generated configure and manual pages
# from the release archive without invoking upstream's fetching wrapper.
cp -a "${rsync_source}/." "${build_tree}/"
pkgdir="$(pkg_stage rsync)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig:${SYSROOT}/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
# These run-time probes otherwise lose Linux/glibc features when cross building.
export rsync_cv_can_hardlink_symlink=yes
export rsync_cv_can_hardlink_special=yes
export rsync_cv_HAVE_SOCKETPAIR=yes
export rsync_cv_HAVE_C99_VSNPRINTF=yes
export rsync_cv_HAVE_SECURE_MKSTEMP=yes
cd "${build_tree}"
# popt stays private to rsync. zlib, libcrypto and libzstd must come from the
# target sysroot. glibc supplies iconv and xattrs; no libacl, liblz4 or libxxhash
# is shipped. Disable the SIMD run-time configure probe for a portable build.
./configure.sh \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --mandir=/usr/share/man \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-rsh=/usr/bin/ssh \
    --with-rsyncd-conf=/etc/rsyncd.conf \
    --with-nobody-user=nobody \
    --with-nobody-group=nobody \
    --with-included-popt \
    --without-included-zlib \
    --without-rrsync \
    --enable-openssl \
    --enable-zstd \
    --enable-xattr-support \
    --enable-iconv \
    --enable-iconv-open \
    --enable-ipv6 \
    --disable-acl-support \
    --disable-lz4 \
    --disable-xxhash \
    --disable-md2man \
    --disable-debug \
    --disable-roll-simd \
    --disable-roll-asm \
    --disable-md5-asm

for feature in EXTERNAL_ZLIB USE_OPENSSL SUPPORT_ZSTD SUPPORT_XATTRS \
    HAVE_SOCKETPAIR CAN_HARDLINK_SYMLINK CAN_HARDLINK_SPECIAL; do
    grep -qx "#define ${feature} 1" config.h \
        || die "rsync was configured without ${feature}"
done
for feature in SUPPORT_ACLS SUPPORT_LZ4 SUPPORT_XXHASH; do
    if grep -q "^#define ${feature} " config.h; then
        die "rsync unexpectedly enables ${feature}"
    fi
done
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

binary="${pkgdir}/usr/bin/rsync"
[[ -f "${binary}" && ! -L "${binary}" ]] || die "rsync was not installed as a regular file"
"${TARGET}-strip" "${binary}"
chmod 0755 "${binary}"
for program in rsync rsync-ssl; do
    [[ -x "${pkgdir}/usr/bin/${program}" && ! -L "${pkgdir}/usr/bin/${program}" ]] \
        || die "rsync did not install ${program}"
    [[ "$(stat -c '%a' "${pkgdir}/usr/bin/${program}")" == 755 ]] \
        || die "${program} has an unexpected mode"
done
bash -n "${pkgdir}/usr/bin/rsync-ssl"
for page in man1/rsync.1 man1/rsync-ssl.1 man5/rsyncd.conf.5; do
    [[ -s "${pkgdir}/usr/share/man/${page}" ]] || die "rsync did not install ${page}"
done
[[ ! -e "${pkgdir}/bin" ]] || die "rsync installed files outside /usr"

elf_header="$("${TARGET}-readelf" -h "${binary}")"
grep -q 'Machine:.*Advanced Micro Devices X86-64' <<< "${elf_header}" \
    || die "rsync is not an x86_64 binary"
program_headers="$("${TARGET}-readelf" -l "${binary}")"
grep -qF '[Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]' <<< "${program_headers}" \
    || die "rsync has an unexpected ELF interpreter"
needed="$("${TARGET}-readelf" -d "${binary}")"
for library in libc.so.6 libcrypto.so.3 libz.so.1 libzstd.so.1; do
    grep -qF "Shared library: [${library}]" <<< "${needed}" \
        || die "rsync was built without ${library}"
done
while IFS= read -r library; do
    case "${library}" in
        libc.so.6 | libcrypto.so.3 | libz.so.1 | libzstd.so.1 | libgcc_s.so.1) ;;
        *) die "rsync links an undeclared library: ${library}" ;;
    esac
done < <(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' <<< "${needed}")
if grep -qE 'RPATH|RUNPATH' <<< "${needed}"; then
    die "rsync carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
compiler_comment="$("${TARGET}-readelf" -p .comment "${binary}")"
grep -qF "GCC: (GNU) ${cross_gcc_version}" <<< "${compiler_comment}" \
    || die "rsync was not built with the cross compiler"
pkg_merge rsync
log "installed rsync $(source_version rsync)"
