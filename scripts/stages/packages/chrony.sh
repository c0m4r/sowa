#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

chrony_source="$(prepare_source chrony)"
build_tree="${BUILD_DIR}/chrony"
reset_build_dir "${build_tree}"
# chrony builds in its source tree, so the checksum-verified unpacked source is
# copied and built from the copy.
cp -a "${chrony_source}/." "${build_tree}/"
pkgdir="$(pkg_stage chrony)"

target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"

# chrony has a hand-written configure that reads CC from the environment and
# compiles - but never runs - its probes, so the cross compiler is all it needs.
# What it would otherwise get wrong is the system it is building for: it asks
# uname what kernel it is on, and the answer has to be the kernel Sowa ships,
# not the one the build host happens to be running.
#
# Every optional dependency is refused. NTS needs gnutls or nettle, neither of
# which is in the sysroot - chrony has no OpenSSL backend to fall back on - so
# it is turned off by name rather than by absence. Without libcap there is
# nothing to drop privileges to, so chronyd stays root, which is also what the
# shipped inittab starts it as.
./configure \
    --prefix=/usr \
    --bindir=/usr/bin \
    --sbindir=/usr/sbin \
    --sysconfdir=/etc \
    --mandir=/usr/share/man \
    --docdir=/usr/share/doc/chrony \
    --localstatedir=/var \
    --chronyrundir=/run/chrony \
    --chronyvardir=/var/lib/chrony \
    --with-pidfile=/run/chrony/chronyd.pid \
    --host-system=Linux \
    --host-release="$(source_version linux)" \
    --host-machine="${PKG_ARCH}" \
    --disable-nts \
    --disable-readline \
    --without-editline \
    --without-nettle \
    --without-gnutls \
    --without-nss \
    --without-tomcrypt \
    --without-libcap \
    --without-seccomp
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/sbin/chronyd"
"${TARGET}-strip" "${pkgdir}/usr/bin/chronyc"

# chrony ships example configurations but installs none of them, so the default
# is Sowa's own and belongs to this package rather than to the overlay. The
# public sources are the only time sources the image can assume; a machine that
# has one on its own network only has to replace those lines.
install -d -m 0755 "${pkgdir}/etc"
cat > "${pkgdir}/etc/chrony.conf" <<'CONFIGURATION'
# Sowa's default chrony configuration. chronyd is started by /etc/inittab and
# logs to /var/log/chronyd.log rather than through syslog, so that what a time
# daemon says about the clock is in one file and does not have to be picked out
# of everything else the machine said.

# Where to get the time from. Any number of source lines may replace these.
pool pool.ntp.org iburst
server time.cloudflare.com iburst

# What the clock's measured drift is, so a restart does not start from nothing.
driftfile /var/lib/chrony/drift

# Step the clock instead of slewing it if it is more than a second out in the
# first three updates. A machine that has been off for a while, or one whose
# real-time clock is wrong, would otherwise take hours to converge.
makestep 1.0 3

# Keep the kernel's real-time clock in step with the system clock.
rtcsync
CONFIGURATION
chmod 0644 "${pkgdir}/etc/chrony.conf"
install -d -m 0755 "${pkgdir}/var/lib/chrony"

[[ -x "${pkgdir}/usr/sbin/chronyd" ]] || die "chronyd was not installed"
[[ -x "${pkgdir}/usr/bin/chronyc" ]] || die "chronyc was not installed"
[[ -f "${pkgdir}/usr/share/man/man8/chronyd.8" ]] \
    || die "the chronyd manual page was not installed"
[[ -f "${pkgdir}/etc/chrony.conf" ]] || die "the chrony configuration was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/chronyd" | grep -q 'libc.so.6'
for library in libgnutls libnettle libcap libedit libreadline; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/chronyd" | grep -q "${library}"; then
        die "chronyd links ${library}; the image has no such library"
    fi
done
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/sbin/chronyd" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "chronyd was not built with the cross compiler"
pkg_merge chrony
log "installed chrony $(source_version chrony)"
