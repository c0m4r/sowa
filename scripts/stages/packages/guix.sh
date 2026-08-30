#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GNU Guix, from the binary tarball its manual calls the binary installation.
#
# This is the one component Sowa does not build. Guix is a package manager
# written in Guile that bootstraps its own world: building it from source needs
# Guile, twelve Guile libraries, and a store to put them in - which is to say it
# needs Guix. Upstream's answer is a signed tarball of a working store, and
# taking that tarball is the honest way to have Guix here. It is pinned by
# SHA-256 in config/sources.lock like every other source, and nothing in it is
# compiled, linked, or relocated: the binaries inside carry their own C library
# and interpreter and refer to each other by absolute store path, which is why
# the tarball can only ever be unpacked at /gnu.
#
# What the package carries is that store and nothing else that moves:
#
#   /gnu/store/...          the 84 store items the tarball ships. A store path
#                           names its own contents, so these are immutable by
#                           construction and two versions of Guix never claim
#                           the same path - which is exactly what sowa-pkg
#                           needs in order to own, verify and upgrade them.
#   /usr/share/guix         the pristine database and the profile generation the
#                           tarball was built with, as seeds
#   the Sowa glue          sowa-guix-setup, the init script, /etc/profile.d
#
# The tarball's /var/guix is deliberately *not* packaged. It is state: the
# database records what this machine has installed and the profile links record
# which generation it is on, and an upgrade of the guix package that wrote over
# either would throw away everything the machine had done with Guix. It is
# seeded into place once, by sowa-guix-setup.

# The lock pins the x86_64-linux tarball, and the store items inside it name
# their own architecture in every ELF header and every #! line.
[[ "${PKG_ARCH}" == x86_64 ]] \
    || die "the pinned Guix binary tarball is x86_64-linux only, not ${PKG_ARCH}"

version="$(source_version guix)"
archive="$(locked_download_path guix)"
pkgdir="$(pkg_stage guix)"
validate_archive_members "${archive}"

# Nothing here is compiled, so this stage needs neither the cross toolchain nor
# the sysroot, and the two ELF checks below read the header themselves rather
# than calling a cross binutils that may not have been built yet.
elf_field() {
    od --address-radix=n --format=x1 --skip-bytes="$2" --read-bytes="$3" "$1" \
        | tr -d ' \n'
}

# Upstream extracts with --strip-components=1 to drop the leading "./", which
# would otherwise fail on a read-only root; here it is what puts gnu/ and var/
# at the top of the staging tree. --preserve-permissions keeps the store's
# read-only modes exactly as they were built rather than as the umask would
# have them.
log "unpacking the Guix store (this is ~870 MiB and takes a minute)"
tar --extract --file="${archive}" --directory="${pkgdir}" \
    --strip-components=1 --preserve-permissions ./gnu ./var

[[ -d "${pkgdir}/gnu/store" ]] || die "the tarball did not unpack a /gnu/store"
[[ -f "${pkgdir}/var/guix/db/db.sqlite" ]] \
    || die "the tarball did not unpack a store database"

