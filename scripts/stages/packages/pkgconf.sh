#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# pkgconf, installed as both pkgconf and pkg-config.
#
# This is the other half of making the shipped GCC usable: an autotools tree
# that reaches PKG_CHECK_MODULES stops dead without a pkg-config, and so does
# every hand-written Makefile that calls "pkg-config --cflags". pkgconf is the
# maintained implementation used here; freedesktop's original pkg-config is
# unmaintained and needed a bundled glib to build. It answers to the established
# name through a symbolic link.
#
# Three paths have to be compiled in rather than left at their defaults, because
# the defaults are the ones autotools picked on the build machine: where .pc
# files live, and the system library and include directories whose -L and -I
# pkgconf is supposed to omit from its output. Getting the last two wrong is
# subtle - every build still works, but every command line grows a redundant
# -I/usr/include, which is exactly the flag that breaks a cross build later.

pkgconf_source="$(prepare_source pkgconf)"
build_tree="${BUILD_DIR}/pkgconf"
reset_build_dir "${build_tree}"
# Built in a copy of the source: libpkgconf's trace and error paths quote
# __FILE__, so an out-of-tree build - where srcdir is absolute - compiles the
# builder's home directory into the library and every command line tool.
cp -a "${pkgconf_source}/." "${build_tree}/"
pkgdir="$(pkg_stage pkgconf)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
./configure \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-static \
    --with-pkg-config-dir=/usr/lib64/pkgconfig:/usr/share/pkgconfig \
    --with-system-libdir=/usr/lib64 \
    --with-system-includedir=/usr/include
# No --disable-rpath here either, so libtool is edited the way the file stage
# edits it: left alone it stamps RUNPATH=/usr/lib64 into the binary and the
# library, which is the loader's default search path anyway.
sed -i -e 's|^hardcode_libdir_flag_spec=.*|hardcode_libdir_flag_spec=""|' \
    -e 's|^runpath_var=LD_RUN_PATH|runpath_var=|' libtool
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

[[ -x "${pkgdir}/usr/bin/pkgconf" ]] || die "pkgconf was not installed"
# pkgconf is not the only program in the tarball: pccritic, bomtool and spdxtool
# come with it and are installed alongside. They are small, they document
# themselves with a manual page each, and leaving them out would mean pruning a
# tree upstream expects to be whole - so they ship, and they are stripped here
# with everything else rather than one binary at a time.
while IFS= read -r binary; do
    "${TARGET}-strip" "${binary}"
done < <(find "${pkgdir}/usr/bin" -type f -perm -u+x -print)
find "${pkgdir}/usr/lib64" -name 'libpkgconf.so.*.*' -exec "${TARGET}-strip" {} +
# The name every configure script and Makefile in existence actually calls. A
# relative link so it stays correct under a DESTDIR and inside the image alike.
ln -sfn pkgconf "${pkgdir}/usr/bin/pkg-config"
[[ "$(readlink "${pkgdir}/usr/bin/pkg-config")" == pkgconf ]] \
    || die "pkg-config is not a link to pkgconf"
# pkg.m4 is why aclocal can expand PKG_CHECK_MODULES. It ships with pkgconf
# rather than with autoconf, and without it an autoreconf on the image fails
# with the macro left as a literal in the generated configure.
[[ -f "${pkgdir}/usr/share/aclocal/pkg.m4" ]] \
    || die "pkg.m4 was not installed; PKG_CHECK_MODULES would not expand on the image"
for page in pkgconf.1 pkg.m4.7; do
    [[ -f "${pkgdir}/usr/share/man/man1/${page}" || -f "${pkgdir}/usr/share/man/man7/${page}" ]] \
        || die "the ${page} manual page was not installed"
done
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/pkgconf" | grep -q 'libpkgconf.so' \
    || die "pkgconf is not linked against the shared libpkgconf"
for linked in usr/bin/pkgconf usr/lib64/libpkgconf.so; do
    if "${TARGET}-readelf" -d "${pkgdir}/${linked}" | grep -qE 'RPATH|RUNPATH'; then
        die "/${linked} carries a run-time library path"
    fi
done
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/pkgconf" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "pkgconf was not built with the cross compiler"
# The compiled-in directories are the package. Ask the binary what it was built
# with rather than trusting the switches above: a typo in one of them produces a
# pkgconf that works and quietly answers with the wrong paths.
for compiled_in in /usr/lib64/pkgconfig /usr/share/pkgconfig /usr/include; do
    grep -aq "${compiled_in}" "${pkgdir}/usr/bin/pkgconf" \
        || grep -aq "${compiled_in}" "${pkgdir}/usr/lib64/libpkgconf.so" \
        || die "pkgconf was not built with ${compiled_in} compiled in"
done
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "pkgconf installed files containing the build path: ${leaked}"
pkg_merge pkgconf
log "installed pkgconf $(source_version pkgconf), also answering to pkg-config"
