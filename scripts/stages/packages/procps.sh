#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# procps-ng: ps, top, free, uptime, vmstat, w, sysctl, pgrep, pkill, pidof,
# watch and the rest of the /proc tools, plus libproc2 behind them. Nothing
# else in the image reads /proc on anyone's behalf, so this is the whole of
# that answer.
#
# top and watch are the reason this links ncurses, and the reason it is built
# after it.

procps_source="$(prepare_source procps)"
build_tree="${BUILD_DIR}/procps"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage procps)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# Sowa's ncurses is built with the terminfo half in a library of its own, so
# cbreak(3) and the rest of the low-level terminal functions live in libtinfow
# rather than in libncursesw. The linker refuses to take them from a library it
# was not given, so watch has to be told about both - the same thing the htop
# stage does with CURSES_LIBS. Setting both halves of the pkg-config pair is
# what stops configure from looking for an "ncursesw" module that would answer
# with the first library alone.
export NCURSES_CFLAGS=" "
export NCURSES_LIBS='-lncursesw -ltinfow'
# --disable-kill is the one deliberate omission: util-linux already installs
# /usr/bin/kill and owns it, and two packages claiming one path is what
# "make packages" refuses to publish. The implementation already in the image
# works, so nothing built and verified has to be rebuilt to make room.
#
# systemd and elogind are not here to be found, SELinux is not in the image, and
# NUMA support would want libnuma; each is refused rather than left to whatever
# the sysroot happens to contain.
"${procps_source}/configure" \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-static \
    --disable-kill \
    --disable-numa \
    --disable-rpath \
    --enable-watch8bit \
    --enable-colorwatch \
    --without-systemd \
    --without-elogind
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

for program in ps top free uptime vmstat w sysctl pgrep pkill pidof watch \
    slabtop pmap pwdx tload; do
    [[ -x "${pkgdir}/usr/bin/${program}" || -x "${pkgdir}/usr/sbin/${program}" ]] \
        || die "procps did not install ${program}"
done
while IFS= read -r binary; do
    "${TARGET}-strip" "${binary}"
done < <(find "${pkgdir}/usr/bin" "${pkgdir}/usr/sbin" -type f -perm -u+x -print)
find "${pkgdir}/usr/lib64" -name 'libproc2.so.*.*' -exec "${TARGET}-strip" {} +

# util-linux keeps kill; nothing here may claim it.
[[ ! -e "${pkgdir}/usr/bin/kill" ]] \
    || die "procps installed kill, which util-linux already owns"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/ps" | grep -q 'libproc2.so' \
    || die "ps is not linked against the shared libproc2"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/top" | grep -q 'libncursesw.so.6' \
    || die "top was built without ncurses; it would have no screen to draw on"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/watch" | grep -q 'libncursesw.so.6' \
    || die "watch was built without ncurses"
for unwanted in libsystemd libelogind libselinux libnuma; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/ps" | grep -q "${unwanted}"; then
        die "ps links ${unwanted}; the image has no such library"
    fi
done
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/ps" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "procps was not built with the cross compiler"
pkg_merge procps
log "installed procps-ng $(source_version procps)"
