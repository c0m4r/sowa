#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# plocate: a locate(1) that answers from a compressed trigram index.
#
# This replaces GNU findutils' locate rather than sitting beside it: findutils
# no longer installs locate or updatedb, and this package answers both names.
# locate is a symlink to plocate, and updatedb is plocate's own database
# builder, installed under the name upstream gives it. findutils used to keep
# its updatedb at /usr/bin/updatedb, and that path must now stay empty of the
# GNU program - which is what packages/findutils.sh removes.
#
# Upstream's privilege separation is deliberately not reproduced. plocate is
# normally setgid to a "plocate" group that owns a 0640 database, so an
# unprivileged user can search paths they could not list themselves and plocate
# filters the answers. That needs a file owned by a group other than root, and
# this image has no way to ship one: the squashfs is built -all-root, and the
# package database records a mode per file but no owner. Setgid to root - the
# only group there is - would be a privilege handed out for nothing, so the
# binary is left unprivileged and the group is root, which makes the database
# root-owned and 0640: plocate here is a root tool, as updatedb already was.
#
# This is the first meson build in the tree, and meson does not cross-compile
# from the environment the way an autotools configure does. CC and friends are
# read for the *build* machine only; everything about the host machine comes
# from a cross file, which is written below. Two consequences worth stating:
#
#   - "meson setup" fails outright if the cross file names a compiler it cannot
#     run, so a mistake here is immediate rather than a build that quietly
#     produced x86_64 host binaries.
#   - meson runs pkg-config through the cross file's own entry, not through
#     PKG_CONFIG. The three cross variables are still exported, because the
#     wrapper meson invokes reads them, but the cross file is what points it at
#     a pkg-config in the first place.

require_command meson
require_command ninja

plocate_source="$(prepare_source plocate)"
build_tree="${BUILD_DIR}/plocate"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage plocate)"

target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"

# The cross file. sys_root is what makes meson's pkg-config answers point into
# the sysroot rather than at the build host's /usr, and pkg_config_libdir is the
# same restriction stated where meson itself will read it: without it a host
# liburing.pc would be found and plocate would be built against a library the
# image does not have.
cross_file="${build_tree}/cross.ini"
mkdir -p "${build_tree}"
cat > "${cross_file}" <<EOF
[binaries]
c = '${TARGET}-gcc'
cpp = '${TARGET}-g++'
ar = '${TARGET}-ar'
strip = '${TARGET}-strip'
pkg-config = 'pkg-config'

[properties]
sys_root = '${SYSROOT}'
pkg_config_libdir = '${SYSROOT}/usr/lib64/pkgconfig'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

# --buildtype=release rather than the project's own debugoptimized default: the
# default is -O2 -g, and the -g is a debug section per object that the strip
# below would remove anyway after compiling it.
#
# install_systemd=false because there is no systemd here; left at its default
# meson probes for a systemd.pc, finds none in the sysroot and skips the units
# quietly, which is the right outcome reached by autodetection - the one thing
# this build does not leave to chance. install_cron is already false upstream,
# and stays that way: the script it installs converts an mlocate database, and
# this image has never had one.
#
# --sharedstatedir=/var/lib puts the database at /var/lib/plocate/plocate.db.
# meson's default for it is ${prefix}/com, which would be /usr/com - a path from
# a different tradition that nothing here would ever look in.
meson setup "${build_tree}/obj" "${plocate_source}" \
    --cross-file="${cross_file}" \
    --prefix=/usr \
    --bindir=bin \
    --sbindir=sbin \
    --libdir=lib64 \
    --mandir=share/man \
    --sharedstatedir=/var/lib \
    --buildtype=release \
    -Dinstall_systemd=false \
    -Dinstall_cron=false \
    -Dlocategroup=root

ninja -C "${build_tree}/obj" -j "${JOBS}"
DESTDIR="${pkgdir}" ninja -C "${build_tree}/obj" install