# The generation root's profile starts on. It is recorded as a symbolic link so
# that what the package says and what the store holds cannot drift apart, and so
# sowa-guix-setup has one thing to read.
profile="$(readlink "${pkgdir}/var/guix/profiles/per-user/root/current-guix-1-link")"
[[ "${profile}" == /gnu/store/* ]] \
    || die "the packaged profile is not a store path: ${profile}"
[[ -d "${pkgdir}${profile}" ]] \
    || die "the profile ${profile} is not among the store items in the tarball"

install -d -m 0755 "${pkgdir}/usr/share/guix"
install -m 0644 "${pkgdir}/var/guix/db/db.sqlite" "${pkgdir}/usr/share/guix/db.sqlite"
ln -s "${profile}" "${pkgdir}/usr/share/guix/current-guix"
rm -rf "${pkgdir:?}/var"

# The Sowa side of it: the setup that initializes Guix state, the service that
# runs the daemon, and the environment an interactive shell needs. They are
# Sowa's own sources, like src/init, rather than the service definitions in the
# upstream archive.
glue="${PROJECT_ROOT}/src/guix"
install -D -m 0755 "${glue}/sowa-guix-setup" "${pkgdir}/usr/sbin/sowa-guix-setup"
install -D -m 0755 "${glue}/guix-daemon" "${pkgdir}/etc/rc.d/init.d/guix-daemon"
install -D -m 0644 "${glue}/guix.sh" "${pkgdir}/etc/profile.d/guix.sh"
# What makes "guix" a command for every user, root included, before anyone has
# run "guix pull". Upstream puts this in /usr/local/bin; Sowa has no
# /usr/local, and /usr/bin is what its PATH has always been.
install -d -m 0755 "${pkgdir}/usr/bin"
ln -s /var/guix/profiles/per-user/root/current-guix/bin/guix "${pkgdir}/usr/bin/guix"

# The store item the profile is built out of, found by name rather than by the
# hash of a particular build.
mapfile -t guix_items < <(find "${pkgdir}/gnu/store" -maxdepth 1 -type d \
    -name "*-guix-${version}" -print)
((${#guix_items[@]} == 1)) \
    || die "expected exactly one guix-${version} store item, found ${#guix_items[@]}"
guix_item="${guix_items[0]}"

# bin/guix is a Guile script and bin/guix-daemon is an ELF binary, and between
# them they are the whole command surface. Both name what they run by absolute
# store path - the interpreter on the first line of the one, the C library in
# the other - which makes the tarball portable and means a check cannot simply
# ask this host whether the path is there. The script's interpreter is looked
# for in the staged tree instead, and the binaries' headers are read where they
# actually are.
[[ -x "${guix_item}/bin/guix" ]] || die "the tarball has no guix command"
interpreter="$(sed -n '1s|^#!\([^[:space:]]*\).*|\1|p' "${guix_item}/bin/guix")"
[[ "${interpreter}" == /gnu/store/* ]] \
    || die "the guix command does not name a store interpreter: ${interpreter:-none}"
[[ -x "${pkgdir}${interpreter}" ]] \
    || die "the guix interpreter ${interpreter} is not among the store items"

for program in "${pkgdir}${interpreter}" "${guix_item}/bin/guix-daemon"; do
    [[ -x "${program}" ]] || die "${program##*/} is missing or not executable"
    [[ "$(elf_field "${program}" 0 4)" == 7f454c46 ]] \
        || die "${program##*/} is not an ELF binary"
    # e_machine, the two bytes at offset 18: 0x3e is EM_X86_64.
    [[ "$(elf_field "${program}" 18 2)" == 3e00 ]] \
        || die "${program##*/} was not built for x86_64"
done
[[ -f "${pkgdir}${profile}/etc/profile" ]] \
    || die "the packaged profile has no etc/profile"
for key in bordeaux.guix.gnu.org ci.guix.gnu.org; do
    [[ -f "${guix_item}/share/guix/${key}.pub" ]] \
        || die "the tarball has no substitute key for ${key}"
done

# A store is only worth anything if it is closed: every absolute store path a
# store item points at has to be in the tree as well, or the first thing that
# follows the link on an installed system falls off the end of it. This is the
# symbolic-link half of that - the references recorded in the database are the
# other half, and the daemon is what checks those.
missing="$(find "${pkgdir}/gnu" -type l -printf '%l\n' \
    | sort -u \
    | while IFS= read -r target; do
        [[ "${target}" == /gnu/store/* ]] || continue
        [[ -e "${pkgdir}${target}" ]] || printf '%s\n' "${target}"
    done)"
[[ -z "${missing}" ]] \
    || die "the store refers to items it does not carry: $(printf '%s' "${missing}" | sed -n '1,3p' | tr '\n' ' ')"

items="$(find "${pkgdir}/gnu/store" -mindepth 1 -maxdepth 1 -printf '.' | wc -c)"
# Guix is published to the repository and never enters the image: an 870 MiB
# store has no business in an initramfs the machine boots from RAM.
pkg_keep_staged guix
log "installed GNU Guix ${version} into the package staging tree (${items} store items)"
