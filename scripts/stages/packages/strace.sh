#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Sowa is x86_64-only.  Building the optional 32-bit and x32 personalities
# would require the matching compat headers and libraries, none of which are
# in the image, so make the supported personality explicit.

strace_source="$(prepare_source strace)"
build_tree="${BUILD_DIR}/strace"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage strace)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
"${strace_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --enable-mpers=no
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

program="${pkgdir}/usr/bin/strace"
[[ -x "${program}" ]] || die "strace did not install"
"${TARGET}-strip" "${program}"
[[ -x "${pkgdir}/usr/bin/strace-log-merge" ]] \
    || die "strace did not install strace-log-merge"
[[ -f "${pkgdir}/usr/share/man/man1/strace.1" ]] \
    || die "strace did not install its manual page"
if "${TARGET}-readelf" -d "${program}" | grep -qE 'RPATH|RUNPATH'; then
    die "strace carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${program}" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "strace was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "strace installed files containing the build path: ${leaked}"
pkg_merge strace
log "installed strace $(source_version strace)"
