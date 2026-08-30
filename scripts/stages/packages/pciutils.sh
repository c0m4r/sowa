#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# pciutils supplies the user-facing PCI tools, the PCI name database they read,
# and libpci for programs built on the target. The database is kept compressed:
# both libpci and lshw can read pci.ids.gz, and the current release's 500 KiB
# archive would otherwise become a roughly 1.5 MiB text file in the image.
#
# The hand-written configure script has four host-sensitive defaults. Zlib and
# DNS are detected by reading this machine's /usr/include, while libkmod and
# libudev are found through this machine's pkg-config. Every one is pinned
# below: zlib is in Sowa, DNS lookup and the two device-manager integrations are
# not, and no library from the build host may decide the result.

pciutils_source="$(prepare_source pciutils)"
build_tree="${BUILD_DIR}/pciutils"
reset_build_dir "${build_tree}"
# Upstream builds in its source tree. A copy keeps generated config.h, manual
# pages and objects out of the verified source extraction.
cp -a "${pciutils_source}/." "${build_tree}/"
pkgdir="$(pkg_stage pciutils)"

pciutils_version="$(source_version pciutils)"
target_configure_env
cd "${build_tree}"
make_arguments=(
    CROSS_COMPILE="${TARGET}-"
    HOST="${TARGET}"
    PREFIX=/usr
    BINDIR=/usr/bin
    SBINDIR=/usr/sbin
    SHAREDIR=/usr/share
    IDSDIR=/usr/share/hwdata
    MANDIR=/usr/share/man
    INCDIR=/usr/include
    LIBDIR=/usr/lib64
    PKGCFDIR=/usr/lib64/pkgconfig
    ZLIB=yes
    DNS=no
    SHARED=yes
    LIBKMOD=no
    HWDB=no
    PKG_CONFIG=/bin/false
    STRIP=
    "OPT=-O2 -DNDEBUG"
)
make -j"${JOBS}" "${make_arguments[@]}"
make "${make_arguments[@]}" DESTDIR="${pkgdir}" install
# install-lib is the development half: headers, the unversioned linker name,
# and libpci.pc. The image carries a compiler, so a library without these would
# be usable by pciutils itself and by nothing built on the target.
make "${make_arguments[@]}" DESTDIR="${pkgdir}" install-lib

library="${pkgdir}/usr/lib64/libpci.so.${pciutils_version}"
[[ -f "${library}" ]] || die "the libpci shared library was not installed"
"${TARGET}-strip" "${library}"
for program in usr/bin/lspci usr/sbin/setpci usr/sbin/pcilmr; do
    [[ -x "${pkgdir}/${program}" ]] || die "pciutils did not install /${program}"
    "${TARGET}-strip" "${pkgdir}/${program}"
    needed="$("${TARGET}-readelf" -d "${pkgdir}/${program}")"
    grep -q 'Shared library: \[libpci.so.3\]' <<< "${needed}" \
        || die "/${program} is not linked against the shared libpci"
    if grep -qE 'RPATH|RUNPATH' <<< "${needed}"; then
        die "/${program} carries a run-time library path"
    fi
done

for link in libpci.so libpci.so.3; do
    [[ -L "${pkgdir}/usr/lib64/${link}" ]] \
        || die "the ${link} symbolic link is missing"
done
[[ "$(readlink "${pkgdir}/usr/lib64/libpci.so")" == libpci.so.3 ]] \
    || die "libpci.so does not point at the ABI soname"
[[ "$(readlink "${pkgdir}/usr/lib64/libpci.so.3")" == "libpci.so.${pciutils_version}" ]] \
    || die "libpci.so.3 does not point at this release"
library_dynamic="$("${TARGET}-readelf" -d "${library}")"
grep -q 'SONAME.*libpci\.so\.3' <<< "${library_dynamic}" \
    || die "libpci carries no ABI soname"
grep -q 'Shared library: \[libz.so.1\]' <<< "${library_dynamic}" \
    || die "libpci was built without compressed PCI ID support"
if grep -qE 'libudev|libkmod|libresolv|RPATH|RUNPATH' <<< "${library_dynamic}"; then
    die "libpci acquired a disabled host-dependent feature"
fi
library_exports="$("${TARGET}-nm" -D --defined-only "${library}")"
grep -qE ' T pci_alloc(@|$)' <<< "${library_exports}" \
    || die "libpci does not export pci_alloc"
[[ -z "$(find "${pkgdir}" -name '*.a' -print -quit)" ]] \
    || die "pciutils installed a static library; the image ships none"

for header in config.h header.h pci.h types.h; do
    [[ -f "${pkgdir}/usr/include/pci/${header}" ]] \
        || die "pciutils did not install pci/${header}"
done
pkgconfig_file="${pkgdir}/usr/lib64/pkgconfig/libpci.pc"
[[ -f "${pkgconfig_file}" ]] || die "pciutils did not install libpci.pc"
grep -q '^libdir=/usr/lib64$' "${pkgconfig_file}" \
    || die "libpci.pc does not point at /usr/lib64"
grep -q '^idsdir=/usr/share/hwdata$' "${pkgconfig_file}" \
    || die "libpci.pc does not name the PCI ID database directory"

ids="${pkgdir}/usr/share/hwdata/pci.ids.gz"
[[ -s "${ids}" ]] || die "pciutils did not install pci.ids.gz"
gzip -t "${ids}"
read -r vendor_count class_count < <(
    gzip -cd "${ids}" | awk '
        /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]  / { vendors++ }
        /^C / { classes++ }
        END { print vendors + 0, classes + 0 }
    '
)
((vendor_count > 1000 && class_count > 10)) \
    || die "the PCI ID database is incomplete (${vendor_count} vendors, ${class_count} classes)"

update_ids="${pkgdir}/usr/sbin/update-pciids"
[[ -x "${update_ids}" ]] || die "pciutils did not install update-pciids"
grep -q '^DEST=/usr/share/hwdata/pci.ids.gz$' "${update_ids}" \
    || die "update-pciids would update a database libpci does not read"
grep -q '^PCI_COMPRESSED_IDS=1$' "${update_ids}" \
    || die "update-pciids would replace the compressed database with plain text"
for page in man8/lspci.8 man8/setpci.8 man8/pcilmr.8 \
    man8/update-pciids.8 man7/pcilib.7 man5/pci.ids.5; do
    [[ -f "${pkgdir}/usr/share/man/${page}" ]] \
        || die "pciutils did not install ${page}"
done

# Execute version-only paths through the target loader. Besides proving the
# binaries are runnable, this catches a shared libpci installed under the right
# name but with an unresolved dependency.
target_loader="${SYSROOT}/lib64/ld-linux-x86-64.so.2"
[[ -x "${target_loader}" ]] || die "the target dynamic loader is missing"
target_library_path="${pkgdir}/usr/lib64:${SYSROOT}/usr/lib64:${SYSROOT}/lib64"
lspci_version="$(
    "${target_loader}" --library-path "${target_library_path}" \
        "${pkgdir}/usr/bin/lspci" --version
)"
[[ "${lspci_version}" == "lspci version ${pciutils_version}" ]] \
    || die "lspci reports '${lspci_version}', not ${pciutils_version}"

cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${library}" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "pciutils was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] \
    || die "pciutils installed files containing the build path: ${leaked}"

pkg_merge pciutils
log "installed pciutils ${pciutils_version}"
