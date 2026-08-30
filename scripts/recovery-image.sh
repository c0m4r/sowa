#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/archive.sh
source "$(dirname "$0")/lib/archive.sh"

require_command cpio
require_command xz
[[ -d "${ROOTFS_DIR}" ]] || die "root filesystem missing; run 'make rootfs'"
[[ -x "${ROOTFS_DIR}/sbin/init" ]] || die "sowa-init is missing; run 'make rootfs'"
[[ -f "${ROOTFS_DIR}/etc/inittab" ]] || die "the inittab is missing from the root filesystem"
[[ -L "${ROOTFS_DIR}/bin/sh" || -x "${ROOTFS_DIR}/bin/sh" ]] \
    || die "target /bin/sh is missing; rebuild Bash and the root filesystem"

archive="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}-recovery.cpio.xz"
legacy_archive="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}-recovery.cpio.gz"
temporary="${archive}.tmp.$$"
trap 'rm -f "${temporary}"' EXIT
ln -sfn sbin/init "${ROOTFS_DIR}/init"
log "create recovery image ${archive}"
# Linux's initramfs decoder supports CRC32, not XZ's default CRC64. Leave the
# compression preset and threading at XZ defaults.
(
    cd "${ROOTFS_DIR}"
    find . -print0 \
        | sort -z \
        | cpio --null --create --format=newc --owner=0:0 --reproducible 2>/dev/null \
        | xz_compress_default --check=crc32 > "${temporary}"
)
# The temporary name ends in .tmp.<pid>, so test it on stdin instead of asking
# xz to infer a suffix from the filename.
xz_test_stream < "${temporary}"
xz_stream_uses_check CRC32 "${temporary}" \
    || die "the recovery XZ stream does not use the kernel-supported CRC32 check"
mv "${temporary}" "${archive}"
trap - EXIT
write_sha256_manifest "${archive}"
rm -f "${legacy_archive}" "${legacy_archive}.sha256"
log "recovery image boots the same init as the release, with no medium to find and nothing to mount"
log "add \"single\" to the kernel command line for a root shell instead of the default runlevel"