# meson's install_mode asks for a setgid binary owned root:root here, which an
# unprivileged build cannot set and which the paragraph at the top explains is
# not wanted anyway. Every mode is assigned explicitly instead, after the strip
# that would have cleared the bit, and read back.
"${TARGET}-strip" "${pkgdir}/usr/bin/plocate" \
    "${pkgdir}/usr/sbin/plocate-build" "${pkgdir}/usr/sbin/updatedb"
chmod 0755 "${pkgdir}/usr/bin/plocate" \
    "${pkgdir}/usr/sbin/plocate-build" "${pkgdir}/usr/sbin/updatedb"
[[ "$(stat -c %a "${pkgdir}/usr/bin/plocate")" == 755 ]] \
    || die "plocate is setgid; this image has no group to be setgid to but root"

# locate is the name people type, and plocate is meant to answer it; the
# symlink is how the search binary is reached as locate, where findutils used
# to install a program of its own. updatedb is a separate binary in sbin, not a
# second link to this one.
ln -sfn plocate "${pkgdir}/usr/bin/locate"

cross_gcc_version="$("${CC}" -dumpfullversion)"
for program in usr/bin/plocate usr/sbin/plocate-build usr/sbin/updatedb; do
    [[ -x "${pkgdir}/${program}" ]] || die "${program} was not installed"
    # The version the cross compiler stamps into .comment, as packages/tar
    # checks it. The cross file is the only thing pointing meson at that
    # compiler, so this is what catches a cross file meson quietly ignored.
    "${TARGET}-readelf" -p .comment "${pkgdir}/${program}" \
        | grep -q "GCC: (GNU) ${cross_gcc_version}" \
        || die "${program} was not built with the cross compiler"
done

# What it may link, and what it may not. liburing is the one that matters: it is
# optional, meson looks for it by pkg-config, and a build that found the host's
# would produce a plocate the image cannot run. The absence is asserted rather
# than assumed, because the failure is a binary that looks fine until it is run
# on the target.
needed="$("${TARGET}-readelf" -d "${pkgdir}/usr/bin/plocate")"
grep -q 'libzstd.so.1' <<< "${needed}" || die "plocate does not link the shared libzstd"
grep -q 'libstdc++.so.6' <<< "${needed}" || die "plocate does not link the shared libstdc++"
for unwanted in liburing uring; do
    if grep -q "${unwanted}" <<< "${needed}"; then
        die "plocate links ${unwanted}; the image has no io_uring library"
    fi
done
# Every library it does name has to be one the image carries.
while IFS= read -r library; do
    case "${library}" in
        libzstd.so.1|libstdc++.so.6|libm.so.6|libgcc_s.so.1|libc.so.6|libatomic.so.1) ;;
        *) die "plocate needs ${library}, which the image does not ship" ;;
    esac
done < <(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' <<< "${needed}")

# The database directory. mkdir.sh made it under the staged tree already; this
# is the assertion that --sharedstatedir landed where the man page says it does.
# 0750 because the database updatedb writes into it is 0640 root-owned,
# and a directory anyone can list is a directory that says what is in it.
[[ -d "${pkgdir}/var/lib/plocate" ]] \
    || die "the plocate database directory is not at /var/lib/plocate"
chmod 0750 "${pkgdir}/var/lib/plocate"

for page in man1/plocate.1 man8/plocate-build.8 man8/updatedb.8 \
    man5/updatedb.conf.5; do
    [[ -f "${pkgdir}/usr/share/man/${page}" ]] || die "missing man page ${page}"
done
[[ "$(readlink "${pkgdir}/usr/bin/locate")" == plocate ]] \
    || die "locate is not a symlink to plocate"
# findutils used to own locate and updatedb, and packages/findutils.sh now
# removes both. plocate's updatedb belongs in sbin - the name is now its own -
# and it must not reach /usr/bin, where findutils' used to live and where a
# leftover would be the GNU program shadowing this one.
[[ ! -e "${pkgdir}/usr/bin/updatedb" ]] \
    || die "plocate installed updatedb into /usr/bin; it belongs in /usr/sbin"
[[ -e "${pkgdir}/usr/sbin/updatedb" ]] \
    || die "plocate did not install updatedb into /usr/sbin"

pkg_merge plocate
log "installed plocate $(source_version plocate)"
