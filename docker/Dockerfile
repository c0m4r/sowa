# The Sowa build environment.
#
# This image is not Sowa and contains no part of it. It is the host side of the
# bootstrap - the compiler, the archivers, the filesystem and boot tools that
# scripts/host-check.sh insists on - packaged so that a checkout can be built on
# any machine that runs a container, without installing any of it on that
# machine. Nothing here is wired into the build system: the container mounts or
# clones a checkout and runs the same "make" the README documents. That is the
# whole contract, and it is why this file can be used against any revision of
# the repository, including ones written after it.
#
# The selected base satisfies every current version floor through its package
# manager. GCC 16.2.1 is what Sowa is developed against, Go is past the 1.26.3
# that Buildx's go.mod demands, and one "grub" package carries both the i386-pc
# and x86_64-efi platform trees that scripts/stages/image/disk-image.sh reads.
# Keeping those inputs in one package transaction avoids layering tool archives
# over the container filesystem.
#
# The cost of a rolling base is that "docker build" is not reproducible by
# default. Both halves of that are pinnable and both are arguments:
#
#   BASE_IMAGE     the dated image tag, which pins the starting point
#   ARCH_SNAPSHOT  a dated package snapshot, which pins the upgrade
#
# Setting only BASE_IMAGE pins very little, because the "pacman -Syu" below
# moves everything to whatever is current. Set both to get the same image twice:
#
#   docker build --build-arg ARCH_SNAPSHOT=2026/08/23 -t sowa-build docker/

ARG BASE_IMAGE=archlinux:base-devel-20260823.0.578598
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-Eeuo", "pipefail", "-c"]

# A date as YYYY/MM/DD selects a dated mirror snapshot and makes the package set
# a function of that date rather than of the day of the build. Empty - the
# default - leaves the image's own mirrorlist alone.
ARG ARCH_SNAPSHOT=""

# The unprivileged account the build runs as. scripts/host-check.sh refuses to
# run as root, so there has to be one, and it has to be able to write a
# bind-mounted checkout owned by whoever is running docker. Both are overridable
# at build time; docker/entrypoint.sh can also move the account at start-up,
# which is what makes one image work for two different people.
ARG BUILDER_UID=1000
ARG BUILDER_GID=1000
ARG BUILDER_NAME=builder

RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked <<'SETUP'
    if [[ -n "${ARCH_SNAPSHOT}" ]]; then
        printf 'Server=https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' \
            "${ARCH_SNAPSHOT}" > /etc/pacman.d/mirrorlist
        # The archive is a frozen tree, so pacman's usual refusal to install a
        # package older than the one it holds has to be relaxed to reach it.
        pacman -Syyuu --noconfirm --needed archlinux-keyring
    else
        # An old base image carries an old keyring, and a keyring that predates
        # a current package's signing key fails the upgrade rather than the
        # signature check. Refreshing it first is what makes an outdated
        # BASE_IMAGE pin recoverable instead of fatal.
        pacman -Sy --noconfirm --needed archlinux-keyring
        pacman -Su --noconfirm
    fi
SETUP

# Everything scripts/host-check.sh looks for, plus the commands the individual
# stages reach for with require_command, grouped by what they are for. base-devel
# is already in the base image and supplies the autotools, bison, flex, gawk,
# gcc, gettext's msgfmt, texinfo's makeinfo, patch, pkgconf and fakeroot.
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked <<'PACKAGES'
    pacman -S --noconfirm --needed \
        bc cpio curl git go inetutils perl python \
        bzip2 tar xz zstd \
        libelf openssl zlib \
        cmake meson ninja \
        dosfstools e2fsprogs mtools squashfs-tools util-linux \
        grub libisoburn \
        qemu-img qemu-system-x86 \
        shellcheck
    # The pacman database is worth keeping - the account inside can install what
    # it turns out to need - but the downloaded packages are not.
    pacman -Scc --noconfirm >/dev/null 2>&1 || true
PACKAGES

# The build refuses to run as root, so this account is not a hardening measure
# but a requirement. sudo is left reachable so that a missing host package is a
# one-line fix from inside the container rather than a rebuild of this image.
RUN <<'ACCOUNT'
    groupadd --gid "${BUILDER_GID}" "${BUILDER_NAME}"
    useradd --uid "${BUILDER_UID}" --gid "${BUILDER_GID}" \
        --create-home --shell /bin/bash "${BUILDER_NAME}"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "${BUILDER_NAME}" \
        > /etc/sudoers.d/"${BUILDER_NAME}"
    chmod 0440 /etc/sudoers.d/"${BUILDER_NAME}"
    # Where a bind-mounted or cloned checkout lands. Created here so that a
    # volume mounted over it inherits an owner rather than arriving as root.
    install -d -o "${BUILDER_UID}" -g "${BUILDER_GID}" -m 0755 /sowa
ACCOUNT

# C.UTF-8 is built into glibc and needs no locale-gen, which keeps this image
# from having to compile a locale to stop configure scripts complaining. The
# build itself pins LC_ALL=C in scripts/lib/common.sh regardless.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SOWA_BUILDER=${BUILDER_NAME}

COPY entrypoint.sh /usr/local/bin/sowa-entrypoint
RUN chmod 0755 /usr/local/bin/sowa-entrypoint

WORKDIR /sowa
ENTRYPOINT ["/usr/local/bin/sowa-entrypoint"]
CMD ["bash", "-l"]
