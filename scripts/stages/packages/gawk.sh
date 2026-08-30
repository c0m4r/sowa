#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

gawk_source="$(prepare_source gawk)"
build_tree="${BUILD_DIR}/gawk"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage gawk)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# The dynamic extensions are left out: they are shared objects loaded by
# @load, nothing in the image uses one, and building them would put a libtool
# module tree into a base system that only wants an awk. MPFR and readline are
# refused for the same reason the other base utilities refuse their optional
# libraries - neither is in the sysroot, and an awk that linked the host's would
# not run on the target.
"${gawk_source}/configure" \
    --prefix=/usr \
    --libexecdir=/usr/libexec \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-extensions \
    --disable-mpfr \
    --without-readline
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/bin/gawk"
# gawk's install hook links gawk-<version> and awk to it. The second is the
# point of the package: /usr/bin/awk is the name scripts actually call.
[[ -x "${pkgdir}/usr/bin/gawk" ]] || die "gawk was not installed"
[[ -L "${pkgdir}/usr/bin/awk" ]] || die "gawk did not install the awk link"
[[ "$(readlink "${pkgdir}/usr/bin/awk")" == gawk ]] \
    || die "/usr/bin/awk does not point at gawk"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/gawk" | grep -q 'libc.so.6'
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/gawk" | grep -q 'libmpfr\|libreadline'; then
    die "gawk links MPFR or readline; neither is part of the image"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/gawk" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "gawk was not built with the cross compiler"
pkg_merge gawk
log "installed gawk $(source_version gawk)"
