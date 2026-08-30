#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# logrotate: the reason /var/log is not eventually the reason a machine stops.
#
# Everything this image writes it writes to a file that nothing truncated
# before this package. The rc framework's daemon helper appends each service's
# output to /var/log/<name>.log, syslog-ng writes messages, secure, cron and
# maillog, and sowa-pkg keeps a record of every transaction in
# /var/log/sowa-pkg.log. On a machine that stays up, each of those is a file
# that only grows - and a root filesystem that fills up does not announce
# itself, it just stops being writable, which is a failure that looks like
# every other failure at once.
#
# popt is built here as a private static library, the way nginx's PCRE2 is: it
# is logrotate's only dependency, it is the option parser logrotate has used
# since before getopt_long could be relied on, and nothing else in the image
# asks for it. Statically, so what the image gains is a program rather than a
# program and a library that one program uses.

popt_source="$(prepare_source popt)"
logrotate_source="$(prepare_source logrotate)"
popt_build="${BUILD_DIR}/logrotate-popt"
popt_root="${BUILD_DIR}/logrotate-popt-root"
build_tree="${BUILD_DIR}/logrotate"
reset_build_dir "${popt_build}"
reset_build_dir "${popt_root}"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage logrotate)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
# The target-side source name __FILE__ is mapped to must not contain the
# checkout path, or the leak check at the end of this stage - a substring grep
# for that path - matches the sanitised objects too. The container builds in
# /sowa, which /usr/src/sowa would contain.
export CFLAGS="${CFLAGS:-} -O2 -ffile-prefix-map=${PROJECT_ROOT}=/usr/src/logrotate"

cd "${popt_build}"
"${popt_source}/configure" \
    --prefix="${popt_root}" \
    --libdir="${popt_root}/lib" \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-shared \
    --enable-static \
    --disable-nls \
    --disable-rpath
make -j"${JOBS}"
make install
[[ -f "${popt_root}/lib/libpopt.a" ]] || die "the static popt was not built"

cd "${build_tree}"
export CPPFLAGS="-I${popt_root}/include"
export LDFLAGS="-L${popt_root}/lib"
# Three of these decide what logrotate does rather than what it is built from:
#
#   --with-state-file-path names the file that records when each log was last
#   rotated. Its default is /var/lib/logrotate.status, a file directly in
#   /var/lib; this image gives it a directory of its own so the file has an
#   owner in the package database and a mode of its own.
#
#   --with-compress-command and its extension are named by absolute path
#   because a cron job's PATH is not a login shell's, and a compress that
#   resolved to nothing would rotate the logs and then leave them uncompressed
#   with an error nobody reads.
#
#   --with-default-mail-command points at false(1). The image has no mail
#   transfer agent, so a configuration using "mail" has to fail visibly rather
#   than appear to have sent something.
#
# SELinux and POSIX ACLs are refused rather than autodetected: there is no
# policy on this system, and libacl is not in the image.
"${logrotate_source}/configure" \
    --prefix=/usr \
    --sbindir=/usr/sbin \
    --sysconfdir=/etc \
    --mandir=/usr/share/man \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --without-selinux \
    --without-acl \
    --with-state-file-path=/var/lib/logrotate/logrotate.status \
    --with-compress-command=/usr/bin/gzip \
    --with-uncompress-command=/usr/bin/gunzip \
    --with-compress-extension=.gz \
    --with-default-mail-command=/usr/bin/false
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

[[ -f "${pkgdir}/usr/sbin/logrotate" ]] \
    || die "logrotate did not install /usr/sbin/logrotate"
"${TARGET}-strip" "${pkgdir}/usr/sbin/logrotate"

# popt absorbed rather than linked: the image has no libpopt, so a build that
# found a shared one - the host's, through a stray -L - would produce a program
# that cannot start on the target.
needed="$("${TARGET}-readelf" -d "${pkgdir}/usr/sbin/logrotate")"
if grep -q 'libpopt' <<< "${needed}"; then
    die "logrotate links a shared popt; the image has no such library"
fi
while IFS= read -r library; do
    case "${library}" in
        libc.so.6 | libgcc_s.so.1) ;;
        *) die "logrotate needs ${library}, which the image does not ship" ;;
    esac
done < <(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' <<< "${needed}")
if grep -qE 'RPATH|RUNPATH' <<< "${needed}"; then
    die "logrotate carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
compiler_comment="$("${TARGET}-readelf" -p .comment \
    "${pkgdir}/usr/sbin/logrotate")"
grep -q "GCC: (GNU) ${cross_gcc_version}" <<< "${compiler_comment}" \
    || die "logrotate was not built with the cross compiler"

for page in man8/logrotate.8 man5/logrotate.conf.5; do
    [[ -f "${pkgdir}/usr/share/man/${page}" ]] \
        || die "logrotate did not install ${page}"
done

# The state file's directory, and the drop-in directory the configuration
# includes. /etc/logrotate.conf and the files below /etc/logrotate.d come from
# the overlay for the same reason sshd_config does: they are this image's
# policy about its own logs. What the build put there is removed so the two
# cannot disagree.
install -d -m 0755 "${pkgdir}/var/lib/logrotate"
rm -f "${pkgdir}/etc/logrotate.conf"
rm -rf "${pkgdir}/etc/logrotate.d"
find "${pkgdir}/etc" -type d -empty -delete 2> /dev/null || true

leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "logrotate carries a build path: ${leaked}"

# Parse the shipped policy with the target binary. Redirect its absolute log
# paths into an empty build directory so --debug never inspects the build
# host's /var/log, and point the include at the overlay drop-in that will be
# copied into the image.
shipped_config="${PROJECT_ROOT}/rootfs-overlay/etc/logrotate.conf"
shipped_rules="${PROJECT_ROOT}/rootfs-overlay/etc/logrotate.d"
probe_logs="${build_tree}/probe-logs"
probe_rules="${build_tree}/probe-rules"
probe_config="${build_tree}/sowa-logrotate.conf"
target_loader="${SYSROOT}/lib64/ld-linux-x86-64.so.2"
[[ -f "${shipped_config}" && -d "${shipped_rules}" ]] \
    || die "the shipped logrotate policy is incomplete"
mkdir -p "${probe_logs}" "${probe_rules}"
while IFS= read -r rule; do
    sed "s|/var/log|${probe_logs}|g" "${rule}" \
        > "${probe_rules}/${rule##*/}"
done < <(find "${shipped_rules}" -maxdepth 1 -type f -print | LC_ALL=C sort)
sed "s|^include /etc/logrotate.d$|include ${probe_rules}|" \
    "${shipped_config}" > "${probe_config}"
if ! "${target_loader}" \
    --library-path "${pkgdir}/usr/lib64:${SYSROOT}/usr/lib64:${SYSROOT}/lib64" \
    "${pkgdir}/usr/sbin/logrotate" --debug --state /dev/null \
    "${probe_config}" > /dev/null 2>&1; then
    die "the shipped logrotate policy does not parse"
fi

pkg_merge logrotate
log "installed logrotate $(source_version logrotate)"
