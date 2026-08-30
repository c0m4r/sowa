#!/usr/bin/env bash
#
# Push the container image built by make docker-image to a registry.
#
# This is the one script in the project that makes something public, and it is
# written to be hard to do by accident: there is no default destination, no
# default registry and no default account. The destination is named on the
# command line or in SOWA_IMAGE_DESTINATION, and nothing is sent until it is
# printed back and confirmed.
#
#   make docker-push SOWA_IMAGE_DESTINATION=ghcr.io/you/sowa:0.1
#   scripts/push-docker-image.sh docker.io/you/sowa:0.1
#
# Credentials are the registry client's business, not this script's: log in with
# "docker login" or "skopeo login" first. Nothing here reads, stores or asks for
# a password, so there is no path by which one ends up in a shell history or a
# build log.
#
# skopeo is preferred when it is installed because it copies the archive
# straight to the registry, the same way the archive was built - no daemon, and
# nothing loaded into a local image store on the way past. docker is the
# fallback, and needs the extra load and tag steps to get there.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

archive="${ARTIFACT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}-docker.tar"
readonly LOCAL_TAG="${SOWA_IMAGE_NAME:-${DISTRO_NAME}}:${SOWA_IMAGE_TAG:-${DISTRO_VERSION}}"

destination="${1:-${SOWA_IMAGE_DESTINATION:-}}"

if [[ -z "${destination}" ]]; then
    printf 'error: no destination given.\n\n' >&2
    printf 'Name the registry, repository and tag to push to - there is no default,\n' >&2
    printf 'because publishing to the wrong place cannot be undone:\n\n' >&2
    printf '  make docker-push SOWA_IMAGE_DESTINATION=ghcr.io/you/sowa:%s\n' "${DISTRO_VERSION}" >&2
    printf '  %s docker.io/you/sowa:%s\n\n' "${0##*/}" "${DISTRO_VERSION}" >&2
    printf 'Log in first with "docker login" or "skopeo login"; this script never\n' >&2
    printf 'handles credentials.\n' >&2
    exit 1
fi

# A tag with no registry host in it resolves to Docker Hub, which is a
# surprising place to arrive at by leaving a word out. Insist on a destination
# that names where it is going.
[[ "${destination}" == *.*/* || "${destination}" == localhost/* || "${destination}" == *:*/* ]] \
    || die "'${destination}' does not name a registry host; write it out in full, e.g. docker.io/you/sowa:${DISTRO_VERSION}"
[[ "${destination}" == *:* ]] \
    || die "'${destination}' has no tag; add one, e.g. ${destination}:${DISTRO_VERSION}"

[[ -f "${archive}" ]] || die "no image archive at ${archive}; run 'make docker-image' first"

if command -v skopeo >/dev/null 2>&1; then
    tool=skopeo
elif command -v docker >/dev/null 2>&1; then
    tool=docker
else
    die "neither skopeo nor docker is installed; one of them is needed to push"
fi

printf '\nAbout to publish:\n\n'
printf '  archive      %s\n' "${archive}"
printf '  digest       %s\n' "$(sha256sum "${archive}" | cut -d' ' -f1)"
printf '  destination  %s\n' "${destination}"
printf '  using        %s\n\n' "${tool}"
printf 'This makes the image public to anyone who can read that repository, and a\n'
printf 'tag that has been pulled cannot be recalled.\n'

if [[ "${SOWA_PUSH_ASSUME_YES:-}" != 1 ]]; then
    printf 'Type "yes" to push: '
    read -r answer
    [[ "${answer}" == yes ]] || die "aborted at user request"
fi

case "${tool}" in
    skopeo)
        log "copying ${archive} to ${destination}"
        skopeo copy "docker-archive:${archive}:${LOCAL_TAG}" "docker://${destination}"
        ;;
    docker)
        log "loading ${archive}"
        docker load -i "${archive}"
        log "tagging ${LOCAL_TAG} as ${destination}"
        docker tag "${LOCAL_TAG}" "${destination}"
        log "pushing ${destination}"
        docker push "${destination}"
        ;;
esac

log "published ${destination}"
