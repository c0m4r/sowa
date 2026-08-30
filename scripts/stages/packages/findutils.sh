#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

findutils_source="$(prepare_source findutils)"
build_tree="${BUILD_DIR}/findutils"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage findutils)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
"${findutils_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --without-selinux
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

# GNU locate is not shipped: plocate answers the names locate and updatedb and
# keeps a different database in a different format, so findutils' copy of the
# two programs - and frcode, which builds that database - is removed after the
# install. findutils has no configure switch that skips locate; it is always
# built, which is what makes this a removal rather than a build without it.
rm -f "${pkgdir}/usr/bin/locate" "${pkgdir}/usr/bin/updatedb" \
    "${pkgdir}/usr/libexec/frcode"
rm -f "${pkgdir}/usr/share/man/man1/locate.1" \
    "${pkgdir}/usr/share/man/man1/updatedb.1" \
    "${pkgdir}/usr/share/man/man5/locatedb.5"

for program in find xargs; do
    "${TARGET}-readelf" -h "${pkgdir}/usr/bin/${program}" > /dev/null 2>&1 \
        && "${TARGET}-strip" "${pkgdir}/usr/bin/${program}"
done
for program in find xargs; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] \
        || die "findutils did not install ${program}"
done
# The locate programs and their pages are gone, or they would be the GNU ones
# shadowing plocate's. The locatedb.5 man page is checked too: it describes a
# database format nothing in the image writes any more.
for removed in usr/bin/locate usr/bin/updatedb usr/libexec/frcode \
    usr/share/man/man1/locate.1 usr/share/man/man1/updatedb.1 \
    usr/share/man/man5/locatedb.5; do
    [[ ! -e "${pkgdir}/${removed}" ]] \
        || die "findutils still installs ${removed}, which plocate owns"
done
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/find" | grep -q 'libc.so.6'
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/find" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "find was not built with the cross compiler"
pkg_merge findutils
log "installed findutils $(source_version findutils)"
