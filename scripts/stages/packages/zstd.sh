#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Zstandard: the zstd command, its unzstd name, and libzstd.
#
# The library is why this stage runs before packages/file. file reads inside a
# compressed file to name what is in it, and libmagic can read four formats;
# three of them were already in the sysroot and this is the fourth, so that
# stage is built against this one.
#
# Two things about the build system need saying. The first is that
# programs/Makefile decides which foreign formats zstd can open by compiling a
# probe for each of zlib, lzma and lz4 and keeping whichever links. The probe
# runs the cross compiler, so it answers for this sysroot rather than for the
# build host - but it answers silently either way, and a sysroot that later
# grew an lz4 would change what the shipped binary accepts with nothing said.
# All three are pinned instead: gz and xz because the image has those
# libraries, lz4 because it has none.
#
# The second is zstd-dll. The ordinary CLI target compiles the whole library
# into the executable, which would put a second copy of the compressor in an
# image that carries libzstd.so anyway for libmagic. zstd-dll is upstream's
# target for linking the command against the shared library instead - the
# arrangement xz and liblzma already have here - and leaves the executable
# holding only the three sources that are not part of the library.

zstd_source="$(prepare_source zstd)"
build_tree="${BUILD_DIR}/zstd"
reset_build_dir "${build_tree}"
# zstd has no out-of-tree build: every makefile compiles beside its sources,
# and the CLI links against the library left sitting in lib/.
cp -a "${zstd_source}/." "${build_tree}/"
pkgdir="$(pkg_stage zstd)"

zstd_version="$(source_version zstd)"
target_configure_env
cd "${build_tree}"
# MOREFLAGS is the makefile's own hook for adding to CFLAGS without displacing
# what it puts there itself. NDEBUG belongs in it because these makefiles never
# define it: DEBUGLEVEL=0 turns off zstd's own logging and its private assert,
# but the dictionary builder's third-party divsufsort.c includes <assert.h>
# directly and keeps every assertion - along with the __FILE__ each one names,
# which is how the builder's home directory ends up as a string in the shipped
# library. The cmake and meson builds define it in their release configuration;
# this is the same thing said to the makefile.
make_arguments=(PREFIX=/usr LIBDIR=/usr/lib64 MOREFLAGS=-DNDEBUG)
# libzstd-release rather than lib-release: the latter also builds libzstd.a,
# and the image ships no static library for the reason it ships no others -
# nothing links one, and it is a second copy of the compressor again.
make -C lib -j"${JOBS}" "${make_arguments[@]}" libzstd-release
# BACKTRACE=0 is what upstream's own zstd-release target does. Left on, the CLI
# installs a SIGABRT handler that prints a stack trace through execinfo, which
# is a debugging aid for a build tree and dead weight in an image.
make -C programs -j"${JOBS}" "${make_arguments[@]}" \
    HAVE_ZLIB=1 HAVE_LZMA=1 HAVE_LZ4=0 BACKTRACE=0 zstd-dll
make -C lib "${make_arguments[@]}" DESTDIR="${pkgdir}" \
    install-shared install-includes install-pc
make -C programs "${make_arguments[@]}" DESTDIR="${pkgdir}" install

[[ -x "${pkgdir}/usr/bin/zstd" ]] || die "zstd was not installed"
"${TARGET}-strip" "${pkgdir}/usr/bin/zstd"
library="${pkgdir}/usr/lib64/libzstd.so.${zstd_version}"
[[ -f "${library}" ]] || die "the shared libzstd was not installed"
"${TARGET}-strip" "${library}"

# unzstd is the applet this package retires under its own name; zstdcat and
# zstdmt are the other two names the one binary answers to.
for link in unzstd zstdcat zstdmt; do
    [[ -L "${pkgdir}/usr/bin/${link}" ]] \
        || die "zstd did not install the ${link} link"
    [[ "$(readlink "${pkgdir}/usr/bin/${link}")" == zstd ]] \
        || die "/usr/bin/${link} does not point at zstd"
