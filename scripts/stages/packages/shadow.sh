#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# shadow supplies useradd, usermod, userdel, groupadd, groupmod, groupdel,
# passwd, chage, and gpasswd together with login and su. This is the whole
# account layer rather than a corner of it:
# creating an account, changing one, moving it between groups and removing
# either, plus the two programs that authenticate somebody into one.
#
# login is on the boot path. Every getty the inittab respawns runs
# /usr/bin/login, and it is this one from here on, so the checks at the end of
# this stage are about the things that would make a machine unreachable if they
# were wrong: the binary is there, it is setuid nothing, and it is linked
# against the libxcrypt that reads the $6$ hashes in /etc/shadow.

shadow_source="$(prepare_source shadow)"
build_tree="${BUILD_DIR}/shadow"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage shadow)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# PAM, SELinux, audit, cracklib, SSSD and libbsd are all services or libraries
# Sowa does not have; refusing them is what keeps the build from depending on
# whatever the host happens to provide. Without PAM, shadow authenticates
# against /etc/shadow through crypt(3), which is what libxcrypt is in the image
# for. The subordinate-id tools stay: newuidmap and newgidmap are what an
# unprivileged user namespace needs, and the kernel now enables those.
"${shadow_source}/configure" \
    --prefix=/usr \
    --bindir=/usr/bin \
    --sbindir=/usr/sbin \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --disable-nls \
    --disable-static \
    --without-libpam \
    --without-selinux \
    --without-audit \
    --without-libcrack \
    --without-libbsd \
    --without-sssd \
    --disable-logind \
    --with-libcrypt \
    --with-yescrypt \
    --with-bcrypt \
    --enable-shadowgrp \
    --enable-subordinate-ids \
    --build="${build_triplet}" \
    --host="${TARGET}"
# shadow's configure blanks exec_prefix whenever prefix is /usr, which is how
# upstream still puts login, su and passwd in /bin and /sbin. Sowa installs
# them under /usr - bindir and sbindir above say so - but one path is computed
# from exec_prefix rather than from bindir and so does not follow: configure
# writes PASSWD_PROGRAM as "$exec_prefix/bin/passwd", which comes out as
# /bin/passwd. That is what login execs when an account's password has expired,
# and /bin holds four names of which passwd is not one, so a login that needed
# a password change would fail with "Can't execute /bin/passwd" and
# let nobody in - on a machine whose only account is root, that is the whole
# machine. Correcting the generated header is the narrowest place to say it;
# passing --exec-prefix cannot survive the blanking, and -D cannot win against
# a config.h that defines it again.
sed -i 's|^#define PASSWD_PROGRAM .*|#define PASSWD_PROGRAM "/usr/bin/passwd"|' config.h
grep -qx '#define PASSWD_PROGRAM "/usr/bin/passwd"' config.h \
    || die "the generated config.h does not define PASSWD_PROGRAM where expected"
# The hashing method login.defs names below only exists if libxcrypt offered it
# to configure; without this the value is rejected at run time and every
# password quietly falls back to SHA-512.
grep -qx '#define USE_YESCRYPT 1' config.h \
    || die "shadow was configured without yescrypt; ENCRYPT_METHOD YESCRYPT would be refused"
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

# coreutils installs /usr/bin/groups and shadow installs its own; two packages
# claiming one path is what "make packages" refuses to publish. Keep the
# coreutils implementation already present in the image.
rm -f "${pkgdir}/usr/bin/groups" "${pkgdir}/usr/share/man/man1/groups.1"
# util-linux already owns nologin, and /etc/passwd points the sshd and nobody
# accounts at it.
rm -f "${pkgdir}/usr/sbin/nologin" "${pkgdir}/usr/share/man/man8/nologin.8"

# useradd creates a mailbox under MAIL_DIR for every account it makes, and
# reports "Creating mailbox file: No such file or directory" when that directory
# is not there. Sowa has no mail transfer agent and no /var/spool/mail, so the
# setting is commented out rather than the directory invented: a machine that
# installs an MTA can put the line back, and until then useradd stops warning
# about a mailbox nothing would ever read.
sed -i 's|^MAIL_DIR\(\s\)|#MAIL_DIR\1|' "${pkgdir}/etc/login.defs"
! grep -qE '^MAIL_DIR' "${pkgdir}/etc/login.defs" \
    || die "login.defs still defines MAIL_DIR; useradd would look for a spool the image has not got"

# Upstream ships ENCRYPT_METHOD commented out, and what shadow falls back to
# then is DES - 56 bits and eight significant characters, from 1979. libxcrypt
# is built here with yescrypt as its gensalt default (see
# packages/libxcrypt.sh), so that is what passwd is told to write. The $6$
# SHA-512 hashes an older Sowa wrote still verify: the method named here
# decides what new passwords look like, not what can be read.
#
# --with-yescrypt above is what makes the name mean anything: without it shadow
# rejects the value at runtime ("Invalid ENCRYPT_METHOD value: 'YESCRYPT'"),
# falls back to SHA512, and says so on every password change.
sed -i 's|^#\?ENCRYPT_METHOD .*|ENCRYPT_METHOD YESCRYPT|' "${pkgdir}/etc/login.defs"
grep -qx 'ENCRYPT_METHOD YESCRYPT' "${pkgdir}/etc/login.defs" \
    || die "login.defs does not select a password hashing method; passwd would write DES"

