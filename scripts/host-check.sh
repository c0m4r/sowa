#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

commands=(
    awk bash bc bison bzip2 cpio curl date diff find flex g++ gawk gcc git go gzip
    make makeinfo mksquashfs msgfmt od openssl patch perl python3 sed sha256sum sort tar xz
)

# The autotools. Several stages regenerate a configure script rather than using
# the one in the tarball - mtr and libcap-ng ship none at all, and libuv's has
# to be rebuilt against the host's libtool - and each of those stages checks for
# what it needs with require_command. Checking here as well is what turns "the
# build stopped two hours in" into "install these first", which is the whole job
# of this file.
commands+=(aclocal autoconf autoheader automake autoreconf libtoolize pkg-config)

# What the disk image is made of. None of it is needed to build the system - it
# is the stage that turns the assembled tree into a partitioned, bootable disk
# without root, and each of these is one step of that: mke2fs writes the ext4
# from a directory, fakeroot is what makes that directory root-owned while it is
# read, mkfs.fat and mtools build the EFI System Partition, sfdisk writes the
# partition table, grub-mkimage builds the two boot images, and qemu-img turns
# the result into the .qcow2 beside it. Checked here for the same reason
# grub-mkrescue and xorriso are: an artifact that cannot be built is better said
# at the start than two hours in.
commands+=(fakeroot mke2fs mkfs.fat mcopy mmd sfdisk grub-mkimage qemu-img)

# meson and ninja, for the one stage that needs them. plocate is a meson project
# and has no other build system, so this is not a preference the stage could
# work around - without these two it cannot be built at all.
commands+=(meson ninja)

missing=()
for command_name in "${commands[@]}"; do
    command -v "${command_name}" >/dev/null 2>&1 || missing+=("${command_name}")
done

if ((${#missing[@]})); then
    printf 'Missing host commands:' >&2
    printf ' %s' "${missing[@]}" >&2
    printf '\n' >&2
    exit 1
fi

[[ "$(uname -s)" == Linux ]] || die "the bootstrap currently requires a Linux host"
[[ "$(uname -m)" == x86_64 ]] || die "the initial port currently requires an x86_64 host"
[[ "${EUID}" -ne 0 ]] || die "build as an unprivileged user, not root"

gcc_major="$(gcc -dumpfullversion -dumpversion | cut -d. -f1)"
((gcc_major >= 10)) || die "host GCC 10 or newer is required"

# zlib's headers, which no command in the list above implies. Stage host/python
# compiles a CPython for this machine, and the last step of the CPython cross
# build uses it to read a zip - the bundled pip wheel - which
# zipfile cannot do without the extension. Nothing notices until that step, so a
# build host without them loses a compile to a missing header. A preprocessor
# run is enough to know.
printf '#include <zlib.h>\n' | gcc -E -x c - > /dev/null 2>&1 \
    || die "the zlib development headers are required"

# Go builds nic, Docker and Buildx. Every current source tree writes its floor
# in go.mod, so use an extracted tree when it is there rather than repeating a
# version that will go stale on the next bump. Before "make fetch" has ever run
# there is no extracted source to read; 1.26.3 is the highest floor among the
# pinned sources (Buildx) and therefore the safe fallback.
minimum_go=1.26.3
for go_source in nic docker-cli buildx; do
    go_mod="${SOURCE_DIR}/$(lock_record "${go_source}" | cut -d'|' -f6)/go.mod"
    [[ -f "${go_mod}" ]] || continue
    source_minimum_go="$(sed -n 's/^go[[:space:]]\{1,\}\([0-9][0-9.]*\).*/\1/p' "${go_mod}" \
        | sed -n '1p')"
    [[ -n "${source_minimum_go}" ]] || die "${go_mod} names no Go version"
    minimum_go="$(printf '%s\n%s\n' "${minimum_go}" "${source_minimum_go}" | sort -V | sed -n '$p')"
done
go_version="$(go env GOVERSION | sed 's/^go//; s/[^0-9.].*$//')"
first_version="$(printf '%s\n%s\n' "${minimum_go}" "${go_version}" | sort -V | sed -n '1p')"
[[ "${first_version}" == "${minimum_go}" ]] \
    || die "Go ${minimum_go} or newer is required by nic's go.mod"

log "host checks passed ($(gcc --version | sed -n '1p'); $(go version))"