done
# Both scripts run a program from another package - zstdless sets LESSOPEN and
# execs less, zstdgrep pipes zstdcat into grep - and both of those are in the
# image, so they are shipped rather than dropped.
for script in zstdgrep zstdless; do
    [[ -x "${pkgdir}/usr/bin/${script}" ]] || die "zstd did not install ${script}"
done
for page in zstd.1 unzstd.1 zstdcat.1 zstdgrep.1 zstdless.1; do
    [[ -e "${pkgdir}/usr/share/man/man1/${page}" ]] \
        || die "the ${page} manual page was not installed"
done
for soname in libzstd.so libzstd.so.1; do
    [[ "$(readlink "${pkgdir}/usr/lib64/${soname}")" == "libzstd.so.${zstd_version}" ]] \
        || die "/usr/lib64/${soname} is not a link to libzstd.so.${zstd_version}"
done
"${TARGET}-readelf" -d "${library}" | grep -q 'SONAME.*libzstd\.so\.1' \
    || die "libzstd carries no soname; nothing could record a dependency on it"
[[ ! -e "${pkgdir}/usr/lib64/libzstd.a" ]] \
    || die "zstd installed a static library; the image ships none"
[[ -f "${pkgdir}/usr/include/zstd.h" ]] || die "zstd.h was not installed"
# The image ships a compiler and a pkg-config for it, so the .pc file has to
# name the library directory this build actually used rather than the /usr/lib
# the makefile defaults to.
pkgconfig_file="${pkgdir}/usr/lib64/pkgconfig/libzstd.pc"
[[ -f "${pkgconfig_file}" ]] || die "libzstd.pc was not installed"
# shellcheck disable=SC2016 # ${exec_prefix} is pkg-config's own variable, written literally into the file.
grep -q '^libdir=${exec_prefix}/lib64$' "${pkgconfig_file}" \
    || die "libzstd.pc does not point at /usr/lib64"

# The whole point of building zstd-dll: the command resolves the compressor
# from the shared library instead of carrying its own.
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/zstd" | grep -q 'libzstd\.so\.1' \
    || die "zstd is not linked against the shared libzstd; the image would carry two copies of the compressor"
# -W because readelf abbreviates a symbol longer than sixteen characters, and
# both of these are longer than that. The table is read once into a variable
# rather than piped: it is long enough that a "grep -q" match near the top ends
# the pipe while readelf is still writing, and under pipefail that SIGPIPE is
# the failure rather than the answer.
dynamic_symbols="$("${TARGET}-readelf" -W --dyn-syms "${pkgdir}/usr/bin/zstd")"
for undefined in ZSTD_compressStream2 ZSTD_decompressStream; do
    grep -q "UND ${undefined}$" <<<"${dynamic_symbols}" \
        || die "zstd does not resolve ${undefined} from libzstd; the library was compiled into it after all"
done
# The two formats pinned on the command line above, read back from the binary:
# the makefile would have dropped either one without failing.
for required in libz.so.1 liblzma.so.5; do
    "${TARGET}-readelf" -d "${pkgdir}/usr/bin/zstd" | grep -q "${required}" \
        || die "zstd was built without ${required}; it could not open a .gz or .xz file"
done
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/zstd" | grep -q 'liblz4'; then
    die "zstd links liblz4; the image has no such library"
fi
for linked in "usr/bin/zstd" "usr/lib64/libzstd.so.${zstd_version}"; do
    if "${TARGET}-readelf" -d "${pkgdir}/${linked}" | grep -qE 'RPATH|RUNPATH'; then
        die "/${linked} carries a run-time library path"
    fi
done
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/zstd" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "zstd was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "zstd installed files containing the build path: ${leaked}"
pkg_merge zstd
log "installed Zstandard ${zstd_version}"
