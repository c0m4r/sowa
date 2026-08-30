#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

require_command patch
cronie_source="$(prepare_source cronie)"
build_tree="${BUILD_DIR}/cronie"
reset_build_dir "${build_tree}"
cp -a "${cronie_source}/." "${build_tree}/"
pkgdir="$(pkg_stage cronie)"
# Cronie 1.7.2 declares the parser callback with an empty parameter list.  GCC
# 16's C23-compatible interpretation makes that a no-argument callback, while
# every caller passes an error string.  Patch the copied source so the cached,
# checksum-verified unpacked source remains pristine across rebuilds.
patch --directory="${build_tree}" --strip=1 \
    --input="${PROJECT_ROOT}/patches/cronie-1.7.2-gcc16.patch"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# Keep the scheduler self-contained.  PAM, SELinux, Linux audit, and anacron
# all need services or policy not shipped by Sowa.  Inotify lets crond reload
# changed tables promptly, while --with-editor points crontab -e at Sowa's
# /bin/vi rather than a configure-time host path.
"${build_tree}/configure" \
    --prefix=/usr \
    --sbindir=/usr/sbin \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --runstatedir=/run \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-editor=/bin/vi \
    --with-inotify \
    --without-pam \
    --without-selinux \
    --without-audit \
    --disable-anacron
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

for binary in usr/sbin/crond usr/bin/crontab usr/bin/cronnext; do
    [[ -f "${pkgdir}/${binary}" ]] || die "Cronie did not install ${binary}"
    "${TARGET}-strip" "${pkgdir}/${binary}"
done
# crontab needs privilege only to replace validated files in the root-owned
# spool.  cron.allow/cron.deny still determine which non-root accounts may use
# it; absent either file, Cronie permits root alone.
chmod 4755 "${pkgdir}/usr/bin/crontab"

grep -q '^#define WITH_INOTIFY 1' config.h \
    || die "Cronie was built without inotify support"
! grep -q '^#define WITH_PAM 1' config.h \
    || die "Cronie unexpectedly enabled PAM"
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/crond" | grep -q 'libc.so.6'
[[ "$(stat -c '%a' "${pkgdir}/usr/bin/crontab")" == 4755 ]] \
    || die "Cronie crontab did not retain its setuid-root mode"
pkg_merge cronie
log "installed Cronie $(source_version cronie)"
