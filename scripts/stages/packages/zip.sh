#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Info-ZIP zip.
#
# Info-ZIP stopped releasing in 2008, leaving build fixes for newer compilers
# and security fixes outside an upstream release. Sowa uses a downstream patch
# series pinned by SHA-256 rather than vendoring those patches or shipping the
# 2008 code unchanged. The series is applied in order with patch(1); a patch
# that no longer applies stops the build rather than being skipped.

zip_source="$(prepare_source zip)"
patch_archive="$(locked_download_path zip-patches)"
build_tree="${BUILD_DIR}/zip"
reset_build_dir "${build_tree}"
cp -a "${zip_source}/." "${build_tree}/"
pkgdir="$(pkg_stage zip)"

require_command patch
# The patch archive has no versioned top-level source directory, so it is taken
# apart beside the build rather than through prepare_source.
patch_dir="${BUILD_DIR}/zip-patches"
reset_build_dir "${patch_dir}"
validate_archive_members "${patch_archive}"
tar -xf "${patch_archive}" -C "${patch_dir}" debian/patches
series="${patch_dir}/debian/patches/series"
[[ -f "${series}" ]] || die "the zip patch archive has no series file"
applied=0
while IFS= read -r patch_name; do
    [[ -n "${patch_name}" && "${patch_name}" != \#* ]] || continue
    patch --directory="${build_tree}" --strip=1 --forward --silent \
        --input="${patch_dir}/debian/patches/${patch_name}" \
        || die "the zip patch ${patch_name} does not apply"
    applied=$((applied + 1))
done < "${series}"
log "applied ${applied} patches from $(source_version zip-patches)"

target_configure_env
cd "${build_tree}"
# unix/configure compiles and runs small probes to decide what the C library
# has, the way nginx's does, which works because Sowa's target architecture is
# the build host's - scripts/host-check.sh insists on that.
LDFLAGS="" sh unix/configure "${CC}" "-O2 -Wall -I. -DUNIX"
make -f unix/Makefile -j"${JOBS}" generic CC="${CC}"
# BINDIR and MANDIR are the makefile's own variables; its defaults are
# /usr/local/bin and $(prefix)/man, and Sowa puts manual pages under
# /usr/share/man like every other package here.
make -f unix/Makefile install \
    prefix="${pkgdir}/usr" \
    BINDIR="${pkgdir}/usr/bin" \
    MANDIR="${pkgdir}/usr/share/man/man1"

for program in zip zipcloak zipnote zipsplit; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] || die "zip did not install ${program}"
    "${TARGET}-strip" "${pkgdir}/usr/bin/${program}"
done
[[ -f "${pkgdir}/usr/share/man/man1/zip.1" ]] || die "the zip manual page was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/zip" | grep -q 'libc.so.6'
"${TARGET}-readelf" -h "${pkgdir}/usr/bin/zip" \
    | grep -q 'Advanced Micro Devices X86-64' \
    || die "zip was not built for the target architecture"
pkg_merge zip
log "installed Info-ZIP zip $(source_version zip)"
