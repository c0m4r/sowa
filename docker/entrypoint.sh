#!/usr/bin/env bash
#
# What has to happen between "docker run" and the build starting.
#
# Two of the three are consequences of scripts/host-check.sh refusing to build
# as root, which is the correct rule and the reason this file exists at all:
#
#   - The account inside has to be able to write a bind-mounted checkout owned
#     by whoever is running docker on the outside. A container has no idea what
#     that UID is until it starts, so the account is moved to it here rather
#     than baked into the image. One image then serves every user on the host.
#   - Privilege is dropped before the command runs, so nothing the build does
#     ever executes as root even though the container starts that way.
#   - A checkout is cloned when one was asked for and the directory is empty,
#     which is what makes "git clone the repo" a container argument rather than
#     a step to remember.
#
# Starting the container with "--user" skips all of it: the caller has already
# decided who the build runs as, and this only checks that the answer is not
# root before handing over.

set -Eeuo pipefail

readonly BUILDER="${SOWA_BUILDER:-builder}"

log() { printf '==> %s\n' "$*" >&2; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Clone into the working directory when one was named and there is nothing
# there yet. "Nothing there yet" is deliberate: a bind-mounted checkout, or a
# named volume from an earlier run, is left exactly as it is.
clone_if_requested() {
    local repo="${SOWA_REPO:-}" ref="${SOWA_REF:-}"
    [[ -n "${repo}" ]] || return 0
    [[ -d /sowa ]] || return 0
    if [[ -n "$(ls -A /sowa 2>/dev/null)" ]]; then
        log "/sowa is not empty; leaving it alone and ignoring SOWA_REPO"
        return 0
    fi
    local at=()
    if [[ -n "${ref}" ]]; then at=(--branch "${ref}"); fi
    log "cloning ${repo}${ref:+ at ${ref}} into /sowa"
    # safe.directory, because cloning a local checkout means reading a
    # repository owned by whoever owns it on the host, which is not this
    # account and which git refuses by default. It is scoped to this one
    # command: the clone it produces is owned by the account that made it, so
    # nothing afterwards needs the exemption.
    # Both spellings: git tests the working tree it was handed and the .git
    # directory inside it, and rejects on either.
    git -c safe.directory="${repo}" -c safe.directory="${repo}/.git" \
        clone "${at[@]}" -- "${repo}" /sowa
}

# Already unprivileged, which means the caller passed --user. Take the answer.
if ((EUID != 0)); then
    [[ -n "${HOME:-}" && -w "${HOME}" ]] || export HOME=/tmp
    clone_if_requested
    exec "$@"
fi

# The UID and GID to become. An explicit SOWA_UID wins; otherwise the owner of
# the working directory is the right answer, because that is the checkout whose
# files the build is about to write.
target_uid="${SOWA_UID:-}"
target_gid="${SOWA_GID:-}"
if [[ -z "${target_uid}" && -d /sowa ]]; then
    target_uid="$(stat -c '%u' /sowa)"
    target_gid="${target_gid:-$(stat -c '%g' /sowa)}"
fi
builder_uid="$(id -u "${BUILDER}")"
builder_gid="$(id -g "${BUILDER}")"
target_uid="${target_uid:-${builder_uid}}"
target_gid="${target_gid:-${builder_gid}}"

((target_uid != 0)) || die \
    "the build refuses to run as root (scripts/host-check.sh); mount a checkout owned by an ordinary user, or set SOWA_UID"

builder_home="$(getent passwd "${BUILDER}" | cut -d: -f6)"

# Move the account onto the host's identity. The clash case - the wanted UID
# already belonging to one of the distribution's own system accounts - is not
# worth renumbering anything over: run as the bare UID instead and give it the
# builder's home, which is all the build actually needs from an account.
if ((target_uid != builder_uid || target_gid != builder_gid)); then
    clashing_user="$(getent passwd "${target_uid}" | cut -d: -f1 || true)"
    if [[ -n "${clashing_user}" && "${clashing_user}" != "${BUILDER}" ]]; then
        log "uid ${target_uid} is ${clashing_user} in this image; running as the bare uid"
    else
        log "moving ${BUILDER} to ${target_uid}:${target_gid} to match the checkout"
        getent group "${target_gid}" >/dev/null \
            || groupmod --gid "${target_gid}" "${BUILDER}"
        usermod --uid "${target_uid}" --gid "${target_gid}" "${BUILDER}"
    fi
    # Only the home directory, and only when it is not already right. The
    # checkout is never touched: chown -R on a bind mount would rewrite the
    # ownership of the user's own files on the host.
    if [[ "$(stat -c '%u' "${builder_home}")" != "${target_uid}" ]]; then
        chown -R "${target_uid}:${target_gid}" "${builder_home}"
    fi
fi

clone_if_requested
# A clone made as root would leave a checkout the build cannot write.
if [[ -d /sowa/.git && "$(stat -c '%u' /sowa/.git)" == 0 ]]; then
    chown -R "${target_uid}:${target_gid}" /sowa
fi

export HOME="${builder_home}" USER="${BUILDER}" LOGNAME="${BUILDER}"
exec setpriv --reuid="${target_uid}" --regid="${target_gid}" --init-groups -- "$@"
