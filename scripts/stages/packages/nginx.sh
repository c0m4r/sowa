#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

pcre2_source="$(prepare_source pcre2)"
nginx_source="$(prepare_source nginx)"
pcre2_build="${BUILD_DIR}/pcre2"
pcre2_root="${BUILD_DIR}/pcre2-root"
build_tree="${BUILD_DIR}/nginx"
reset_build_dir "${pcre2_build}"
reset_build_dir "${pcre2_root}"
reset_build_dir "${build_tree}"
# nginx configures and builds inside its own source tree, so the
# checksum-verified unpacked source is copied and built from the copy.
cp -a "${nginx_source}/." "${build_tree}/"
pkgdir="$(pkg_stage nginx)"

build_triplet="$(sh "${pcre2_source}/config.guess")"
target_configure_env

# PCRE2 is what gives nginx its regular expressions - "location ~", the rewrite
# module, and every regex capture - so it is not optional in practice. It is
# built here as a private static library rather than as a package of its own:
# nginx is the only thing in Sowa that wants it, and an image that does not
# ship nginx has no business shipping a library for it either. Only the 8-bit
# code units nginx uses are built.
cd "${pcre2_build}"
"${pcre2_source}/configure" \
    --prefix="${pcre2_root}" \
    --libdir="${pcre2_root}/lib" \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-shared \
    --enable-static \
    --disable-pcre2-16 \
    --disable-pcre2-32 \
    --disable-pcre2grep-libz \
    --disable-pcre2grep-libbz2
make -j"${JOBS}"
make install
[[ -f "${pcre2_root}/lib/libpcre2-8.a" ]] || die "the static PCRE2 was not built"

# The build tree and the PCRE2 prefix are siblings, and nginx runs both its
# configure probes and its compiler from the top of the build tree, so the two
# flags below are given relative to it: they are baked into the binary and
# reported by "nginx -V", and an absolute path would put this checkout's
# location into a published package.
cd "${build_tree}"
# nginx's configure compiles and *runs* small probes to size the target's types.
# That works because Sowa's target architecture is the build host's - which
# scripts/host-check.sh insists on - and it is the reason there is no
# --host-style option here to pass instead.
./configure \
    --prefix=/usr/share/nginx \
    --sbin-path=/usr/sbin/nginx \
    --conf-path=/etc/nginx/nginx.conf \
    --pid-path=/run/nginx.pid \
    --lock-path=/run/nginx.lock \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --http-client-body-temp-path=/var/lib/nginx/client-body \
    --http-proxy-temp-path=/var/lib/nginx/proxy \
    --http-fastcgi-temp-path=/var/lib/nginx/fastcgi \
    --http-uwsgi-temp-path=/var/lib/nginx/uwsgi \
    --http-scgi-temp-path=/var/lib/nginx/scgi \
    --user=nobody \
    --group=nobody \
    --with-threads \
    --with-pcre \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_gzip_static_module \
    --with-http_stub_status_module \
    --with-cc-opt=-I../pcre2-root/include \
    --with-ld-opt=-L../pcre2-root/lib
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/sbin/nginx"
# The service. nginx is not in the image, so the root filesystem overlay - where
# every other init script in Sowa comes from - cannot carry this one: a path the
# image already has is a conflict an optional package is refused for. It is
# Sowa's own source, like src/init and the Guix glue, because what upstream
# ships is a systemd unit.
#
# It arrives switched off and is left that way. Deciding to install a web server
# is not deciding to publish one, and config/hooks/nginx.hooks does not enable
# it either; "chkconfig nginx on" is the whole of that decision.
install -D -m 0755 "${PROJECT_ROOT}/src/nginx/nginx" \
    "${pkgdir}/etc/rc.d/init.d/nginx"
# nginx creates these at startup and chowns them to the worker user, but only if
# it is started as root and only if their parent exists; shipping them keeps
# "nginx -t" honest for an unprivileged check as well.
for temporary in client-body proxy fastcgi uwsgi scgi; do
    install -d -m 0700 "${pkgdir}/var/lib/nginx/${temporary}"
done
# The tarball's manual page is a template; nginx's own port makefiles are what
# normally fill it in.
install -d -m 0755 "${pkgdir}/usr/share/man/man8"
sed -e 's|%%PREFIX%%|/usr/share/nginx|g' \
    -e 's|%%CONF_PATH%%|/etc/nginx/nginx.conf|g' \
    -e 's|%%ERROR_LOG_PATH%%|/var/log/nginx/error.log|g' \
    -e 's|%%PID_PATH%%|/run/nginx.pid|g' \
    "${build_tree}/man/nginx.8" > "${pkgdir}/usr/share/man/man8/nginx.8"
chmod 0644 "${pkgdir}/usr/share/man/man8/nginx.8"
! grep -q '%%' "${pkgdir}/usr/share/man/man8/nginx.8" \
    || die "the nginx manual page still has unsubstituted paths"

[[ -x "${pkgdir}/usr/sbin/nginx" ]] || die "nginx was not installed"
[[ -x "${pkgdir}/etc/rc.d/init.d/nginx" ]] \
    || die "the nginx init script was not installed; the package could not start at boot"
# The pid file the init script signals for a reload and a stop is the one the
# binary was configured to write. They are set in two different places - the
# --pid-path above and the script's own pidfile - so the pair is checked here
# rather than discovered as a stop that reports success and leaves nginx running.
grep -q '^#define NGX_PID_PATH  "/run/nginx.pid"$' objs/ngx_auto_config.h \
    || die "nginx was not built to write /run/nginx.pid, which its init script signals"
grep -q '^pidfile=/run/nginx.pid$' "${pkgdir}/etc/rc.d/init.d/nginx" \
    || die "the nginx init script does not name /run/nginx.pid"
[[ -f "${pkgdir}/etc/nginx/nginx.conf" ]] || die "the nginx configuration was not installed"
[[ -f "${pkgdir}/etc/nginx/mime.types" ]] || die "the nginx MIME type map was not installed"
[[ -f "${pkgdir}/usr/share/nginx/html/index.html" ]] \
    || die "the nginx default site was not installed"
[[ -d "${pkgdir}/var/log/nginx" ]] || die "the nginx log directory was not created"
grep -q '^#define NGX_PCRE2  *1$' objs/ngx_auto_config.h \
    || die "nginx was built without PCRE2; it would have no regular expressions"
grep -q '^#define NGX_HTTP_SSL  *1$' objs/ngx_auto_config.h \
    || die "nginx was built without TLS"
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/nginx" | grep -q 'libssl.so.3'
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/nginx" | grep -q 'libcrypto.so.3'
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/nginx" | grep -q 'libz.so.1'
# PCRE2 is linked in statically and deliberately leaves no runtime dependency,
# since nothing in the image would provide one.
if "${TARGET}-readelf" -d "${pkgdir}/usr/sbin/nginx" | grep -q 'libpcre'; then
    die "nginx links PCRE2 dynamically; the image has no such library"
fi
if grep -q "${WORK_DIR}" "${pkgdir}/usr/sbin/nginx"; then
    die "the nginx binary records the build directory"
fi
# nginx is published to the repository and installed on demand; it is not part
# of the image, so its staged tree is never merged into the sysroot.
pkg_keep_staged nginx
log "installed nginx $(source_version nginx) into the package staging tree"
