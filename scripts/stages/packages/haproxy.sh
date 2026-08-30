#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

haproxy_source="$(prepare_source haproxy)"
build_tree="${BUILD_DIR}/haproxy"
reset_build_dir "${build_tree}"
# HAProxy has no configure and no out-of-tree build, so the checksum-verified
# unpacked source is copied and built from the copy.
cp -a "${haproxy_source}/." "${build_tree}/"
pkgdir="$(pkg_stage haproxy)"

target_configure_env
cd "${build_tree}"

# HAProxy is configured on the make command line rather than by a configure
# script. TARGET names the platform's syscall and polling support; everything
# else here is a deliberate yes or no:
#
#   USE_OPENSSL   TLS, from the image's own OpenSSL
#   USE_ZLIB      compression, from the image's own zlib
#   USE_PROMEX    the built-in Prometheus exporter, which needs nothing else
#   USE_LUA/PCRE2 refused: neither is in the image, and HAProxy's own regular
#                 expression engine falls back to the libc's without them
#
# libcrypt comes with linux-glibc, because HAProxy checks userlist passwords
# with crypt(3) - the one libxcrypt provides now that glibc does not.
make_options=(
    TARGET=linux-glibc
    CC="${CC}"
    LD="${CC}"
    USE_OPENSSL=1
    USE_ZLIB=1
    USE_PROMEX=1
    USE_LUA=
    USE_PCRE=
    USE_PCRE2=
    USE_SYSTEMD=
)
make -j"${JOBS}" "${make_options[@]}"
make "${make_options[@]}" install \
    DESTDIR="${pkgdir}" \
    PREFIX=/usr \
    SBINDIR=/usr/sbin \
    MANDIR=/usr/share/man \
    DOCDIR=/usr/share/doc/haproxy

"${TARGET}-strip" "${pkgdir}/usr/sbin/haproxy"
# The service. HAProxy is not in the image, so the root filesystem overlay -
# where every other init script in Sowa comes from - cannot carry this one: a
# path the image already has is a conflict an optional package is refused for.
# It is Sowa's own source, like src/init and the Guix glue; the service files in
# the upstream archive do not match Sowa's init framework or configuration
# layout.
#
# It arrives switched off and is left that way. Installing a load balancer is
# not deciding that this machine is one, and config/hooks/haproxy.hooks does not
# enable it either; "chkconfig haproxy on" is the whole of that decision.
install -D -m 0755 "${PROJECT_ROOT}/src/haproxy/haproxy" \
    "${pkgdir}/etc/rc.d/init.d/haproxy"

# HAProxy ships no default configuration and refuses to start without a proxy
# to run, so the package provides one that is useful on its own: the built-in
# statistics page, which is also where the Prometheus exporter is reachable.
# Replacing it is the first thing anyone installing HAProxy does.
install -d -m 0755 "${pkgdir}/etc/haproxy"
cat > "${pkgdir}/etc/haproxy/haproxy.cfg" <<'CONFIGURATION'
# Sowa's default HAProxy configuration. Nothing starts HAProxy at boot: the
# package ships /etc/rc.d/init.d/haproxy switched off, because installing a load
# balancer is not the same decision as running one. Both halves of turning it on:
#
#   chkconfig haproxy on     # at the next boot
#   service haproxy start    # and now
#
# "service haproxy reload" applies a change to this file without dropping the
# connections that are established, and "service haproxy configtest" checks one
# without applying it.

global
    maxconn 4096
    # HAProxy's own logging is left off and what it writes to stderr is what
    # the init script redirects. The image has a syslog daemon and a "log"
    # line here would reach it; whether a proxy's request log belongs in
    # /var/log/messages is the administrator's decision, not this file's.

defaults
    mode    http
    option  httplog
    timeout connect 5s
    timeout client  30s
    timeout server  30s

# Until this file describes a real service, the only thing HAProxy listens on
# is its own statistics page, with the Prometheus exporter under /metrics.
frontend stats
    bind *:8404
    stats enable
    stats uri /
    stats refresh 10s
    http-request use-service prometheus-exporter if { path /metrics }
CONFIGURATION
chmod 0644 "${pkgdir}/etc/haproxy/haproxy.cfg"

[[ -x "${pkgdir}/usr/sbin/haproxy" ]] || die "haproxy was not installed"
[[ -x "${pkgdir}/etc/rc.d/init.d/haproxy" ]] \
    || die "the haproxy init script was not installed; the package could not start at boot"
# "reload" means a SIGUSR2 re-exec rather than a restart, and that only exists in
# master-worker mode. Losing the -W would leave a reload that signals a process
# which treats SIGUSR2 as nothing at all and reports success.
grep -q -- '-W -db -f' "${pkgdir}/etc/rc.d/init.d/haproxy" \
    || die "the haproxy init script does not start a master-worker HAProxy; its reload would do nothing"
[[ -f "${pkgdir}/usr/share/man/man1/haproxy.1" ]] \
    || die "the haproxy manual page was not installed"
[[ -f "${pkgdir}/etc/haproxy/haproxy.cfg" ]] \
    || die "the haproxy configuration was not installed"
for library in libssl.so.3 libcrypto.so.3 libz.so.1 libcrypt.so.2; do
    "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/haproxy" | grep -q "${library}" \
        || die "haproxy was not linked against ${library}"
done
if "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/haproxy" | grep -q 'liblua\|libpcre'; then
    die "haproxy links Lua or PCRE; the image has neither"
fi
if grep -q "${WORK_DIR}" "${pkgdir}/usr/sbin/haproxy"; then
    die "the haproxy binary records the build directory"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/sbin/haproxy" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "haproxy was not built with the cross compiler"
# haproxy is published to the repository and installed on demand; it is not part
# of the image, so its staged tree is never merged into the sysroot.
pkg_keep_staged haproxy
log "installed haproxy $(source_version haproxy) into the package staging tree"
