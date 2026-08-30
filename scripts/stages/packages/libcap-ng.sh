#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# libcap-ng, the library for reading and setting POSIX capability sets.
#
# It is in the image because OpenVPN 2.7 will not configure without it: on
# Linux that check is unconditional - there is no --without-libcap-ng to give
# it - and openvpn uses the library for the one thing capabilities are actually
# good for here, keeping CAP_NET_ADMIN across the --user and --group it drops
# to, so a tunnel can still change routes after it has stopped being root.
#
# The tools that come with it earn their place separately: pscap and netcap say
# which processes and which listening sockets hold which capabilities, and
# filecap says which files carry them. The image ships no file capabilities at
# all, so "filecap -a /" printing nothing is the expected answer rather than a
# broken one.
#
# Upstream stopped publishing release tarballs after 0.8.5, so the source is
# now the git tag, which carries no configure script and has autogen.sh generate
# one. That makes this the third stage, with packages/mtr and packages/libuv,
# that needs the autotools on the build host, and the reason the verified source
# is copied before it is built: autogen.sh writes into the directory it runs
# in, and the tree under work/sources is shared with every later build.
#
# Three of its parts are declined here. The Python bindings are refused rather
# than left to configure, which would find the host interpreter and swig and
# build bindings for the wrong Python on the wrong architecture. cap-audit, new
# in 0.9, is left at its default off: it is a BPF program that clang and bpftool
# compile against libbpf and libaudit, none of which is in this build. And
# captest went behind --enable-deprecated in 0.9.3, which is not asked for - it
# reports the capabilities of the process it runs in, which is what "pscap $$"
# answers.

# What autogen.sh runs: autoreconf, and through it the other five.
require_command autoreconf
require_command libtoolize
require_command aclocal
require_command autoconf
require_command autoheader
require_command automake
# PKG_PROG_PKG_CONFIG is new in 0.9's configure.ac, and comes from pkg.m4, which
# ships with pkg-config rather than with autoconf. Without it aclocal leaves the
# macro unexpanded and configure fails somewhere far less obvious.
require_command pkg-config

libcap_ng_source="$(prepare_source libcap-ng)"
build_tree="${BUILD_DIR}/libcap-ng"
reset_build_dir "${build_tree}"
cp -a "${libcap_ng_source}/." "${build_tree}/"
pkgdir="$(pkg_stage libcap-ng)"

build_triplet="$(gcc -dumpmachine)"
cd "${build_tree}"
# Run before target_configure_env: libtoolize, aclocal, autoconf, autoheader and
# automake are host programs and have no business seeing a cross compiler in CC.
# autogen.sh also touches the NEWS file that automake's GNU strictness insists
# on and that the tag archive does not carry.
./autogen.sh
[[ -x "${build_tree}/configure" ]] || die "autogen.sh did not generate a configure script"

target_configure_env
# libtool decides whether to hardcode a library directory into what it links by
# asking which directories the loader searches by default - and it asks the
# build host. The answer there may not be the target's: when /usr/lib64 is a
# symbolic link absent from ld.so.conf, the generated libtool concludes it is
# not a default path and stamps RUNPATH=/usr/lib64 into every program it links.
# On the target that is already the first directory the loader looks in. The
# 0.8.5 tarball's own libtool 2.4.7 answered with the lib64 directories and
# needed nothing here, showing how much this depends on the build machine, so
# the target's answer is supplied rather than probed.
export lt_cv_sys_lib_dlsearch_path_spec="/lib64 /usr/lib64 /lib /usr/lib"
./configure \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-static \
    --without-python3

# netcap's --advanced mode - the one that inventories every listener in the
# network namespace instead of only the processes that hold capabilities - is
# compiled in only when the sock_diag headers are found, and configure settles
# for a warning when they are not. They come from the kernel headers in the
# sysroot, so this is decided by toolchain/03-linux-headers rather than by
# anything on the build host, and a silent "no" would quietly ship the smaller
# netcap.
grep -q '^#define HAVE_NETCAP_ADVANCED 1$' config.h \
    || die "netcap was configured without --advanced; the sock_diag headers are missing from the sysroot"
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

