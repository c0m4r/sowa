#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GNU which.
#
# Worth knowing what this program is and is not, because the name promises more
# than it delivers. GNU which searches $PATH itself and knows nothing about the
# shell it was typed into: an alias, a shell function, a builtin, or a hashed
# path all make it disagree with what the shell would actually run. Bash's own
# "type -P" and "command -v" ask the shell and are right by construction, and
# they are what this image's documentation points at. This package is here
# because the name is muscle memory and a script that calls it should find it,
# not because it is the better tool.
#
# It does try: --read-alias and --read-functions make it parse an alias or
# function list fed to it on standard input. Sowa ships the plain binary and no
# wrapper; a shell function called "which" that shadows the program it wraps is
# a surprise of its own, and the honest answer is already spelled "type".
#
# libcwd is the one thing configure would decide by looking at the build host.
# It is a C++ debugging library that nothing here has and that would make this
# a C++ program if it found one, so it is refused by name rather than by
# absence.

which_source="$(prepare_source which)"
build_tree="${BUILD_DIR}/which"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage which)"

build_triplet="$(sh "${which_source}/config.guess")"
target_configure_env
cd "${build_tree}"
"${which_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-silent-rules \
    --disable-debug \
    --disable-libcwd
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

program="${pkgdir}/usr/bin/which"
[[ -x "${program}" ]] || die "which did not install"
"${TARGET}-strip" "${program}"
[[ -f "${pkgdir}/usr/share/man/man1/which.1" ]] \
    || die "the which manual page was not installed"

# Nothing but libc. A which that had picked up libcwd would name libstdc++ as
# well, which is the shape that refusal is meant to prevent.
needed="$("${TARGET}-readelf" -d "${program}")"
grep -q 'libc\.so\.6' <<<"${needed}" || die "which is not linked against libc"
for unwanted in libstdc++ libcwd; do
    if grep -q "${unwanted}" <<<"${needed}"; then
        die "which links ${unwanted}; configure found a build-host library"
    fi
done
if grep -qE 'RPATH|RUNPATH' <<<"${needed}"; then
    die "which carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${program}" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "which was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "which installed files containing the build path: ${leaked}"
pkg_merge which
log "installed GNU which $(source_version which)"
