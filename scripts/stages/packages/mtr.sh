#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# mtr, which is also what the image answers the traceroute name with.
#
# mtr is traceroute and ping in one program: it walks the path once and then
# keeps probing every hop it found, so what it reports is loss and latency per
# hop over time rather than a single snapshot. That is the question anyone
# running traceroute actually has, which is why Sowa retires the traceroute name
# into a placeholder pointing here instead of building a second package for it.
#
# Upstream publishes tags, not release tarballs, so this tree has no configure
# script and the stage generates one. That is the only place in the build where
# autoconf and automake are host requirements.
#
# Two optional libraries are deliberately declined. mtr-packet gets its raw
# socket from the setuid bit set below rather than from libcap - upstream warns
# about this and it is the same trade the inetutils ping makes. GTK is refused
# outright: this is a terminal image, and configure would otherwise look for
# gtk+-3.0 through the build host's pkg-config and find the host's own.

require_command autoreconf
require_command automake
require_command aclocal
require_command autoheader
# PKG_CHECK_MODULES comes from pkg.m4, which ships with pkg-config rather than
# with autoconf. Without it aclocal expands the macro to nothing and configure
# fails somewhere far less obvious.
require_command pkg-config

mtr_source="$(prepare_source mtr)"
build_tree="${BUILD_DIR}/mtr"
reset_build_dir "${build_tree}"
# Bootstrapped in a copy: bootstrap.sh writes aclocal.m4, config.h.in, the
# Makefile.in and the build-aux scripts into the tree it runs in, and the
# unpacked source under work/sources is shared with anything else that reads it.
cp -a "${mtr_source}/." "${build_tree}/"
pkgdir="$(pkg_stage mtr)"

build_triplet="$(gcc -dumpmachine)"
cd "${build_tree}"
# Run before target_configure_env: autoconf and automake are host programs and
# have no business seeing a cross compiler in CC.
./bootstrap.sh
[[ -x "${build_tree}/configure" ]] || die "bootstrap.sh did not generate a configure script"

target_configure_env
# Sowa's ncurses is built with the terminfo half in a library of its own, and
# mtr looks for the curses functions with AC_SEARCH_LIBS against -lncursesw
# alone. That finds wprintw and stops, so the link then fails on stdscr, which
# lives in libtinfow: "DSO missing from command line". Both halves are pinned
# into the first search rather than probed - the same thing packages/procps.sh
# does with NCURSES_LIBS - and the second search is told the libraries are
# already on the line so it does not add them twice.
export ac_cv_search_wprintw='-lncursesw -ltinfow'
export ac_cv_search_initscr='none required'
# libcap is present in an incremental sysroot after its stage has run once, but
# it comes after mtr in a clean build and this package deliberately uses a
# setuid packet helper instead. Pin the Autoconf probe off so build history
# cannot silently add an undeclared libcap dependency.
ac_cv_lib_cap_cap_set_proc=no "${build_tree}/configure" \
    --prefix=/usr \
    --sbindir=/usr/sbin \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --without-gtk \
    --without-jansson
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

for program in mtr mtr-packet; do
    [[ -x "${pkgdir}/usr/sbin/${program}" ]] || die "mtr did not install ${program}"
    "${TARGET}-strip" "${pkgdir}/usr/sbin/${program}"
done
# mtr-packet is the half that opens the raw socket; mtr itself is the display
# and execs it. Only the former needs the privilege, and the mode is set after
# the strip that would have cleared it.
chmod 4755 "${pkgdir}/usr/sbin/mtr-packet"
[[ "$(stat -c '%a' "${pkgdir}/usr/sbin/mtr-packet")" == 4755 ]] \
    || die "mtr-packet must be setuid root to open a raw socket"
[[ "$(stat -c '%a' "${pkgdir}/usr/sbin/mtr")" == 755 ]] \
    || die "mtr itself must not be setuid; only mtr-packet opens a socket"
for page in mtr.8 mtr-packet.8; do
    [[ -f "${pkgdir}/usr/share/man/man8/${page}" ]] \
        || die "the ${page} manual page was not installed"
done
# Without a curses library mtr still builds, as a program that prints a report
# and exits - the "-r" mode - and never draws the live display anyone runs it
# for. That is a silent downgrade, so it is checked rather than assumed.
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/mtr" | grep -q 'libncursesw.so.6' \
    || die "mtr was built without ncurses; it would have no live display"
for program in mtr mtr-packet; do
    for unwanted in libgtk libgdk libjansson libcap.so; do
        if "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/${program}" \
            | grep -q "${unwanted}"; then
            die "${program} links ${unwanted}; it is not a declared mtr dependency"
        fi
    done
done
if "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/mtr" | grep -qE 'RPATH|RUNPATH'; then
    die "mtr carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/sbin/mtr" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "mtr was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "mtr installed files containing the build path: ${leaked}"
pkg_merge mtr
log "installed mtr $(source_version mtr)"