# libtool leaves a .la beside every library it installs. There is no libtool on
# the target to read them, and the ones it writes name the staging directory by
# absolute path, so they are removed rather than shipped.
rm -f "${pkgdir}"/usr/lib64/*.la

library="$(find "${pkgdir}/usr/lib64" -type f -name 'libcap-ng.so.0*' -print -quit)"
[[ -n "${library}" ]] || die "the libcap-ng shared library was not installed"
"${TARGET}-strip" "${library}"
# The LD_PRELOAD shim that drops the ambient capability set from a program that
# cannot be taught to do it itself. It is installed with the library it belongs
# to rather than left behind.
ambient="$(find "${pkgdir}/usr/lib64" -type f -name 'libdrop_ambient.so.0*' -print -quit)"
[[ -n "${ambient}" ]] || die "libdrop_ambient was not installed"
"${TARGET}-strip" "${ambient}"
for tool in netcap pscap filecap; do
    [[ -x "${pkgdir}/usr/bin/${tool}" ]] || die "libcap-ng ${tool} was not installed"
    "${TARGET}-strip" "${pkgdir}/usr/bin/${tool}"
done
[[ ! -e "${pkgdir}/usr/bin/captest" ]] \
    || die "captest was installed; it is deprecated upstream and the image does not carry it"

# Upstream installs its completions as a single file named after the project,
# into the directory bash-completion reads - where nothing will ever load it:
# the loader looks for completions/<command>, on demand, under the name being
# completed. One file registers all three tools, so it is installed under the
# first of those names with the other two pointing at it. It also completes
# cap-audit, which this build does not produce; a completion for an absent
# command costs nothing.
completions="${pkgdir}/usr/share/bash-completion/completions"
[[ -f "${completions}/libcap-ng.bash_completion" ]] \
    || die "the libcap-ng bash completions were not installed"
mv "${completions}/libcap-ng.bash_completion" "${completions}/pscap"
ln -sf pscap "${completions}/netcap"
ln -sf pscap "${completions}/filecap"

[[ -L "${pkgdir}/usr/lib64/libcap-ng.so" ]] \
    || die "the libcap-ng linker symbolic link is missing; OpenVPN could not link against it"
[[ -f "${pkgdir}/usr/include/cap-ng.h" ]] || die "cap-ng.h was not installed"
# OpenVPN's configure finds this library through pkg-config and nothing else,
# so a missing .pc file is a build that stops two stages later.
[[ -f "${pkgdir}/usr/lib64/pkgconfig/libcap-ng.pc" ]] \
    || die "the libcap-ng pkg-config file was not installed"
[[ -f "${pkgdir}/usr/share/man/man3/capng_apply.3" ]] \
    || die "the libcap-ng manual pages were not installed"
[[ -f "${pkgdir}/usr/share/man/man8/pscap.8" ]] \
    || die "the libcap-ng tool manual pages were not installed"
# netcap.8 is generated from netcap.8.in by config.status, which cuts the
# --advanced sections out of it when the mode was not built. Reading the flag
# back out of the installed page is what says the two agree.
grep -q '^\.B \\-\\-advanced$' "${pkgdir}/usr/share/man/man8/netcap.8" \
    || die "netcap.8 does not document --advanced; the page and the binary disagree"
"${TARGET}-readelf" -d "${library}" | grep -q 'libcap-ng.so.0' \
    || die "libcap-ng was built without the expected SONAME"
"${TARGET}-nm" -D --defined-only "${library}" | grep -qE ' T capng_change_id(@|$)' \
    || die "libcap-ng does not export capng_change_id; OpenVPN calls it to drop privilege"
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/pscap" | grep -qE 'RPATH|RUNPATH'; then
    die "pscap carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${library}" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "libcap-ng was not built with the cross compiler"
# Built in a copy of the source rather than beside it, so a build path has a
# tree to leak into that an out-of-tree build did not give it.
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "libcap-ng installed files containing the build path: ${leaked}"
pkg_merge libcap-ng
log "installed libcap-ng $(source_version libcap-ng)"
