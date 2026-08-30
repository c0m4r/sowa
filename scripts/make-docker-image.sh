#!/usr/bin/env bash
#
# Pack the assembled root filesystem into a container image.
#
# The output is a Docker archive - the format "docker save" writes and "docker
# load", "podman load" and skopeo all read - assembled here with tar and
# sha256sum rather than by a container runtime. Nothing in this file needs a
# daemon, a builder, or a container tool of any kind to be installed, which is
# the same reason the rest of this project builds a Linux distribution with a
# compiler and a shell: the format is a tar of a tar and two JSON documents, and
# writing it out is less machinery than asking something else to.
#
# It is also what makes the result reproducible. A "docker build" stamps a
# creation time and a layer id that change on every run; everything below is
# derived from the tree and from SOURCE_DATE_EPOCH, so the same rootfs produces
# the same image with the same digest.
#
# What is in it is the whole system minus the kernel. A container never boots
# one, so /boot is dropped; everything else stays, including GRUB and the three
# installers, because that makes the image a way to install Sowa onto a real
# disk from any machine that can run a container:
#
#   docker run --rm -it --privileged -v /dev:/dev sowa:0.1
#   sowa-bootstrap --from-tarball /tmp/sowa-rootfs.tar.xz /mnt
#
# The kernel the installed system boots comes from that tarball, not from the
# image, which is why dropping /boot costs nothing here.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_command tar
require_command sha256sum
require_command find
require_command sort

[[ -d "${ROOTFS_DIR}" ]] || die "root filesystem is missing; run 'make rootfs' first"
[[ -x "${ROOTFS_DIR}/bin/bash" ]] || die "the root filesystem has no /bin/bash"

# A host key in a public image would be one private key shared by every machine
# that ever pulled it. The build should never produce one - they are generated
# at first boot - so this is an assertion rather than a cleanup.
if compgen -G "${ROOTFS_DIR}/etc/ssh/ssh_host_*" >/dev/null; then
    die "the root filesystem contains SSH host keys; they must not be published in an image"
fi

readonly IMAGE_NAME="${SOWA_IMAGE_NAME:-${DISTRO_NAME}}"
readonly IMAGE_TAG="${SOWA_IMAGE_TAG:-${DISTRO_VERSION}}"

archive="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}-docker.tar"
staging="${WORK_DIR}/docker-image"
rm -rf "${staging}"
mkdir -p "${staging}" "${ARTIFACT_DIR}"
trap 'rm -rf "${staging}"' EXIT

created="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"

# The layer: the root filesystem as one uncompressed tar, built with the same
# deterministic options as the rootfs tarball. Uncompressed because the diff_id
# a container runtime identifies a layer by is the digest of the *uncompressed*
# tar, so compressing it here would only have to be undone to name it.
#
# /boot goes, its directory stays: a mount point that exists costs one tar
# header and saves an error from anything that looks for it.
log "packing the root filesystem layer"
layer="${staging}/layer.tar"
(
    cd "${ROOTFS_DIR}"
    find . -path ./boot -prune -print0 -o -print0 \
        | sort -z \
        | tar --create --file="${layer}" \
            --format=pax \
            --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
            --owner=0 --group=0 --numeric-owner \
            --mtime=@"${SOURCE_DATE_EPOCH}" \
            --no-recursion \
            --null --files-from=-
)

diff_id="$(sha256sum "${layer}" | cut -d' ' -f1)"
mv "${layer}" "${staging}/${diff_id}.tar"

# The image configuration. Written by hand because it is twenty lines of JSON
# and adding a jq dependency to emit it would be the larger change.
#
# PATH is the one the image's own /etc/profile exports, repeated here because a
# container command does not go through a login shell and would otherwise get
# the runtime's default PATH instead of this system's. LANG is here for exactly
# the same reason: /etc/profile.d/locale.sh is what exports it and a container
# command never reads it, so without this a container would run in the C locale
# on a system whose whole point is that it does not have to.
#
# It is read from the image rather than written down, because naming a locale
# the archive does not hold is what makes every program print a setlocale
# warning on startup - and the rootfs stage has already held /etc/locale.conf
# to naming one that was compiled.
image_lang="$(locale_conf_lang "${ROOTFS_DIR}/etc/locale.conf" 2>/dev/null || true)"
[[ -n "${image_lang}" ]] \
    || die "the root filesystem's /etc/locale.conf sets no LANG; run 'make rootfs' first"
log "writing the image configuration"
config="${staging}/config.json"
cat > "${config}" <<CONFIG
{
  "created": "${created}",
  "architecture": "${GOARCH}",
  "os": "linux",
  "config": {
    "Env": [
      "PATH=/usr/local/bin:/usr/local/sbin:/bin:/sbin:/usr/bin:/usr/sbin",
      "LANG=${image_lang}"
    ],
    "Cmd": ["/bin/bash"],
    "WorkingDir": "/root",
    "Labels": {
      "org.opencontainers.image.title": "Sowa Linux",
      "org.opencontainers.image.version": "${DISTRO_VERSION}",
      "org.opencontainers.image.description": "A source-built Linux distribution, kernel excluded",
      "org.opencontainers.image.licenses": "GPL-3.0-or-later",
      "org.opencontainers.image.url": "https://sowa.wolfet.pl"
    }
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": ["sha256:${diff_id}"]
  },
  "history": [
    {
      "created": "${created}",
      "created_by": "sowa ${DISTRO_VERSION} rootfs, kernel excluded",
      "comment": "built from source by scripts/build.sh"
    }
  ]
}
CONFIG

# The config's file name is its own digest, which is also the image ID a
# runtime will report. It has to be computed after the file is final.
config_digest="$(sha256sum "${config}" | cut -d' ' -f1)"
mv "${config}" "${staging}/${config_digest}.json"

cat > "${staging}/manifest.json" <<MANIFEST
[
  {
    "Config": "${config_digest}.json",
    "RepoTags": ["${IMAGE_NAME}:${IMAGE_TAG}"],
    "Layers": ["${diff_id}.tar"]
  }
]
MANIFEST

# manifest.json first: "docker load" streams the archive and wants the manifest
# before the layer it names, so a tar in the other order has to be spooled to
# disk in full before anything can start.
log "create ${archive}"
tar --create --file="${archive}" \
    --format=pax \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    --owner=0 --group=0 --numeric-owner \
    --mtime=@"${SOURCE_DATE_EPOCH}" \
    -C "${staging}" \
    manifest.json "${config_digest}.json" "${diff_id}.tar"

rm -rf "${staging}"
trap - EXIT
write_sha256_manifest "${archive}"

log "image ${IMAGE_NAME}:${IMAGE_TAG} is ${archive}"
log "image id sha256:${config_digest}"
log "load it with: docker load -i ${archive}"
log "or run it with: make docker-run"
