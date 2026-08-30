#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GNU less.
#
# This is the pager the rest of the image already assumes. mandoc compiles a
# pager path in as BINM_PAGER and man runs it for every page, and Git runs its
# own output through a pager for every log and diff. Both used to reach a pager
# that renders the overstruck bold and underline of a manual page as
# literal control characters instead of resolving them - the thing GNU less has
# done since it replaced more(1). mandoc used to work around that with a wrapper
# that stripped the overstriking before the pager saw it, at the cost of the
# formatting; shipping the real pager is what retires the workaround and makes
# the manual pages installed by every other package readable as written.
#
# less has one library: the terminal database. Sowa's ncurses puts the low-level
# terminal functions in libtinfow rather than in libncursesw, so the probe that
# matters here is the one for tgoto.

less_source="$(prepare_source less)"
build_tree="${BUILD_DIR}/less"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage less)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# configure looks for tgoto in -ltinfo before -ltinfow, and either answer
# produces a working less on a host that has both. This sysroot has only the
# wide library, so the first probe is a link that must fail and the second one
# a link that must succeed - and both are cross links, which configure would
# happily let the build machine's own libraries answer. They are pinned rather
# than probed, so a build host with a narrow libtinfo installed cannot select a
# library the image does not carry.
export ac_cv_lib_tinfo_tgoto=no
export ac_cv_lib_tinfow_tgoto=yes
# --with-regex is the other autodetection worth refusing. "auto" prefers PCRE2,
# then PCRE, then the POSIX functions in libc. The image's PCRE2 is a static
# copy private to nginx and Git and is not in the sysroot, so auto would land on
# POSIX anyway - but it would land there by accident, and a sysroot that later
# grew a shared PCRE2 would silently change which regular expression dialect
# "less /pattern" accepts.
"${less_source}/configure" \
    --prefix=/usr \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-regex=posix \
    --with-editor=/usr/bin/vi
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

for program in less lesskey; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] || die "less did not install ${program}"
    "${TARGET}-strip" "${pkgdir}/usr/bin/${program}"
done
# lessecho is not a command anyone runs: less execs it to expand a metacharacter
# in a filename, so it lives in libexec rather than on PATH. less-osc8-open is
# the shell script beside it that opens an OSC 8 hyperlink.
[[ -x "${pkgdir}/usr/libexec/lessecho" ]] || die "less did not install lessecho"
"${TARGET}-strip" "${pkgdir}/usr/libexec/lessecho"
[[ -x "${pkgdir}/usr/libexec/less-osc8-open" ]] \
    || die "less did not install the OSC 8 link opener"
for page in less.1 lesskey.1 lessecho.1; do
    [[ -f "${pkgdir}/usr/share/man/man1/${page}" ]] \
        || die "the ${page} manual page was not installed"
done
# The whole point of the package: without a terminal library less cannot address
# the screen, and configure will build one that scrolls by printing newlines
# rather than fail.
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/less" | grep -q 'libtinfow.so.6' \
    || die "less was built without a terminal library; it could not page a screen"
for unwanted in libpcre2 libpcre libncursesw libtinfo.so; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/less" | grep -q "${unwanted}"; then
        die "less links ${unwanted}; the image has no such library"
    fi
done
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/less" | grep -qE 'RPATH|RUNPATH'; then
    die "less carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/less" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "less was not built with the cross compiler"
pkg_merge less
log "installed GNU less $(source_version less)"
