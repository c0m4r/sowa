#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Sowa Monitor is repository-owned source and has no upstream archive to
# prepare. It is optional because publishing host telemetry is an explicit
# administrator decision; the image still carries Python, its only runtime
# dependency.
pkgdir="$(pkg_stage sowa-monitor)"
source_dir="${PROJECT_ROOT}/src/sowa-monitor"

install -D -m 0755 "${source_dir}/sowa-monitor" \
    "${pkgdir}/usr/sbin/sowa-monitor"
install -D -m 0755 "${source_dir}/sowa-monitor.init" \
    "${pkgdir}/etc/rc.d/init.d/sowa-monitor"
install -D -m 0644 "${source_dir}/index.html" \
    "${pkgdir}/usr/share/sowa-monitor/index.html"
install -D -m 0644 "${source_dir}/dashboard.css" \
    "${pkgdir}/usr/share/sowa-monitor/dashboard.css"
install -D -m 0644 "${source_dir}/dashboard.js" \
    "${pkgdir}/usr/share/sowa-monitor/dashboard.js"
install -D -m 0644 "${source_dir}/nginx.conf.example" \
    "${pkgdir}/usr/share/doc/sowa-monitor/nginx.conf.example"
install -D -m 0644 "${source_dir}/sowa-monitor.8" \
    "${pkgdir}/usr/share/man/man8/sowa-monitor.8"

[[ -x "${pkgdir}/usr/sbin/sowa-monitor" ]] \
    || die "the Sowa monitor backend was not installed"
[[ -x "${pkgdir}/etc/rc.d/init.d/sowa-monitor" ]] \
    || die "the Sowa monitor init script was not installed"
[[ -f "${pkgdir}/usr/share/sowa-monitor/index.html" ]] \
    || die "the Sowa monitor dashboard was not installed"
[[ -f "${pkgdir}/usr/share/doc/sowa-monitor/nginx.conf.example" ]] \
    || die "the Sowa monitor nginx example was not installed"

# Compile without writing host-version bytecode into the target staging tree.
# The target interpreter will compile on demand, and the source itself is what
# needs to remain portable across Python maintenance releases.
"${HOST_PYTHON}" -c \
    'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
    "${pkgdir}/usr/sbin/sowa-monitor"

# These are security properties, not documentation: no IP listener, no command
# execution, a mandatory privilege drop for root, and an exact static route map.
grep -q 'socketserver.UnixStreamServer' "${pkgdir}/usr/sbin/sowa-monitor" \
    || die "the Sowa monitor is not bound to a Unix socket"
grep -q 'refusing to serve as root' "${pkgdir}/usr/sbin/sowa-monitor" \
    || die "the Sowa monitor no longer refuses to remain root"
if grep -Eq 'subprocess|os\.system|shell=True' "${pkgdir}/usr/sbin/sowa-monitor"; then
    die "the read-only Sowa monitor contains command-execution code"
fi
grep -q 'do_POST = reject_method' "${pkgdir}/usr/sbin/sowa-monitor" \
    || die "the Sowa monitor does not explicitly reject POST"
grep -q 'frame-ancestors.*none' "${pkgdir}/usr/sbin/sowa-monitor" \
    || die "the Sowa monitor no longer sends its anti-framing policy"

pkg_keep_staged sowa-monitor
log "staged Sowa Monitor ${DISTRO_VERSION} for the repository"
