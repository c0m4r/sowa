#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Info-ZIP unzip. The pinned patch series is applied for the reasons the zip
# stage gives: unzip 6.0 is from 2009, the fixes for CVE-2014-8139 through
# CVE-2022-0530 were never released upstream, and the series also makes it
# build with a compiler this new.

unzip_source="$(prepare_source unzip)"
patch_archive="$(locked_download_path unzip-patches)"
build_tree="${BUILD_DIR}/unzip"
reset_build_dir "${build_tree}"
cp -a "${unzip_source}/." "${build_tree}/"
pkgdir="$(pkg_stage unzip)"

require_command patch
patch_dir="${BUILD_DIR}/unzip-patches"
reset_build_dir "${patch_dir}"
validate_archive_members "${patch_archive}"
tar -xf "${patch_archive}" -C "${patch_dir}" debian/patches
series="${patch_dir}/debian/patches/series"
[[ -f "${series}" ]] || die "the unzip patch archive has no series file"
applied=0
while IFS= read -r patch_name; do
    [[ -n "${patch_name}" && "${patch_name}" != \#* ]] || continue
    patch --directory="${build_tree}" --strip=1 --forward --silent \
        --input="${patch_dir}/debian/patches/${patch_name}" \
        || die "the unzip patch ${patch_name} does not apply"
    applied=$((applied + 1))
done < "${series}"
log "applied ${applied} patches from $(source_version unzip-patches)"

target_configure_env
cd "${build_tree}"
# Each define is an explicit decision: UNICODE_SUPPORT and UTF8_MAYBE_NATIVE let
# unzip read UTF-8 names, DATE_FORMAT=DF_YMD makes listings sortable,
# WILD_STOP_AT_DIR keeps a wildcard from crossing a directory boundary, and
# USE_BZIP2 is why this package depends on bzip2 - a zip member may be
# bzip2-compressed, and without libbz2 unzip can only report that it cannot read
# it.
defines=(
    -DACORN_FTYPE_NFS -DWILD_STOP_AT_DIR -DLARGE_FILE_SUPPORT
    -DUNICODE_SUPPORT -DUNICODE_WCHAR -DUTF8_MAYBE_NATIVE -DNO_LCHMOD
    -DDATE_FORMAT=DF_YMD -DUSE_BZIP2 -DIZ_HAVE_UXUIDGID -DNOMEMCPY
    -DNO_WORKING_ISPRINT
)
make -f unix/Makefile -j"${JOBS}" unzips \
    CC="${CC}" \
    D_USE_BZ2=-DUSE_BZIP2 \
    L_BZ2=-lbz2 \
    CF="-O2 -Wall -I. ${defines[*]}"
make -f unix/Makefile install \
    prefix="${pkgdir}/usr" \
    BINDIR="${pkgdir}/usr/bin" \
    MANDIR="${pkgdir}/usr/share/man/man1"

# unzip installs zipinfo as a second copy of the same binary, which decides what
# it is by the name it was called with; a link says that and costs nothing.
rm -f "${pkgdir}/usr/bin/zipinfo"
ln -s unzip "${pkgdir}/usr/bin/zipinfo"

for program in unzip funzip unzipsfx; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] || die "unzip did not install ${program}"
    "${TARGET}-strip" "${pkgdir}/usr/bin/${program}"
done
[[ -x "${pkgdir}/usr/bin/zipgrep" ]] || die "unzip did not install zipgrep"
[[ -L "${pkgdir}/usr/bin/zipinfo" ]] || die "zipinfo is not linked to unzip"
[[ -f "${pkgdir}/usr/share/man/man1/unzip.1" ]] \
    || die "the unzip manual page was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/unzip" | grep -q 'libbz2.so.1.0' \
    || die "unzip was built without libbz2; it could not read bzip2 members"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/unzip" | grep -q 'libc.so.6'
pkg_merge unzip
log "installed Info-ZIP unzip $(source_version unzip)"
