#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# LVM2 and its device-mapper library.  Sowa has neither udev nor systemd, so
# device discovery is synchronous and activation is performed in rc.sysinit.
# Thin/cache/VDO metadata tools are separate upstream projects and are not
# silently promised here; basic volumes, snapshots, mirrors and RAID segments
# remain compiled in.
lvm_source="$(prepare_source lvm2)"
build_tree="${BUILD_DIR}/lvm2"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage lvm2)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
"${lvm_source}/configure" \
    --prefix=/usr \
    --sbindir=/usr/sbin \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --runstatedir=/run \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-readline \
    --disable-selinux \
    --disable-nls \
    --disable-use-lvmlockd \
    --disable-use-lvmpolld \
    --disable-systemd-journal \
    --disable-app-machineid \
    --disable-sd-notify \
    --disable-udev_sync \
    --disable-udev_rules \
    --disable-fsadm \
    --disable-lvmimportvdo \
    --disable-blkdeactivate \
    --without-libnvme \
    --without-systemd \
    --without-udev \
    --with-default-use-devices-file=0 \
    --with-default-event-activation=0 \
    --with-thin=none \
    --with-cache=none \
    --with-vdo=none \
    --enable-pkgconfig
# The release archive's generated manpage rules accidentally prefix three
# build-tree intermediates with srcdir.  Correct those prerequisites in the
# generated Makefile so the ordinary out-of-tree build can install its manuals.
# shellcheck disable=SC2016 # $(srcdir) and the rest are make variables, and
# these expressions are matched against the makefile's own text.
sed -i \
    -e 's|$(srcdir)/$(MAN7INDEX)_gen|$(MAN7INDEX)_gen|' \
    -e 's|$(srcdir)/$(MAN7CATEGORIES)_gen|$(MAN7CATEGORIES)_gen|' \
    -e 's|$(srcdir)/$(MAN7ARGS)_gen|$(MAN7ARGS)_gen|' \
    man/Makefile
# Build the tools before asking the manpage generator for them.  A top-level
# parallel "all" lets its recursive man build launch a second tools build into
# the same object tree.
make -j"${JOBS}" tools device-mapper
make -C man -j"${JOBS}" man
make DESTDIR="${pkgdir}" install_system_dirs install_lvm2 install_device-mapper

rm -f "${pkgdir}"/usr/lib64/*.a "${pkgdir}"/usr/lib64/*.la
while IFS= read -r binary; do
    "${TARGET}-readelf" -h "${binary}" >/dev/null 2>&1 || continue
    chmod u+w "${binary}"
    "${TARGET}-strip" "${binary}"
done < <(find "${pkgdir}/usr/sbin" -type f)
while IFS= read -r library; do
    chmod u+w "${library}"
    "${TARGET}-strip" --strip-unneeded "${library}"
done < <(find "${pkgdir}/usr/lib64" -type f -name '*.so.*')

for program in lvm pvcreate pvdisplay pvs vgcreate vgdisplay vgs lvcreate \
    lvdisplay lvs vgchange dmsetup; do
    [[ -x "${pkgdir}/usr/sbin/${program}" || -L "${pkgdir}/usr/sbin/${program}" ]] \
        || die "LVM2 did not install ${program}"
done
[[ -f "${pkgdir}/etc/lvm/lvm.conf" ]] || die "LVM2 did not install lvm.conf"
[[ -f "${pkgdir}/usr/share/man/man8/lvm.8" ]] \
    || die "LVM2 did not install its manual pages"
grep -q '^#define HAVE_XFS_XFS_H 1$' "${build_tree}/include/configure.h" \
    || die "LVM2 was built without complete XFS resize support"
[[ -f "${pkgdir}/usr/lib64/libdevmapper.so.1.02" \
    || -L "${pkgdir}/usr/lib64/libdevmapper.so.1.02" ]] \
    || die "LVM2 did not install libdevmapper.so.1.02"
needed="$("${TARGET}-readelf" -d "${pkgdir}/usr/sbin/lvm")"
grep -q 'libaio.so.1' <<< "${needed}" \
    || die "LVM2 was built without libaio support"
if grep -qE 'libudev|libsystemd|libselinux' <<< "${needed}"; then
    die "LVM2 linked a runtime Sowa does not ship"
fi

pkg_merge lvm2
log "installed LVM2 $(source_version lvm2)"
