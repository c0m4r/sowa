#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GNU tar.
#
# This is not only a convenience. sowa-pkg unpacks every package with whatever
# "tar" resolves to, and a tar that refuses an absolute symbolic link on
# extraction - a sound default for an archive off the network - cannot install
# the guix package at all, since its store is built out of them:
#
#   tar: unsafe absolute symbolic link "gnu/store/...-profile"
#
# GNU tar extracts what the archive says, and rejects the thing that is actually
# dangerous - a member path that escapes the destination - which is also what
# scripts/lib/common.sh checks for before any source is unpacked here.

tar_source="$(prepare_source tar)"
build_tree="${BUILD_DIR}/tar"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage tar)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# The extended-attribute, ACL and SELinux backends need libattr, libacl and
# libselinux, none of which the image has; they are refused rather than left to
# whatever the sysroot happens to contain. rmt, tar's remote-tape helper, is the
# one thing it installs outside /usr/bin, and it goes where libexecdir says;
# --with-rmt would name an external one instead and install none.
FORCE_UNSAFE_CONFIGURE=1 "${tar_source}/configure" \
    --prefix=/usr \
    --libexecdir=/usr/libexec \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --without-posix-acls \
    --without-xattrs \
    --without-selinux
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/bin/tar" "${pkgdir}/usr/libexec/rmt"
[[ -x "${pkgdir}/usr/bin/tar" ]] || die "tar was not installed"
[[ -x "${pkgdir}/usr/libexec/rmt" ]] || die "rmt was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/tar" | grep -q 'libc.so.6'
# A tar linked against a library the image does not carry would be a tar that
# cannot unpack the package that would install it.
for unwanted in libacl libattr libselinux liblzma; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/tar" | grep -q "${unwanted}"; then
        die "tar links ${unwanted}; the image has no such library"
    fi
done
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/tar" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "tar was not built with the cross compiler"
pkg_merge tar
log "installed GNU tar $(source_version tar)"
