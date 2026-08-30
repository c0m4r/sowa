#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# mdadm and mdmon are built without libudev, systemd or clustered-RAID glue:
# Sowa has none of those runtimes.  Assembly is performed explicitly during
# rc.sysinit, before fstab is mounted.
mdadm_source="$(prepare_source mdadm)"
mdadm_version="$(source_version mdadm)"
build_tree="${BUILD_DIR}/mdadm"
reset_build_dir "${build_tree}"
cp -a "${mdadm_source}/." "${build_tree}/"
pkgdir="$(pkg_stage mdadm)"

target_configure_env
make_args=(
    CC="${CC}"
    VERSION="${mdadm_version}"
    CXFLAGS='-O2 -DNDEBUG -DNO_LIBUDEV -Wno-error=unused-but-set-variable -Wno-error=unterminated-string-initialization -Wno-error=uninitialized -Wno-error=format-overflow'
    COROSYNC=-DNO_COROSYNC
    DLM=-DNO_DLM
    CHECK_RUN_DIR=0
    BINDIR=/usr/sbin
    MANDIR=/usr/share/man
    STRIP=
)
make -C "${build_tree}" -j"${JOBS}" "${make_args[@]}" all
make -C "${build_tree}" "${make_args[@]}" DESTDIR="${pkgdir}" \
    install-bin install-man

for program in mdadm mdmon; do
    [[ -x "${pkgdir}/usr/sbin/${program}" ]] || die "mdadm did not install ${program}"
    "${TARGET}-strip" "${pkgdir}/usr/sbin/${program}"
done
for page in man4/md.4 man5/mdadm.conf.5 man8/mdadm.8 man8/mdmon.8; do
    [[ -f "${pkgdir}/usr/share/man/${page}" ]] || die "mdadm did not install ${page}"
done
install -D -m 0644 "${PROJECT_ROOT}/config/mdadm.conf" "${pkgdir}/etc/mdadm.conf"
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/mdadm" | grep -q 'libc.so.6' \
    || die "mdadm is not dynamically linked against the target libc"
if "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/mdadm" | grep -q 'libudev'; then
    die "mdadm links libudev, which Sowa does not ship"
fi

pkg_merge mdadm
log "installed mdadm ${mdadm_version}"
