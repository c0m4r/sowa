#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# libcap, the POSIX capability library, and the commands that read and set
# capabilities on a file or a process.
#
# This is not the libcap-ng that packages/libcap-ng already builds. They are
# separate projects with separate APIs solving the same problem twice:
# libcap-ng is the one OpenVPN insists on, and libcap is the one BIND insists
# on. BIND 9.20 checks for it through pkg-config on any *-linux* host and stops
# if it is missing, and the --disable-linux-caps that used to refuse it was
# removed before this branch. named uses it for the same thing openvpn uses the
# other one for: keeping the capabilities it needs - binding port 53, mostly -
# across the switch to an unprivileged user.
#
# The commands come free with the library and are worth having on their own.
# The image has had no way to ask which capabilities a file or a process
# carries; setcap, getcap, getpcaps and capsh are that. As with libcap-ng's
# tools, "getcap -r /" printing nothing is the expected answer on an image that
# ships no file capabilities.
#
# libcap has a hand-written makefile that answers four questions by looking at
# the build host, which is four chances to build for the wrong machine:
#
#   lib             read out of "ldd /usr/bin/ld" - the build host's own layout
#   BUILD_CC        defaults to CC, which here is the cross compiler, and one
#                   of the programs it builds is run during the build
#   GOLANG          "is there a go on PATH" - and there is one, for nic
#   PAM_CAP         "does this host have pam_modules.h" - about the host's PAM,
#                   not the image's, which has none
#
# All four are pinned below, along with RAISE_SETFCAP, which is already no by
# default and which would otherwise run the freshly built target setcap on the
# build machine.

libcap_source="$(prepare_source libcap)"
build_tree="${BUILD_DIR}/libcap"
reset_build_dir "${build_tree}"
# libcap builds beside its sources and has no out-of-tree mode. Building in a
# copy is also what keeps the build path out of the objects: every compile runs
# in the directory holding the file it names, so __FILE__ stays relative.
cp -a "${libcap_source}/." "${build_tree}/"
pkgdir="$(pkg_stage libcap)"

target_configure_env
cd "${build_tree}"
export CPPFLAGS="-DNDEBUG"
# BUILD_CC is the build host's compiler and must stay that: libcap/_makenames
# is compiled and then run during the build to generate cap_names.h from the
# kernel header, so a cross-compiled one would not execute here.
make_arguments=(
    CROSS_COMPILE="${TARGET}-"
    BUILD_CC=gcc
    BUILD_CPPFLAGS=
    prefix=/usr
    lib=lib64
    sbin=sbin
    SHARED=yes
    PTHREADS=yes
    GOLANG=no
    PAM_CAP=no
    RAISE_SETFCAP=no
)
make -j"${JOBS}" "${make_arguments[@]}"
make "${make_arguments[@]}" DESTDIR="${pkgdir}" install

libcap_version="$(source_version libcap)"
# "make install" installs the static archive and then the shared library. The
# image ships no static libraries, so the archives go straight back out - and
# are checked for, because the plain install target is the one that puts them
# there and a later version could add another.
rm -f "${pkgdir}"/usr/lib64/*.a
[[ -z "$(find "${pkgdir}" -name '*.a' -print -quit)" ]] \
    || die "libcap installed a static library; the image ships none"

# doc/ installs a manual page for every program in the tarball, including the
# two this build does not produce: captree is written in Go, and pam_cap is the
# PAM module PAM_CAP=no refuses. A manual page for a command the image does not
# have is a worse answer than no manual page.
rm -f "${pkgdir}/usr/share/man/man8/captree.8" \
    "${pkgdir}/usr/share/man/man8/pam_cap.8"

for stem in libcap libpsx; do
    library="${pkgdir}/usr/lib64/${stem}.so.${libcap_version}"
    [[ -f "${library}" ]] || die "the ${stem} shared library was not installed"
    "${TARGET}-strip" "${library}"
    "${TARGET}-readelf" -d "${library}" | grep -q "SONAME.*${stem}\.so\.2" \
        || die "${stem} carries no soname; nothing could record a dependency on it"
    for link in "${stem}.so" "${stem}.so.2"; do
        [[ -L "${pkgdir}/usr/lib64/${link}" ]] \
            || die "the ${link} symbolic link is missing"
    done
done
for program in setcap getcap getpcaps capsh; do
    [[ -x "${pkgdir}/usr/sbin/${program}" ]] || die "libcap did not install ${program}"
    "${TARGET}-strip" "${pkgdir}/usr/sbin/${program}"
    if "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/${program}" | grep -qE 'RPATH|RUNPATH'; then
        die "${program} carries a run-time library path"
    fi
done
# The programs must resolve the library rather than carry a copy of it: the
# makefile links -lcap against the tree it just built, and a static link there
# would be silent.
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/setcap" | grep -q 'libcap.so.2' \
    || die "setcap is not linked against the shared libcap"

[[ -f "${pkgdir}/usr/include/sys/capability.h" ]] \
    || die "sys/capability.h was not installed"
# BIND's configure finds this library through pkg-config and nothing else.
pkgconfig_file="${pkgdir}/usr/lib64/pkgconfig/libcap.pc"
[[ -f "${pkgconfig_file}" ]] || die "the libcap pkg-config file was not installed"
grep -q '^libdir=/usr/lib64$' "${pkgconfig_file}" \
    || die "libcap.pc does not point at /usr/lib64"
for page in man8/setcap.8 man8/getcap.8 man1/capsh.1 man3/cap_get_proc.3; do
    [[ -f "${pkgdir}/usr/share/man/${page}" ]] \
        || die "the ${page} manual page was not installed"
done
# The one function named uses to keep CAP_NET_BIND_SERVICE across setuid, read
# back from the library.
library="${pkgdir}/usr/lib64/libcap.so.${libcap_version}"
"${TARGET}-nm" -D --defined-only "${library}" | grep -qE ' T cap_set_proc(@|$)' \
    || die "libcap does not export cap_set_proc"
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${library}" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "libcap was not built with the cross compiler"
# The Go bindings are a second implementation of the same library that ships in
# the same tarball. GOLANG=no is what keeps them out; this is that flag read
# back from the result, since the build prints no warning when it finds a Go.
[[ ! -e "${pkgdir}/usr/share/gocode" ]] \
    || die "libcap installed its Go bindings; GOLANG=no did not take"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "libcap installed files containing the build path: ${leaked}"
pkg_merge libcap
log "installed libcap ${libcap_version}"
