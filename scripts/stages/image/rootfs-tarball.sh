#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"
# shellcheck source=../../lib/archive.sh
source "${PROJECT_ROOT}/scripts/lib/archive.sh"

require_command tar
require_command xz
require_command find
require_command sort

[[ -d "${ROOTFS_DIR}" ]] || die "root filesystem is missing"
[[ -f "${ROOTFS_DIR}/boot/vmlinuz" ]] \
    || die "the kernel is missing from the root filesystem; run 'make image' first"

# The root filesystem, packed as a plain tarball. The live ISO installs by
# copying the running system with tar; this is that same system, frozen into an
# artifact so the portable installer can lay it down onto a mounted filesystem
# and finish the install the way sowa-bootstrap's closing instructions
# describe: write /etc/fstab, run grub-install, and drop a grub.cfg in. See
# docs/install.md.
#
# It is cut from the assembled tree after the image stage has embedded the
# kernel at /boot/vmlinuz and removed the recovery image's /init, so it is a
# complete, bootable root and not a build intermediate.
tarball="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}-rootfs.tar.xz"
legacy_tarball="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}-rootfs.tar.gz"
temporary="${tarball}.tmp.$$.tar"
compressed="${temporary}.xz"
trap 'rm -f "${temporary}" "${compressed}"' EXIT

log "create ${tarball}"
# The same deterministic options the binary packages are built with: every
# member owned by root, a single fixed mtime, and pax headers that carry no
# writer PID, atime or ctime. The build runs unprivileged, so without
# --owner=0 --group=0 the archive would record the build user's uid and an
# installation made by extracting it would not be root-owned. --no-recursion
# pairs with the explicit file list, which is sorted so the same tree always
# produces the same archive.
(
    cd "${ROOTFS_DIR}"
    find . -print0 \
        | sort -z \
        | tar --create --file="${temporary}" \
            --format=pax \
            --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
            --owner=0 --group=0 --numeric-owner \
            --mtime=@"${SOURCE_DATE_EPOCH}" \
            --no-recursion \
            --null --files-from=-
)
xz_compress_default < "${temporary}" > "${compressed}"
xz_test_stream < "${compressed}"
mv "${compressed}" "${tarball}"
rm -f "${temporary}"
trap - EXIT
write_sha256_manifest "${tarball}"
rm -f "${legacy_tarball}" "${legacy_tarball}.sha256"
