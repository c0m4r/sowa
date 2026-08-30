#!/usr/bin/env bash
#
# The build environment without compose.
#
# docker/compose.yml is the readable description of what this runs; this is the
# same thing as one command, and it works with podman, which is the reason it
# exists rather than a two-line alias. It deliberately shares nothing with the
# rest of scripts/ - no lib/common.sh, no config/build.conf - because the whole
# point of the container is to be usable against a checkout that does not have
# them yet, or has different ones.
#
#   docker/sowa-env.sh build                 build (or rebuild) the image
#   docker/sowa-env.sh shell                 a login shell in this checkout
#   docker/sowa-env.sh run make check        one command in this checkout
#   docker/sowa-env.sh run make all          the whole Sowa build
#   docker/sowa-env.sh clone [url [ref]]     a clone in a volume, host untouched
#   docker/sowa-env.sh clean                 remove the image and the volume
#
# "clone" with no argument clones this checkout, which needs no network and no
# credentials and is the honest test: a pristine tree, nothing carried over from
# a build that has already happened here. Give it a URL to clone that instead;
# a private remote needs its credentials passed in, which is what SOWA_SSH_AGENT
# below is for.
#
# The environment it reads:
#
#   SOWA_RUNTIME       docker or podman; the first one found by default
#   SOWA_IMAGE         image name (default sowa-build:latest)
#   SOWA_ARCH_SNAPSHOT a dated snapshot used to pin the package set
#   SOWA_KVM           1 to pass /dev/kvm through, for "make run-qemu"
#   SOWA_REPO_KEY      absolute host path to the repository signing key
#   SOWA_SSH_AGENT     1 to forward SSH_AUTH_SOCK, for cloning a private remote
#   JOBS               build parallelism, passed to make

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HERE
readonly CHECKOUT="${HERE%/docker}"
readonly IMAGE="${SOWA_IMAGE:-sowa-build:latest}"
readonly VOLUME="${SOWA_VOLUME:-sowa-checkout}"

