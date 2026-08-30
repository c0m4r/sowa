#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GNU autoconf, so the image can configure the autotools trees it can already
# compile. It installs no compiled program: autoconf is Perl and shell driving
# m4, and both of those are in the image ahead of it.
#
# Two host paths get written into the installed scripts, and both are the reason
# this stage is longer than it looks. autom4te records the m4 it was configured
# with, and every program here carries a #! line naming the Perl that configure
# found. Neither can be probed on the target, so both are pinned to the path the
# image puts them at and the build host is required to agree.
#
# The m4 version matters beyond the path. autoconf pre-freezes its macro files
# into the .m4f form m4 loads directly, freezing happens on the build host, and
# a frozen file is only guaranteed to load in the m4 that wrote it. Requiring
# the host's m4 to be the exact version this image ships is what keeps the
# shipped .m4f files loadable by the shipped m4.

require_command perl
require_command m4

target_m4=/usr/bin/m4
target_perl=/usr/bin/perl
[[ -x "${target_m4}" ]] \
    || die "the build host has no ${target_m4}; autoconf bakes that path into autom4te"
[[ -x "${target_perl}" ]] \
    || die "the build host has no ${target_perl}; autoconf bakes that path into its #! lines"
host_m4_version="$("${target_m4}" --version | sed -n '1s/.* //p')"
image_m4_version="$(source_version m4)"
[[ "${host_m4_version}" == "${image_m4_version}" ]] \
    || die "host m4 is ${host_m4_version} but the image ships ${image_m4_version}; the frozen .m4f files would be written by one and read by the other"

autoconf_source="$(prepare_source autoconf)"
build_tree="${BUILD_DIR}/autoconf"
reset_build_dir "${build_tree}"
# Built in a copy of the source rather than beside it. Freezing a macro file
# records the path m4 was given for it, and that path is then printed in every
# diagnostic the frozen file can produce - so an out-of-tree build, where srcdir
# is absolute, ships four .m4f files quoting the builder's home directory. In
# tree the recorded paths are relative.
cp -a "${autoconf_source}/." "${build_tree}/"
pkgdir="$(pkg_stage autoconf)"

build_triplet="$(gcc -dumpmachine)"
cd "${build_tree}"
# target_configure_env is deliberately not called. Nothing here is compiled, and
# a CC pointing at the cross compiler would only give configure a C compiler it
# has no use for; what it does need - m4, perl and awk - are host programs
# running on host data.
./configure \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    M4="${target_m4}" \
    PERL="${target_perl}" \
    EMACS=no
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

for program in autoconf autoheader autom4te autoreconf autoscan autoupdate ifnames; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] || die "autoconf did not install ${program}"
done
# The frozen macro files. Without them autoconf still works and every run pays
# to re-read the whole of m4sugar and autoconf's own macros first, so their
# absence is a quiet tenfold slowdown rather than a failure.
for frozen in autoconf/autoconf.m4f m4sugar/m4sugar.m4f m4sugar/m4sh.m4f \
    autotest/autotest.m4f; do
    [[ -s "${pkgdir}/usr/share/autoconf/${frozen}" ]] \
        || die "${frozen} was not frozen; autoconf would reparse its macros on every run"
done
# The two pinned paths, checked in what was actually installed rather than in
# what configure was told.
grep -q "^#! *${target_perl}" "${pkgdir}/usr/bin/autom4te" \
    || die "autom4te does not name ${target_perl}; it would not run on the image"
grep -q "${target_m4}" "${pkgdir}/usr/bin/autom4te" \
    || die "autom4te does not name ${target_m4}; it would look for m4 somewhere the image has none"
while IFS= read -r script; do
    head -n 1 "${script}" | grep -qE "^#! *(${target_perl}|/bin/sh)" \
        || die "$(basename "${script}") has a #! line the image cannot run: $(head -n 1 "${script}")"
done < <(find "${pkgdir}/usr/bin" -maxdepth 1 -type f -perm -u+x -print)
[[ -f "${pkgdir}/usr/share/man/man1/autoconf.1" ]] \
    || die "the autoconf manual page was not installed"
# autoconf is the package most likely to publish a build path, because so much
# of what it installs is generated text rather than compiled code.
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "autoconf installed files containing the build path: ${leaked}"
pkg_merge autoconf
log "installed GNU autoconf $(source_version autoconf)"
