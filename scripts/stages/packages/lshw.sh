#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# lshw presents the whole hardware tree rather than one kernel interface: DMI,
# CPU, memory, storage, network, USB and PCI data all meet in one report. Only
# the command-line program is built; the optional GTK interface would add a
# desktop stack to a console system.
#
# Its release tarball carries a PCI database of its own, but pciutils ships a
# newer one at /usr/share/hwdata/pci.ids.gz and lshw already searches that path.
# The private copy is removed after installation so the two commands name a
# device from one maintained database instead of disagreeing according to
# which release happened to be newer. The package dependency records that data
# relationship explicitly.

require_command msgfmt
lshw_source="$(prepare_source lshw)"
build_tree="${BUILD_DIR}/lshw"
reset_build_dir "${build_tree}"
# The makefiles compile beside the sources and quote relative file names, so a
# copied in-tree build stays reproducible without putting the checkout path in
# assertions or diagnostics embedded in the binary.
cp -a "${lshw_source}/." "${build_tree}/"
pkgdir="$(pkg_stage lshw)"

lshw_version="$(source_version lshw)"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
make_arguments=(
    PREFIX=/usr
    SBINDIR=/usr/bin
    MANDIR=/usr/share/man
    DATADIR=/usr/share
    VERSION="${lshw_version}"
    NO_VERSION_CHECK=1
    SQLITE=0
    ZLIB=1
    "GZIP=gzip -9n"
    "RPM_OPT_FLAGS=-O2 -DNDEBUG"
    CXX="${CXX}"
    AR="${AR}"
    LD="${LD}"
    PKG_CONFIG=pkg-config
)
make -C src -j"${JOBS}" "${make_arguments[@]}"
make -C src "${make_arguments[@]}" DESTDIR="${pkgdir}" install

# pciutils owns the current PCI table. All of lshw's other bundled name tables
# are still useful and have no provider elsewhere in the image.
rm -f "${pkgdir}/usr/share/lshw/pci.ids" \
    "${pkgdir}/usr/share/lshw/pci.ids.gz"

program="${pkgdir}/usr/bin/lshw"
[[ -x "${program}" ]] || die "lshw was not installed into /usr/bin"
"${TARGET}-strip" "${program}"
[[ -f "${pkgdir}/usr/share/man/man1/lshw.1" ]] \
    || die "lshw did not install its manual page"
for table in usb.ids.gz oui.txt.gz manuf.txt.gz pnp.ids.gz pnpid.txt.gz; do
    [[ -s "${pkgdir}/usr/share/lshw/${table}" ]] \
        || die "lshw did not install ${table}"
    gzip -t "${pkgdir}/usr/share/lshw/${table}"
done
for language in ca es fr; do
    catalog="${pkgdir}/usr/share/locale/${language}/LC_MESSAGES/lshw.mo"
    [[ -s "${catalog}" ]] || die "lshw did not install its ${language} translation"
    # Upstream's install command has no mode and therefore makes catalogs
    # executable. They are data read by gettext, not programs.
    chmod 0644 "${catalog}"
done

dynamic="$("${TARGET}-readelf" -d "${program}")"
for required in libz.so.1 libstdc++.so.6 libgcc_s.so.1 libc.so.6; do
    grep -q "Shared library: \[${required}\]" <<< "${dynamic}" \
        || die "lshw does not link ${required}"
done
if grep -qE 'libsqlite|libresolv|RPATH|RUNPATH' <<< "${dynamic}"; then
    die "lshw acquired a disabled optional feature or run-time path"
fi
# The compiled search path is the proof that removing lshw's private pci.ids
# above still leaves its PCI names backed by the pciutils package.
grep -aqF '/usr/share/hwdata/pci.ids' "${program}" \
    || die "lshw does not search pciutils' PCI ID database"
if grep -aqF 'ezix.org' "${program}"; then
    die "lshw retained its remote version check despite NO_VERSION_CHECK=1"
fi

target_loader="${SYSROOT}/lib64/ld-linux-x86-64.so.2"
[[ -x "${target_loader}" ]] || die "the target dynamic loader is missing"
reported_version="$(
    "${target_loader}" \
        --library-path "${SYSROOT}/usr/lib64:${SYSROOT}/lib64" \
        "${program}" -version
)"
[[ "${reported_version}" == "${lshw_version}" ]] \
    || die "lshw reports '${reported_version}', not ${lshw_version}"

cross_gcc_version="$("${CXX}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${program}" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "lshw was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] \
    || die "lshw installed files containing the build path: ${leaked}"

pkg_merge lshw
log "installed lshw ${lshw_version}"
