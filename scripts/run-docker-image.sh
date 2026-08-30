#!/usr/bin/env bash
#
# Run the container image built by make docker-image.
#
# The archive that stage writes is not an image a runtime knows about yet - it
# is a file - so this loads it first and then runs it, which is the two-step
# dance the documentation spells out by hand:
#
#   docker load -i artifacts/sowa-0.1-x86_64-docker.tar
#   docker run --rm -it sowa:0.1
#
# The load is skipped when the runtime already holds this exact image, and
# "this exact image" is knowable because the build is reproducible: the image
# id is the digest of the configuration inside the archive, so comparing it
# with what the local tag points at answers the question without unpacking
# anything. A rebuilt rootfs changes that digest and the load happens again.
#
#   scripts/run-docker-image.sh                     # an interactive shell
#   scripts/run-docker-image.sh uname -a            # one command, then exit
#   scripts/run-docker-image.sh --install           # /dev and the artifacts
#
# Nothing here publishes anything and nothing here needs root beyond whatever
# the runtime already asks for.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_command tar

archive="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}-docker.tar"

# Podman reads the same archive and takes the same arguments, so either will
# do; docker is tried first only because it is the name on the target.
if [[ -n "${SOWA_CONTAINER_RUNTIME:-}" ]]; then
    runtime="${SOWA_CONTAINER_RUNTIME}"
    require_command "${runtime}"
elif command -v docker >/dev/null 2>&1; then
    runtime=docker
elif command -v podman >/dev/null 2>&1; then
    runtime=podman
else
    die "neither docker nor podman is installed; one of them is needed to run the image"
fi

# A container gets the host's kernel rather than the one this project builds,
# and every binary in the image was compiled against a glibc configured
# --enable-kernel=6.1.0. Below that, statx(2) returns ENOSYS and coreutils
# fails in ways that read as a broken image rather than a too-old host, so say
# which it is before the shell starts. The kernel that matters is the one the
# containers run on, so nothing is said when DOCKER_HOST points at a daemon
# somewhere else: this machine's release would be the wrong number to judge.
warn_host_kernel() {
    local release="${1:-}"
    [[ -z "${DOCKER_HOST:-}" ]] || return 0
    [[ "${release}" =~ ^([0-9]+)\.([0-9]+) ]] || return 0
    ((BASH_REMATCH[1] > 6 || (BASH_REMATCH[1] == 6 && BASH_REMATCH[2] >= 1))) && return 0
    log "warning: this host runs Linux ${release}, and the image needs 6.1 or newer;"
    log "         expect 'Function not implemented' from ls, stat and du"
}

run_flags=(--rm)

privileged=0
while (($# > 0)); do
    case "$1" in
        # What the documented install-from-a-container flow needs: the host's
        # devices to write a disk with, and the artifacts directory to take the
        # rootfs tarball from. Read-only, because the container is here to read
        # that tarball and not to write anything back into a build tree.
        --install)
            privileged=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*) die "usage: ${0##*/} [--install] [command [argument...]]" ;;
        *) break ;;
    esac
done

if ((privileged)); then
    run_flags+=(--privileged -v /dev:/dev -v "${ARTIFACT_DIR}:/artifacts:ro")
fi

# -t on a pipe gives the runtime a terminal that is not there, and the shell
# inside then behaves as if it were interactive: "make docker-run < script" and
# a command in a CI log both want stdin attached and nothing else.
run_flags+=(--interactive)
if [[ -t 0 && -t 1 ]]; then
    run_flags+=(--tty)
fi

[[ -f "${archive}" ]] || die "no image archive at ${archive}; run 'make docker-image' first"

# Both facts this needs are in the archive's manifest, and both are read from
# the archive rather than rebuilt from SOWA_IMAGE_NAME and SOWA_IMAGE_TAG: the
# tag a load produces is the one recorded when the archive was written, so
# asking the file is the only way to name the image that will actually appear.
# --occurrence=1 stops tar at the member it wants instead of reading a gigabyte
# of layer to reach the end.
manifest="$(tar -xOf "${archive}" --occurrence=1 manifest.json)"

# The manifest names the configuration file by that file's own digest, which is
# the image id the runtime will report.
image_id="$(sed -n 's/.*"Config"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)\.json".*/\1/p' <<< "${manifest}")"
local_tag="$(sed -n 's/.*"RepoTags"[[:space:]]*:[[:space:]]*\[[[:space:]]*"\([^"]*\)".*/\1/p' <<< "${manifest}")"
[[ -n "${image_id}" && -n "${local_tag}" ]] \
    || die "cannot read an image id and tag from ${archive}; rebuild it with 'make docker-image'"

# Docker prints the id with a sha256: prefix and podman without one.
loaded_id="$("${runtime}" image inspect --format '{{.Id}}' "${local_tag}" 2>/dev/null || true)"
if [[ "${loaded_id#sha256:}" != "${image_id}" ]]; then
    log "loading ${archive}"
    "${runtime}" load -i "${archive}"
fi

# The runtime would otherwise name the container after a random hex string and
# put that in the prompt, which is a confusing thing to read on a system whose
# hostname is meant to be its own. Registry host and tag are dropped from it:
# a hostname is a label, not an address.
hostname="${local_tag%%:*}"
run_flags+=(--hostname "${hostname##*/}")
run_flags+=(--pid host --network host)

warn_host_kernel "$(uname -r)"

rootfs_tarball="${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}-rootfs.tar.xz"
if ((privileged)) && [[ -f "${ARTIFACT_DIR}/${rootfs_tarball}" ]]; then
    log "install onto a disk with:"
    log "    sowa-bootstrap --from-tarball /artifacts/${rootfs_tarball} /mnt"
fi

log "running ${local_tag} (image id sha256:${image_id})"
exec "${runtime}" run "${run_flags[@]}" "${local_tag}" "$@"
