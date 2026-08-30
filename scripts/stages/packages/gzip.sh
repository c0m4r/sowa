#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GNU gzip: the compressor, and the z* scripts that are most of what makes it
# usable - zgrep, zdiff, zless and the rest.

gzip_source="$(prepare_source gzip)"
build_tree="${BUILD_DIR}/gzip"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage gzip)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# The scripts run whatever /bin/sh is, which here is Bash, and gzip bakes that
# path into them at configure time.
# gzip only builds zless when configure finds a less on the build host, which
# says nothing about the target - the image ships less - so force the answer.
LESS=less "${gzip_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/bin/gzip"
[[ -x "${pkgdir}/usr/bin/gzip" ]] || die "gzip was not installed"
# gunzip and zcat are the same program under other names, and the scripts are
# what a shell reaches for; both halves have to be there.
for program in gunzip zcat; do
    [[ -e "${pkgdir}/usr/bin/${program}" ]] || die "gzip did not install ${program}"
done
for script in zgrep zdiff zless zmore znew zcmp zforce gzexe; do
    [[ -x "${pkgdir}/usr/bin/${script}" ]] || die "gzip did not install ${script}"
done
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/gzip" | grep -q 'libc.so.6'
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/gzip" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "gzip was not built with the cross compiler"
pkg_merge gzip
log "installed GNU gzip $(source_version gzip)"
