#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# xfsprogs has a source-tree make build.  Current releases require inih,
# libuuid, libblkid and userspace RCU; all probes are constrained to Sowa's
# sysroot so a host library cannot become an accidental image dependency.
xfs_source="$(prepare_source xfsprogs)"
build_tree="${BUILD_DIR}/xfsprogs"
reset_build_dir "${build_tree}"
cp -a "${xfs_source}/." "${build_tree}/"
pkgdir="$(pkg_stage xfsprogs)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
export BUILD_CC=gcc
export BUILD_CFLAGS='-O2 -DNDEBUG -std=gnu11'
cd "${build_tree}"

# If LVM2 happens to have been built already, xfsprogs can opportunistically
# link libdevmapper.  Force the probe off so a direct xfsprogs build and a full
# image build have exactly the same runtime dependencies.
ac_cv_search_dm_task_create=no ./configure \
    --prefix=/usr \
    --sbindir=/usr/sbin \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-static \
    --disable-gettext \
    --enable-lib64=no \
    --enable-libicu=no \
    --enable-scrub=yes \
    --with-systemd-unit-dir=no \
    --with-crond-dir=no \
    --with-udev-rule-dir=no
make -j"${JOBS}"
make DIST_ROOT="${pkgdir}" install
# LVM2 uses the public XFS ioctl definitions to implement the complete
# lvextend --resizefs path for XFS, so retain the development headers too.
install -d -m 0755 "${pkgdir}/usr/include/xfs"
install -m 0644 \
    "${build_tree}/include/handle.h" \
    "${build_tree}/include/jdm.h" \
    "${build_tree}/include/linux.h" \
    "${build_tree}/include/xfs.h" \
    "${build_tree}/include/xqm.h" \
    "${build_tree}/include/xfs_fs_compat.h" \
    "${build_tree}/include/xfs_arch.h" \
    "${build_tree}/libxfs/xfs_fs.h" \
    "${build_tree}/libxfs/xfs_types.h" \
    "${build_tree}/libxfs/xfs_da_format.h" \
    "${build_tree}/libxfs/xfs_format.h" \
    "${build_tree}/libxfs/xfs_log_format.h" \
    "${pkgdir}/usr/include/xfs/"

rm -f "${pkgdir}"/usr/lib64/*.la "${pkgdir}"/usr/lib64/*.a
while IFS= read -r binary; do
    "${TARGET}-readelf" -h "${binary}" >/dev/null 2>&1 || continue
    "${TARGET}-strip" "${binary}"
done < <(find "${pkgdir}/usr/sbin" -type f)
while IFS= read -r library; do
    "${TARGET}-strip" --strip-unneeded "${library}"
done < <(find "${pkgdir}/usr/lib64" -type f -name '*.so.*')

for program in mkfs.xfs xfs_repair xfs_growfs xfs_info xfs_db xfs_io \
    xfs_scrub xfs_copy; do
    [[ -x "${pkgdir}/usr/sbin/${program}" ]] \
        || die "xfsprogs did not install ${program}"
done
[[ -f "${pkgdir}/usr/include/xfs/xfs.h" ]] \
    || die "xfsprogs did not install xfs.h for LVM2"
needed="$("${TARGET}-readelf" -d "${pkgdir}/usr/sbin/mkfs.xfs")"
for library in libinih.so.0 libuuid.so.1 libblkid.so.1; do
    grep -q "${library}" <<< "${needed}" \
        || die "mkfs.xfs was not linked against ${library} from the sysroot"
done
if grep -q 'libdevmapper' <<< "${needed}"; then
    die "mkfs.xfs picked up libdevmapper despite the disabled probe"
fi

pkg_merge xfsprogs
log "installed xfsprogs $(source_version xfsprogs)"