log() { printf '==> %s\n' "$*" >&2; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

if [[ -n "${SOWA_RUNTIME:-}" ]]; then
    runtime="${SOWA_RUNTIME}"
elif command -v docker >/dev/null 2>&1; then
    runtime=docker
elif command -v podman >/dev/null 2>&1; then
    runtime=podman
else
    die "neither docker nor podman is installed"
fi
command -v "${runtime}" >/dev/null 2>&1 || die "${runtime} is not installed"
readonly runtime

build_image() {
    local args=(build --tag "${IMAGE}")
    [[ -n "${SOWA_ARCH_SNAPSHOT:-}" ]] \
        && args+=(--build-arg "ARCH_SNAPSHOT=${SOWA_ARCH_SNAPSHOT}")
    [[ -n "${SOWA_BASE_IMAGE:-}" ]] \
        && args+=(--build-arg "BASE_IMAGE=${SOWA_BASE_IMAGE}")
    log "building ${IMAGE}"
    "${runtime}" "${args[@]}" "${HERE}"
}

have_image() {
    "${runtime}" image inspect "${IMAGE}" >/dev/null 2>&1
}

# Arguments common to both ways of running. Everything the build needs and
# nothing it does not: no privileges, host devices or signing credentials
# unless they were asked for.
run_args=()
run_arguments() {
    run_args=(--rm --interactive --init --shm-size=2g
        --workdir /sowa
        --env "JOBS=${JOBS:-auto}"
        --env "TERM=${TERM:-xterm-256color}")
    [[ -t 0 ]] && run_args+=(--tty)
    # /dev/kvm turns "make run-qemu" from an emulator into a virtual machine.
    # It is off by default because a container that can open it can use the
    # host's hardware virtualisation, which is not something to hand over
    # silently for a build.
    if [[ "${SOWA_KVM:-0}" == 1 ]]; then
        [[ -c /dev/kvm ]] || die "SOWA_KVM=1 but /dev/kvm does not exist"
        run_args+=(--device /dev/kvm)
    fi
    # Signing happens while "make packages" writes the repository index. Lend
    # that invocation only the private key it needs, as a read-only file away
    # from the builder's home: the entrypoint may chown that home while mapping
    # the account onto the owner of the checkout. REPO_KEY is a path in the
    # build configuration, so only the non-secret container path is exported.
    if [[ -n "${SOWA_REPO_KEY:-}" ]]; then
        [[ "${SOWA_REPO_KEY}" == /* ]] \
            || die "SOWA_REPO_KEY must be an absolute host path"
        [[ -f "${SOWA_REPO_KEY}" ]] \
            || die "no repository signing key at ${SOWA_REPO_KEY}"
        [[ -r "${SOWA_REPO_KEY}" ]] \
            || die "repository signing key is not readable: ${SOWA_REPO_KEY}"
        run_args+=(--volume \
            "${SOWA_REPO_KEY}:/run/secrets/sowa-repo-ed25519.key:ro"
            --env REPO_KEY=/run/secrets/sowa-repo-ed25519.key)
    fi
    # A private remote needs a key, and the agent socket is the way to lend one
    # without copying it into the container.
    if [[ "${SOWA_SSH_AGENT:-0}" == 1 ]]; then
        [[ -S "${SSH_AUTH_SOCK:-}" ]] || die "SOWA_SSH_AGENT=1 but no ssh-agent is running"
        run_args+=(--volume "${SSH_AUTH_SOCK}:/ssh-agent"
            --env SSH_AUTH_SOCK=/ssh-agent)
    fi
}

command_name="${1:-shell}"
[[ $# -gt 0 ]] && shift

case "${command_name}" in
    build)
        build_image
        ;;
    shell | run)
        have_image || build_image
        run_arguments
        # The checkout, and the identity to write it as. The entrypoint would
        # work this out from the directory's owner; passing it explicitly means
        # it is also right when the checkout is on a filesystem that reports
        # something else, which is every network and fuse mount.
        run_args+=(--volume "${CHECKOUT}:/sowa"
            --env "SOWA_UID=$(id -u)" --env "SOWA_GID=$(id -g)")
        if [[ "${command_name}" == shell ]]; then
            exec "${runtime}" run "${run_args[@]}" "${IMAGE}" bash -l
        fi
        (($#)) || die "run needs a command, for example: run make check"
        exec "${runtime}" run "${run_args[@]}" "${IMAGE}" "$@"
        ;;
    clone)
        have_image || build_image
        run_arguments
        run_args+=(--volume "${VOLUME}:/sowa")
        origin="${1:-${SOWA_REPO:-}}"
        if [[ -z "${origin}" ]]; then
            # This checkout, mounted read-only somewhere the clone can reach and
            # the build cannot reach back through. git clones a directory as
            # happily as a URL, so the default costs no network and no key.
            run_args+=(--volume "${CHECKOUT}:/srv/origin:ro"
                --env "SOWA_REPO=/srv/origin")
        else
            run_args+=(--env "SOWA_REPO=${origin}")
        fi
        [[ -n "${2:-}" ]] && run_args+=(--env "SOWA_REF=$2")
        exec "${runtime}" run "${run_args[@]}" "${IMAGE}" bash -l
        ;;
    clean)
        log "removing ${IMAGE} and volume ${VOLUME}"
        "${runtime}" image rm "${IMAGE}" 2>/dev/null || true
        "${runtime}" volume rm "${VOLUME}" 2>/dev/null || true
        ;;
    help | -h | --help)
        # The comment block at the top of this file, which is the help text
        # and stays the help text when it is edited.
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
            "${BASH_SOURCE[0]}"
        ;;
    *)
        die "unknown command '${command_name}'; try: $(basename "${BASH_SOURCE[0]}") help"
        ;;
esac
