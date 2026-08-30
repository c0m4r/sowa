#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Btrfs' userspace suite.  The image already carries zlib and zstd; LZO is not
# present, so that optional userspace decoder is explicitly disabled rather
# than detected from the build host.  The kernel-side filesystem still has its
# complete built-in compression support.
btrfs_source="$(prepare_source btrfs-progs)"
build_tree="${BUILD_DIR}/btrfs-progs"
reset_build_dir "${build_tree}"
cp -a "${btrfs_source}/." "${build_tree}/"
pkgdir="$(pkg_stage btrfs-progs)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
./configure \
    --prefix=/usr \
    --bindir=/usr/sbin \
    --libdir=/usr/lib64 \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-backtrace \
    --disable-documentation \
    --disable-static \
    --disable-convert \
    --disable-lzo \
    --disable-libudev \
    --disable-python \
    --with-crypto=builtin
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

# Release archives contain generated manual pages even when Sphinx is absent.
# Install those pages directly, excluding the converter that was not built.
while IFS= read -r page; do
    [[ "$(basename "${page}")" == btrfs-convert.8 ]] && continue
    section="${page##*.}"
    install -D -m 0644 "${page}" \
        "${pkgdir}/usr/share/man/man${section}/$(basename "${page}")"
done < <(find "${build_tree}/Documentation" -maxdepth 1 -type f \
    \( -name '*.2' -o -name '*.5' -o -name '*.8' \) -print)

rm -f "${pkgdir}"/usr/lib64/*.a
while IFS= read -r binary; do
    "${TARGET}-readelf" -h "${binary}" >/dev/null 2>&1 || continue
    "${TARGET}-strip" "${binary}"
done < <(find "${pkgdir}/usr/sbin" -type f)
while IFS= read -r library; do
    "${TARGET}-strip" --strip-unneeded "${library}"
done < <(find "${pkgdir}/usr/lib64" -type f -name '*.so.*')

for program in btrfs mkfs.btrfs btrfs-image btrfs-find-root btrfstune \
    btrfs-select-super; do
    [[ -x "${pkgdir}/usr/sbin/${program}" ]] \
        || die "btrfs-progs did not install ${program}"
done
[[ -f "${pkgdir}/usr/lib64/libbtrfsutil.so.1" \
    || -L "${pkgdir}/usr/lib64/libbtrfsutil.so.1" ]] \
    || die "btrfs-progs did not install libbtrfsutil.so.1"
needed="$("${TARGET}-readelf" -d "${pkgdir}/usr/sbin/mkfs.btrfs")"
for library in libuuid.so.1 libblkid.so.1 libz.so.1 libzstd.so.1; do
    grep -q "${library}" <<< "${needed}" \
        || die "mkfs.btrfs was not linked against ${library} from the sysroot"
done
if grep -qE 'libudev|liblzo' <<< "${needed}"; then
    die "mkfs.btrfs linked an optional library Sowa does not ship"
fi

pkg_merge btrfs-progs
log "installed btrfs-progs $(source_version btrfs-progs)"
