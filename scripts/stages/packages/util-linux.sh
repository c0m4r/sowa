#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

util_linux_source="$(prepare_source util-linux)"
build_tree="${BUILD_DIR}/util-linux"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage util-linux)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
# Everything util-linux can optionally link against - systemd, libudev,
# libcap-ng, SELinux, audit, libeconf, sqlite for lastlog2 - is absent from the
# sysroot and must stay that way, so the probes look there rather than at the
# build host's development packages. ncurses is the one it does find, and cfdisk
# and more are why it is wanted.
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
# ncurses is the one optional library that is in the sysroot, and util-linux
# would rather ask ncursesw6-config about it than pkg-config. The only such
# helper on the machine is the build host's, and it describes the host's
# ncurses: one library, with no separate terminfo half. Sowa's is built with
# one, so cfdisk and irqtop would be linked without -ltinfow and fail on
# "undefined reference to stdscr". Blocking the helper - and the ncurses5 and
# non-wide spellings of it - leaves pkg-config, which is already pinned to the
# sysroot, to answer instead.
export NCURSES6_CONFIG=false NCURSESW6_CONFIG=false
export NCURSES5_CONFIG=false NCURSESW5_CONFIG=false
cd "${build_tree}"

# login, su, runuser, sulogin, chfn and chsh are deliberately not built. They
# expect PAM and a shadow suite Sowa does not ship; shadow supplies login and
# passwd, and /usr/bin/login is what the inittab's gettys are told to run -
# agetty is from this package, and its own default of /bin/login is a name the
# image deliberately does not have (see image/10-rootfs.sh). nologin *is* built,
# because /etc/passwd needs a shell for the sshd and nobody accounts and nothing
# else in the image provides one.
#
# The install steps that chown, setuid or setgid their output are disabled: the
# build runs unprivileged and the initramfs is created with --owner=0:0 anyway,
# so a build-time chown would only fail. Nothing here needs a setuid bit on a
# system whose only account is root.
"${util_linux_source}/configure" \
    --prefix=/usr \
    --bindir=/usr/bin \
    --sbindir=/usr/sbin \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-static \
    --disable-rpath \
    --disable-asciidoc \
    --disable-liblastlog2 \
    --disable-uuidd \
    --disable-pylibmount \
    --disable-login \
    --disable-su \
    --disable-runuser \
    --disable-sulogin \
    --disable-chfn-chsh \
    --disable-use-tty-group \
    --disable-makeinstall-chown \
    --disable-makeinstall-setuid \
    --disable-makeinstall-tty-setgid \
    --without-python \
    --without-systemd \
    --with-systemdsystemunitdir=no \
    --without-udev \
    --without-cap-ng \
    --without-libmagic \
    --without-libz \
    --without-readline \
    --without-utempter \
    --without-selinux \
    --without-audit \
    --without-econf \
    --with-ncursesw
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

while IFS= read -r program; do
    "${TARGET}-readelf" -h "${program}" > /dev/null 2>&1 || continue
    "${TARGET}-strip" "${program}"
done < <(find "${pkgdir}/usr/bin" "${pkgdir}/usr/sbin" -type f)
while IFS= read -r library; do
    "${TARGET}-strip" --strip-unneeded "${library}"
done < <(find "${pkgdir}/usr/lib64" -type f -name '*.so.*')

# The shipped inittab calls this mount by path and rc.sysinit mounts /proc,
# /sys, /dev, devpts and cgroup2 with it, so a build that quietly dropped it
# would leave the system with none of them.
for program in mount umount dmesg lsblk findmnt kill hexdump more flock \
    getopt mountpoint uuidgen; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] \
        || die "util-linux did not install ${program}"
done
for program in blkid fdisk sfdisk cfdisk mkfs mkswap swapon swapoff losetup \
    fsck findfs switch_root nologin wipefs hwclock; do
    [[ -x "${pkgdir}/usr/sbin/${program}" ]] \
        || die "util-linux did not install ${program}"
done
# shadow owns login, su and the password path. util-linux builds its own set
# of the same names, and those expect PAM; a second copy landing on the same
# paths would fail at the first authentication.
for program in login su runuser sulogin chsh chfn; do
    [[ ! -e "${pkgdir}/usr/bin/${program}" && ! -e "${pkgdir}/usr/sbin/${program}" ]] \
        || die "util-linux built ${program}; shadow provides the login path"
done
# e2fsprogs is built against these rather than against its own copies, which is
# what keeps one blkid and one libuuid in the image.
for library in libblkid libmount libuuid libsmartcols libfdisk; do
    [[ -f "${pkgdir}/usr/lib64/${library}.so.1" ]] \
        || die "util-linux did not install ${library}.so.1"
done
for module in blkid uuid mount; do
    [[ -f "${pkgdir}/usr/lib64/pkgconfig/${module}.pc" ]] \
        || die "util-linux did not install the ${module} pkg-config file"
done
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/mount" | grep -q 'libmount.so.1'
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/cfdisk" | grep -q 'libncursesw.so.6'
# The build host is x86_64 too, so a binary compiled with the host's own gcc
# would pass every other check here and only be noticed once the image booted.
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/mount" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "mount was not built with the cross compiler"
pkg_merge util-linux
log "installed util-linux $(source_version util-linux)"
