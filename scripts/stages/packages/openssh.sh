#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

openssh_source="$(prepare_source openssh)"
build_tree="${BUILD_DIR}/openssh"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage openssh)"

build_triplet="$(sh "${openssh_source}/config.guess")"
target_configure_env
# OpenSSH links its configure probes with $LD rather than the compiler driver,
# so the cross binutils linker cannot be left in the environment. OpenSSL, zlib
# and libcrypt are found through the compiler's own sysroot; --with-ssl-dir and
# --with-zlib would point the search at ${SYSROOT}/usr/lib, and Sowa keeps its
# 64-bit libraries in /usr/lib64.
export LD="${CC}"
cd "${build_tree}"
"${openssh_source}/configure" \
    --prefix=/usr \
    --sysconfdir=/etc/ssh \
    --libexecdir=/usr/lib/openssh \
    --mandir=/usr/share/man \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-privsep-path=/var/empty \
    --with-privsep-user=sshd \
    --with-pid-dir=/run \
    --with-default-path=/bin:/sbin:/usr/bin:/usr/sbin \
    --with-superuser-path=/bin:/sbin:/usr/bin:/usr/sbin \
    --with-sandbox=seccomp_filter \
    --disable-lastlog \
    --without-pam \
    --without-selinux \
    --without-kerberos5 \
    --without-libedit \
    --without-security-key-builtin \
    --disable-strip
make -j"${JOBS}"
# install-nokeys skips the "ssh-keygen -A" and "sshd -t" steps of the default
# install target; both would run target binaries on the build host, and host
# keys belong to the running system, not the image (see sowa-sshd-keygen).
make DESTDIR="${pkgdir}" install-nokeys

for binary in usr/bin/ssh usr/bin/scp usr/bin/sftp usr/bin/ssh-add \
    usr/bin/ssh-agent usr/bin/ssh-keygen usr/bin/ssh-keyscan usr/sbin/sshd \
    usr/lib/openssh/sshd-session usr/lib/openssh/sshd-auth \
    usr/lib/openssh/sftp-server usr/lib/openssh/ssh-keysign \
    usr/lib/openssh/ssh-pkcs11-helper usr/lib/openssh/ssh-sk-helper; do
    [[ -f "${pkgdir}/${binary}" ]] || die "OpenSSH did not install ${binary}"
    # ssh-keysign is installed setuid root; strip must not clear its mode.
    mode="$(stat -c '%a' "${pkgdir}/${binary}")"
    "${TARGET}-strip" "${pkgdir}/${binary}"
    chmod "${mode}" "${pkgdir}/${binary}"
done

[[ -d "${pkgdir}/var/empty" ]] || die "the privilege separation directory was not created"
[[ -f "${pkgdir}/etc/ssh/moduli" ]] || die "the moduli file was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/sshd" | grep -q 'libcrypto.so.3'
"${TARGET}-readelf" -d "${pkgdir}/usr/lib/openssh/sshd-auth" | grep -q 'libcrypt.so.2'
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/ssh" | grep -q 'libz.so.1'
# Password authentication has to reach the $6$ hashes shadow's passwd writes, and
# the privilege-separated network code has to keep its seccomp sandbox.
grep -q '^#define HAVE_CRYPT_H 1' config.h \
    || die "OpenSSH was built without crypt(3); password authentication would fail"
grep -q '^#define SANDBOX_SECCOMP_FILTER 1' config.h \
    || die "OpenSSH was built without the seccomp sandbox"
grep -q '^#define DISABLE_LASTLOG 1' config.h \
    || die "OpenSSH was built with lastlog support; Sowa has no lastlog database"
pkg_merge openssh
log "installed OpenSSH $(source_version openssh)"