# And with no mail spool there is nothing for login to look in, so it stops
# greeting every login with "No mail."
sed -i 's|^MAIL_CHECK_ENAB\(\s.*\)|MAIL_CHECK_ENAB\tno|' "${pkgdir}/etc/login.defs"

# CONSOLE names the file listing the terminals root may log in on, and shadow
# treats a missing one as "all of them" - which is what Sowa has been relying
# on, by accident, since it ships no /etc/securetty. The line goes rather than
# the file being invented, because the decision it would record is the wrong
# one for this system: the inittab runs a getty per console, an installed
# machine may put its console on a port no list here could have guessed, and
# the failure mode of an incomplete securetty is root being refused at the one
# terminal someone is standing at. Ship a securetty listing every getty device
# and put this line back to reverse it.
sed -i 's|^CONSOLE\(\s\)|#CONSOLE\1|' "${pkgdir}/etc/login.defs"
! grep -qE '^CONSOLE\s' "${pkgdir}/etc/login.defs" \
    || die "login.defs still names a securetty file the image does not ship"

# useradd reads this file for the answers it was not given, and creates it from
# its built-in defaults if it is missing. Shipping it is how the one deviation
# from those defaults gets written down where "useradd -D" will show it.
install -D -m 0644 /dev/stdin "${pkgdir}/etc/default/useradd" <<'DEFAULTS'
# /etc/default/useradd - what useradd assumes when it is not told otherwise.
# "useradd -D" prints these; "useradd -D -s /bin/sh" and friends rewrite them.
#
# CREATE_MAIL_SPOOL is the line Sowa changes. The base system has no mail
# transfer agent and no mail spool, so a mailbox per account would be a file
# nothing writes and nothing reads - and useradd would only report that it could
# not create it. Install an MTA, make its spool directory, put MAIL_DIR back in
# /etc/login.defs, and set this to yes.
HOME=/home
INACTIVE=-1
EXPIRE=
SHELL=/bin/bash
CREATE_MAIL_SPOOL=no
DEFAULTS

for program in useradd usermod userdel groupadd groupmod groupdel \
    grpck pwck vipw vigr newusers chpasswd pwconv grpconv; do
    [[ -x "${pkgdir}/usr/sbin/${program}" ]] || die "shadow did not install ${program}"
done
for program in login su passwd chage chfn chsh gpasswd newgrp; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] || die "shadow did not install ${program}"
done
[[ -f "${pkgdir}/etc/login.defs" ]] || die "shadow did not install /etc/login.defs"
[[ -f "${pkgdir}/etc/default/useradd" ]] || die "the useradd defaults were not installed"

while IFS= read -r binary; do
    mode="$(stat -c '%a' "${binary}")"
    "${TARGET}-strip" "${binary}"
    # strip clears the setuid bit, and passwd without it is a passwd no
    # unprivileged account can run.
    chmod "${mode}" "${binary}"
done < <(find "${pkgdir}/usr/bin" "${pkgdir}/usr/sbin" -type f -perm -u+x -print)

# The two that have to be setuid root to work at all, and the one that must not
# be: login is started by init as root and drops privilege itself.
for program in passwd su; do
    [[ "$(stat -c '%a' "${pkgdir}/usr/bin/${program}")" == 4755 ]] \
        || die "shadow ${program} is not setuid root; an unprivileged user could not run it"
done
[[ "$(stat -c '%a' "${pkgdir}/usr/bin/login")" == 755 ]] \
    || die "shadow login is setuid; init runs it as root and it drops privilege itself"

"${TARGET}-readelf" -d "${pkgdir}/usr/bin/login" | grep -q 'libcrypt.so.2' \
    || die "login does not link libxcrypt; it could not check a password in /etc/shadow"
passwd_paths="$("${TARGET}-strings" "${pkgdir}/usr/bin/login" \
    | grep -o '/[a-z/]*bin/passwd' | sort -u | tr '\n' ' ')"
[[ "${passwd_paths}" == "/usr/bin/passwd " ]] \
    || die "login looks for passwd at: ${passwd_paths:-nowhere}"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/login" | grep -q 'libc.so.6'
for unwanted in libpam libselinux libaudit libcrack libbsd; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/login" | grep -q "${unwanted}"; then
        die "login links ${unwanted}; the image has no such library"
    fi
done
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/sbin/useradd" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "shadow was not built with the cross compiler"
pkg_merge shadow
log "installed shadow $(source_version shadow)"
