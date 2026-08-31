#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

case "${ROOTFS_DIR}" in
    "${WORK_DIR}"/*) ;;
    *) die "refusing to reset rootfs outside ${WORK_DIR}" ;;
esac
pkg_reconcile_orphaned_merges
pkg_prune_optional_sysroot_residue "${SYSROOT}"
rm -rf "${ROOTFS_DIR}"
mkdir -p "${ROOTFS_DIR}"
cp -a "${SYSROOT}/." "${ROOTFS_DIR}/"

mkdir -p "${ROOTFS_DIR}"/{bin,sbin,etc,dev,proc,sys,run,tmp,root,home,mnt,var,boot} \
    "${ROOTFS_DIR}/usr"/{bin,sbin,lib,share} \
    "${ROOTFS_DIR}/var"/{log,lib,tmp}
# /usr/local, which /etc/profile puts at the front of PATH. It is made here
# rather than shipped in the overlay because these directories are empty and
# git does not record an empty directory - a fresh checkout would produce an
# image whose PATH names four directories that do not exist. Nothing installs
# into them: they belong to whoever is running the machine, which is what makes
# them the one part of the filesystem an upgrade cannot disturb.
mkdir -p "${ROOTFS_DIR}/usr/local"/{bin,sbin,lib,include,share,etc}
# /root/.ssh, for the same reason and with the same consequence: sshd's
# StrictModes wants it private, and it is made here rather than shipped in the
# overlay because what goes in it is nobody's package. An empty
# authorized_keys once travelled in the overlay to keep git from dropping the
# directory, which made the file sowa-release's - so every upgrade of that
# package put an empty one back over whatever keys had been authorised. A
# directory is all a package can own here: apply_manifest creates one and sets
# its mode, and prune only removes it once it is empty.
install -d -m 0700 "${ROOTFS_DIR}/root/.ssh"
chmod 1777 "${ROOTFS_DIR}/tmp" "${ROOTFS_DIR}/var/tmp"
# glibc has /var/run/utmp compiled into it, and so does every program that
# records or reads a login. /run is where rc.sysinit mounts the tmpfs that
# holds it, so /var/run has to be that directory rather than one of its own on
# the root filesystem - otherwise the login is written where nothing looks.
ln -sfn ../run "${ROOTFS_DIR}/var/run"
# sshd refuses to start unless its privilege separation chroot is owned by root
# and writable by nobody else.
install -d -m 0755 "${ROOTFS_DIR}/var/empty"
# Cronie owns its crontabs here.  A root-only spool prevents direct edits;
# crontab(1) performs the required validation and atomic replacement instead.
install -d -m 0755 "${ROOTFS_DIR}/etc/cron.d"
install -d -m 0700 "${ROOTFS_DIR}/var/spool/cron"
# Older e2fsprogs-stage outputs may carry an LVM/systemd-oriented e2scrub
# schedule.  It is intentionally disabled in the stage, and removed here so
# upgrading an existing build cache cannot activate it when crond is added.
rm -f "${ROOTFS_DIR}/etc/cron.d/e2scrub_all"

[[ -x "${ROOTFS_DIR}/bin/bash" ]] || die "Bash is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/usr/share/bash-completion/bash_completion" ]] \
    || die "bash-completion is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/nano" ]] || die "nano is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/openssl" ]] || die "OpenSSL is missing from the target sysroot"
[[ -s "${ROOTFS_DIR}/etc/ssl/certs/ca-certificates.crt" ]] \
    || die "CA certificates are missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/vim" ]] || die "Vim is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/htop" ]] || die "htop is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/curl" ]] || die "curl is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/python3" ]] || die "Python is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/usr/lib64/libcrypt.so.2" ]] \
    || die "libxcrypt is missing from the target sysroot"
# The unwinder. No binary in the image records a NEEDED entry for it - GCC links
# libgcc statically - so nothing here would fail to build or to start without
# it; what fails is a thread calling pthread_exit, which makes glibc dlopen it
# by name, and any program brought in from outside the image, since Rust and C++
# link it outright.
[[ -f "${ROOTFS_DIR}/usr/lib64/libgcc_s.so.1" ]] \
    || die "libgcc_s.so.1 is missing from the target sysroot; pthread_exit would abort"
# The C++ runtime. Nothing in the image records a NEEDED entry for it, but every
# C++ program brought in from outside links it outright and cannot start without
# it.
[[ -f "${ROOTFS_DIR}/usr/lib64/libstdc++.so.6" ]] \
    || die "libstdc++.so.6 is missing from the target sysroot; no foreign C++ binary could start"
[[ -x "${ROOTFS_DIR}/usr/bin/ssh" ]] || die "the OpenSSH client is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/sbin/sshd" ]] || die "the OpenSSH server is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/lib/openssh/sshd-session" ]] \
    || die "sshd-session is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/sbin/crond" ]] || die "Cronie crond is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/crontab" ]] || die "Cronie crontab is missing from the target sysroot"
[[ "$(stat -c '%a' "${ROOTFS_DIR}/usr/bin/crontab")" == 4755 ]] \
    || die "Cronie crontab must be setuid root to manage user crontabs"
[[ -x "${ROOTFS_DIR}/usr/sbin/ip" ]] || die "the iproute2 ip command is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/sbin/ss" ]] || die "the iproute2 ss command is missing from the target sysroot"
[[ "$(readlink "${ROOTFS_DIR}/usr/sbin/netstat")" == ss ]] \
    || die "the iproute2 netstat command is not linked to ss in the target sysroot"
[[ "$(readlink "${ROOTFS_DIR}/usr/share/man/man8/netstat.8")" == ss.8 ]] \
    || die "the iproute2 netstat manual page is not linked to ss.8 in the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/sbin/xtables-legacy-multi" ]] \
    || die "the iptables multicall binary is missing from the target sysroot"
[[ -L "${ROOTFS_DIR}/usr/sbin/iptables" ]] \
    || die "iptables is not linked to the xtables multicall binary"
[[ -x "${ROOTFS_DIR}/usr/bin/mount" ]] || die "util-linux mount is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/lsblk" ]] || die "util-linux lsblk is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/sbin/blkid" ]] || die "util-linux blkid is missing from the target sysroot"
# /etc/passwd gives the sshd and nobody accounts this shell, and nothing else in
# the image provides one.
[[ -x "${ROOTFS_DIR}/usr/sbin/nologin" ]] || die "util-linux nologin is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/ls" ]] || die "coreutils is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/grep" ]] || die "GNU grep is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/sed" ]] || die "GNU sed is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/awk" ]] || die "GNU awk is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/find" ]] || die "GNU find is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/diff" ]] || die "GNU diff is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/make" ]] || die "GNU make is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/perl" ]] || die "Perl is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/sbin/chronyd" ]] || die "chronyd is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/etc/chrony.conf" ]] || die "the chrony configuration is missing from the image"
[[ -x "${ROOTFS_DIR}/usr/sbin/nic" ]] || die "nic is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/etc/nic.conf" ]] || die "the nic configuration is missing from the image"
for family in v4 v6; do
    [[ -f "${ROOTFS_DIR}/etc/nic.rules.${family}" ]] \
        || die "the default IPv${family#v} firewall rules are missing from the image"
    cmp -s "${PROJECT_ROOT}/config/nic.rules.${family}" \
        "${ROOTFS_DIR}/etc/nic.rules.${family}" \
        || die "the installed IPv${family#v} firewall rules differ from the configured defaults"
done
grep -qx 'iptables /etc/nic.rules.v4' "${ROOTFS_DIR}/etc/nic.conf" \
    || die "nic.conf does not load the default IPv4 firewall"
grep -qx 'ip6tables /etc/nic.rules.v6' "${ROOTFS_DIR}/etc/nic.conf" \
    || die "nic.conf does not load the default IPv6 firewall"
# The account tools. login is the one the inittab respawns on the console, so
# its absence is a machine nobody can log in to.
[[ -x "${ROOTFS_DIR}/usr/bin/login" ]] || die "shadow login is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/etc/login.defs" ]] || die "/etc/login.defs is missing from the image"
for account_tool in useradd usermod userdel groupadd groupmod groupdel; do
    [[ -x "${ROOTFS_DIR}/usr/sbin/${account_tool}" ]] \
        || die "shadow ${account_tool} is missing from the target sysroot"
done
[[ "$(stat -c '%a' "${ROOTFS_DIR}/usr/bin/passwd")" == 4755 ]] \
    || die "passwd must be setuid root to write /etc/shadow"
# The archivers. tar is the one sowa-pkg unpacks every package with.
[[ -x "${ROOTFS_DIR}/usr/bin/tar" ]] || die "GNU tar is missing from the target sysroot"
for compressor in gzip bzip2 xz zstd zip unzip; do
    [[ -x "${ROOTFS_DIR}/usr/bin/${compressor}" ]] \
        || die "${compressor} is missing from the target sysroot"
done
for archive_link in gunzip zcat bunzip2 bzcat unxz xzcat lzma unzstd zstdcat \
    zipinfo; do
    [[ -e "${ROOTFS_DIR}/usr/bin/${archive_link}" ]] \
        || die "${archive_link} is missing from the target sysroot"
done
# The library rather than the command: libmagic links it, so this is what a
# zstd stage that stopped installing its library would be caught by.
[[ -f "${ROOTFS_DIR}/usr/lib64/libzstd.so.1" \
    || -L "${ROOTFS_DIR}/usr/lib64/libzstd.so.1" ]] \
    || die "libzstd is missing from the target sysroot"
# procps-ng: the /proc tools. Ten commands from one tarball, and nothing else in
# the image reads /proc on anyone's behalf, so the whole group is checked.
for proc_tool in ps top free uptime vmstat w pgrep pkill pidof watch; do
    [[ -x "${ROOTFS_DIR}/usr/bin/${proc_tool}" ]] \
        || die "procps ${proc_tool} is missing from the target sysroot"
done
[[ -x "${ROOTFS_DIR}/usr/sbin/sysctl" ]] || die "procps sysctl is missing from the target sysroot"
# The two views of the machine's hardware. pciutils supplies both the commands
# that inspect PCI configuration space and the current name database; lshw
# consumes that database for the PCI branch of its broader hardware tree.
for pci_program in usr/bin/lspci usr/sbin/setpci usr/sbin/pcilmr \
    usr/sbin/update-pciids; do
    [[ -x "${ROOTFS_DIR}/${pci_program}" ]] \
        || die "/${pci_program} is missing from the target sysroot"
done
[[ -f "${ROOTFS_DIR}/usr/lib64/libpci.so.3" ]] \
    || die "libpci is missing from the target sysroot"
[[ -s "${ROOTFS_DIR}/usr/share/hwdata/pci.ids.gz" ]] \
    || die "the PCI ID database is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/lshw" ]] \
    || die "lshw is missing from the target sysroot"
[[ ! -e "${ROOTFS_DIR}/usr/share/lshw/pci.ids.gz" ]] \
    || die "lshw carries its stale private PCI database instead of using pciutils' copy"
# GnuPG. gpgv is the half of it that verifies a signature with nothing but a
# keyring, and pinentry is what gpg-agent has to exec before it can unlock a
# secret key: without one, gpg can check and encrypt but never sign or decrypt.
for gnupg_program in gpg gpgv gpg-agent dirmngr gpgconf; do
    [[ -x "${ROOTFS_DIR}/usr/bin/${gnupg_program}" ]] \
        || die "GnuPG ${gnupg_program} is missing from the target sysroot"
done
[[ -e "${ROOTFS_DIR}/usr/bin/pinentry" ]] \
    || die "pinentry is missing; gpg-agent could not ask for a passphrase"
# Git, and the helper an https:// remote is fetched with - the ssh:// and
# git:// transports are inside the git binary, but HTTP is a separate program.
[[ -x "${ROOTFS_DIR}/usr/bin/git" ]] || die "Git is missing from the target sysroot"
[[ -e "${ROOTFS_DIR}/usr/libexec/git-core/git-remote-https" ]] \
    || die "Git cannot clone over HTTPS; its remote helper is missing"
# Wget, which is in the image for what curl does not do: -r and -m, walking a
# site rather than fetching one URL.
[[ -x "${ROOTFS_DIR}/usr/bin/wget" ]] || die "wget is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/etc/wgetrc" ]] || die "the wget configuration is missing"
# The two VPNs. OpenVPN is a daemon and a directory of tunnel configurations;
# WireGuard is in the kernel, so all that is here is the pair of programs that
# configure it. Both directories hold key material and must not be readable by
# anything but root.
[[ -x "${ROOTFS_DIR}/usr/sbin/openvpn" ]] || die "openvpn is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/usr/lib64/openvpn/plugins/openvpn-plugin-down-root.so" ]] \
    || die "the OpenVPN down-root plugin is missing from the target sysroot"
[[ "$(stat -c '%a' "${ROOTFS_DIR}/etc/openvpn")" == 700 ]] \
    || die "/etc/openvpn must be readable only by root; it holds key material"
[[ -x "${ROOTFS_DIR}/usr/bin/wg" ]] || die "wg is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/wg-quick" ]] || die "wg-quick is missing from the target sysroot"
[[ "$(stat -c '%a' "${ROOTFS_DIR}/etc/wireguard")" == 700 ]] \
    || die "/etc/wireguard must be readable only by root; it holds private keys"
# wg-quick shells out to these, and to iptables when a peer routes everything.
# They are all in the image already; this says so, because a wg-quick that
# cannot find them fails half way through, with the interface already created.
for wg_quick_tool in usr/sbin/ip usr/sbin/iptables usr/sbin/ip6tables usr/sbin/sysctl; do
    [[ -e "${ROOTFS_DIR}/${wg_quick_tool}" ]] \
        || die "wg-quick needs /${wg_quick_tool}, which is not in the image"
done
[[ -x "${ROOTFS_DIR}/usr/bin/pscap" ]] || die "libcap-ng pscap is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/usr/lib64/libcap-ng.so.0" ]] \
    || die "libcap-ng is missing from the target sysroot; openvpn links it"
# The reader for the manual pages every other package installs, and the three
# other names the same binary answers to.
[[ -x "${ROOTFS_DIR}/usr/bin/mandoc" ]] || die "mandoc is missing from the target sysroot"
for mandoc_alias in usr/bin/man usr/bin/apropos usr/bin/whatis usr/sbin/makewhatis; do
    [[ -x "${ROOTFS_DIR}/${mandoc_alias}" ]] \
        || die "/${mandoc_alias} is missing from the target sysroot"
done
# man pages through /usr/bin/less unless MANPAGER or PAGER says otherwise, and
# that path is compiled into mandoc as BINM_PAGER rather than looked up on
# PATH - so a missing less is not a fallback, it is a man that opens a page and
# shows nothing. GNU less is also what makes those pages readable rather than
# merely displayed: a page arrives full of the backspace overstriking nroff has
# emitted since the 1970s, and resolving that back into bold and underline is
# what a pager has to do before a manual page reads as one.
[[ -x "${ROOTFS_DIR}/usr/bin/less" ]] || die "GNU less is missing from the target sysroot"
grep -aq '/usr/bin/less' "${ROOTFS_DIR}/usr/bin/mandoc" \
    || die "mandoc does not name /usr/bin/less as its pager; rm work/stamps/packages/mandoc.done and rebuild it"
[[ ! -e "${ROOTFS_DIR}/usr/bin/manpager" ]] \
    || die "the obsolete manpager wrapper is still in the image; man pages through less directly now"
[[ -x "${ROOTFS_DIR}/usr/bin/lesskey" ]] \
    || die "less lesskey is missing from the target sysroot"
# lessecho is not on PATH: less execs it by path to expand a metacharacter in a
# filename, so it lives in libexec.
[[ -x "${ROOTFS_DIR}/usr/libexec/lessecho" ]] \
    || die "less lessecho is missing from the target sysroot"
# file, and the compiled magic database without which it calls everything "data".
[[ -x "${ROOTFS_DIR}/usr/bin/file" ]] || die "file is missing from the target sysroot"
[[ -s "${ROOTFS_DIR}/usr/share/misc/magic.mgc" ]] \
    || die "the compiled magic database is missing; file would identify nothing"
# inetutils. ping opens a raw socket, so the setuid bit is as much a part of the
# package as the binary - a strip pass that cleared it would leave a ping that
# only root can run, which is the kind of thing nobody discovers until the
# network is already broken.
for inetutils_program in ping ping6 hostname telnet; do
    [[ -x "${ROOTFS_DIR}/usr/bin/${inetutils_program}" ]] \
        || die "inetutils ${inetutils_program} is missing from the target sysroot"
done
for raw_socket_program in usr/bin/ping usr/bin/ping6; do
    [[ "$(stat -c '%a' "${ROOTFS_DIR}/${raw_socket_program}")" == 4755 ]] \
        || die "/${raw_socket_program} must be setuid root to open a raw socket"
done
# mtr, which is also the answer /usr/bin/traceroute points at. Same setuid
# argument, applied to the half of it that holds the socket.
[[ -x "${ROOTFS_DIR}/usr/sbin/mtr" ]] || die "mtr is missing from the target sysroot"
[[ "$(stat -c '%a' "${ROOTFS_DIR}/usr/sbin/mtr-packet")" == 4755 ]] \
    || die "mtr-packet must be setuid root to open a raw socket"
[[ -x "${ROOTFS_DIR}/usr/bin/whois" ]] || die "whois is missing from the target sysroot"
# BIND. dig, host and nslookup are checked with the rest of the base commands
# further down; what is checked here is the rest of the package, which nothing
# else would notice the absence of. named is the server, named-checkconf is what
# the init script runs before starting it, rndc is how a running one is spoken
# to, and dnssec-keygen stands for the signing tools.
for bind_program in named rndc rndc-confgen tsig-keygen; do
    [[ -x "${ROOTFS_DIR}/usr/sbin/${bind_program}" ]] \
        || die "BIND did not install ${bind_program} into the target sysroot"
done
for bind_program in delv nsupdate named-checkconf named-checkzone dnssec-keygen dnssec-signzone; do
    [[ -x "${ROOTFS_DIR}/usr/bin/${bind_program}" ]] \
        || die "BIND did not install ${bind_program} into the target sysroot"
done
[[ -f "${ROOTFS_DIR}/etc/named.conf" ]] \
    || die "named.conf is missing from the target sysroot; named would not start"
# named writes the DNSSEC keys it manages into this directory, so it has to
# exist and it has to belong to the account named switches to.
[[ -d "${ROOTFS_DIR}/var/named" ]] \
    || die "named's working directory /var/named is missing from the target sysroot"
# libcap is BIND's, but its commands are the image's: nothing else here can say
# what capabilities a file or a process carries.
for capability_program in setcap getcap getpcaps capsh; do
    [[ -x "${ROOTFS_DIR}/usr/sbin/${capability_program}" ]] \
        || die "libcap did not install ${capability_program} into the target sysroot"
done
[[ -f "${ROOTFS_DIR}/usr/lib64/libpcap.so.1" ]] \
    || die "libpcap is missing from the target sysroot; tcpdump cannot capture packets"
[[ -x "${ROOTFS_DIR}/usr/bin/tcpdump" ]] \
    || die "tcpdump is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/bin/strace" ]] \
    || die "strace is missing from the target sysroot"
# landlock-sandboxer, and the two lines in the kernel fragment without which it
# is a program whose only possible output is the hint that says the kernel has
# no Landlock. CONFIG_SECURITY_LANDLOCK is what builds the module in;
# CONFIG_LSM is the ordered list that decides whether a module that was built in
# is ever initialised, and one missing from it fails nothing anywhere else.
[[ -x "${ROOTFS_DIR}/usr/bin/landlock-sandboxer" ]] \
    || die "landlock-sandboxer is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/usr/share/man/man1/landlock-sandboxer.1" ]] \
    || die "the landlock-sandboxer manual page is missing from the image"
grep -qx 'CONFIG_SECURITY_LANDLOCK=y' "${PROJECT_ROOT}/config/kernel-x86_64.fragment" \
    || die "the image ships landlock-sandboxer, but the kernel fragment no longer asks for Landlock"
grep -qE '^CONFIG_LSM="([^"]*,)?landlock(,[^"]*)?"$' \
    "${PROJECT_ROOT}/config/kernel-x86_64.fragment" \
    || die "the kernel fragment's CONFIG_LSM does not name landlock, so the kernel would build it in and never enable it"
[[ -x "${ROOTFS_DIR}/usr/bin/ncdu" ]] \
    || die "ncdu is missing from the target sysroot"
# plocate, and the two programs that fill its database. locate is a symlink to
# plocate, and updatedb is plocate's own builder in sbin: findutils no longer
# installs either name, so a GNU program reaching the image would be the two
# implementations shadowing each other across PATH.
for plocate_program in usr/bin/plocate usr/sbin/plocate-build usr/sbin/updatedb; do
    [[ -x "${ROOTFS_DIR}/${plocate_program}" ]] \
        || die "${plocate_program} is missing from the target sysroot"
done
[[ "$(readlink "${ROOTFS_DIR}/usr/bin/locate")" == plocate ]] \
    || die "/usr/bin/locate is not a symlink to plocate"
# findutils must not ship its own locate any more, or it would sit in front of
# plocate's symlink and answer the same names with a different database.
for findutils_locate in usr/bin/updatedb usr/libexec/frcode; do
    [[ ! -e "${ROOTFS_DIR}/${findutils_locate}" ]] \
        || die "GNU findutils still installs /${findutils_locate}; plocate owns that name"
done
# Not setgid, and the stage says at length why: this image ships every file
# owned by root, so the only group plocate could be setgid to is root, which
# would be a privilege granted for no benefit. Asserted here because the bit
# would come back silently if the stage ever stopped assigning modes by hand.
[[ "$(stat -c %a "${ROOTFS_DIR}/usr/bin/plocate")" == 755 ]] \
    || die "plocate is setgid in the image; see packages/plocate.sh for why it must not be"
[[ -d "${ROOTFS_DIR}/var/lib/plocate" ]] \
    || die "the plocate database directory is missing from the image"

# The system logger and the library it is written against. GLib is in this
# image for syslog-ng alone, and it is shared rather than absorbed because
# syslog-ng dlopens its modules and every one of them has to resolve GLib
# against the same copy - so the modules directory is checked as well as the
# daemon. See packages/glib.sh.
[[ -f "${ROOTFS_DIR}/usr/lib64/libpcre2-8.so.0" ]] \
    || die "PCRE2 is missing from the target sysroot; syslog-ng could not start"
[[ -f "${ROOTFS_DIR}/usr/lib64/libglib-2.0.so.0" ]] \
    || die "GLib is missing from the target sysroot; syslog-ng could not start"
[[ -f "${ROOTFS_DIR}/usr/lib64/libgmodule-2.0.so.0" ]] \
    || die "gmodule is missing from the target sysroot; syslog-ng loads its modules with it"
[[ -f "${ROOTFS_DIR}/usr/lib64/libjson-c.so.5" ]] \
    || die "json-c is missing from the target sysroot; syslog-ng could not start"
[[ -x "${ROOTFS_DIR}/usr/sbin/syslog-ng" ]] \
    || die "syslog-ng is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/sbin/syslog-ng-ctl" ]] \
    || die "syslog-ng-ctl is missing from the target sysroot"
for module in affile afsocket afuser afprog syslogformat basicfuncs; do
    [[ -f "${ROOTFS_DIR}/usr/lib64/syslog-ng/lib${module}.so" ]] \
        || die "the syslog-ng ${module} module is missing; the daemon would fail to read its configuration"
done
[[ -d "${ROOTFS_DIR}/var/lib/syslog-ng" ]] \
    || die "syslog-ng's persist directory is missing from the image"

# logrotate's program and persistent-state directory come from its package. Its
# policy and cron schedule come from the overlay and are checked after that has
# been copied below.
[[ -x "${ROOTFS_DIR}/usr/sbin/logrotate" ]] \
    || die "logrotate is missing from the target sysroot"
[[ -d "${ROOTFS_DIR}/var/lib/logrotate" ]] \
    || die "logrotate's state directory is missing from the image"
# The native toolchain, which is what makes this image self-hosting rather than
# only installable: a compiler that runs here, the assembler and linker it
# execs, and the headers and libraries it compiles and links against. Each of
# these is useless without the others, so they are checked as one thing.
for compiler in gcc g++ cpp cc c++; do
    [[ -x "${ROOTFS_DIR}/usr/bin/${compiler}" ]] \
        || die "${compiler} is missing from the target sysroot; the image could not compile a program"
done
for binutil in as ld ar nm objdump ranlib readelf strip; do
    [[ -x "${ROOTFS_DIR}/usr/bin/${binutil}" ]] \
        || die "binutils ${binutil} is missing from the target sysroot; gcc execs it"
done
gcc_version="$(source_version gcc)"
for backend in cc1 cc1plus; do
    [[ -x "${ROOTFS_DIR}/usr/libexec/gcc/${TARGET}/${gcc_version}/${backend}" ]] \
        || die "the ${backend} compiler proper is missing; gcc is only the driver that runs it"
done
# What "cc hello.c" reads and links: GCC's start files and libgcc, glibc's
# headers and its C runtime, and for C++ the standard headers next to the
# libstdc++ the image already carried.
for startfile in "usr/lib64/gcc/${TARGET}/${gcc_version}/crtbegin.o" \
    "usr/lib64/gcc/${TARGET}/${gcc_version}/libgcc.a" \
    usr/lib64/crt1.o usr/lib64/libc.so usr/include/stdio.h \
    "usr/include/c++/${gcc_version}/vector" usr/lib64/libstdc++.so; do
    [[ -e "${ROOTFS_DIR}/${startfile}" ]] \
        || die "/${startfile} is missing; the compiler would have nothing to compile against"
done
# What turns that compiler into something that can build a package rather than a
# single source file. Almost everything anyone would compile on this image
# arrives as an autotools tree, which needs m4, autoconf and a pkg-config before
# it will even configure.
[[ -x "${ROOTFS_DIR}/usr/bin/m4" ]] || die "GNU m4 is missing from the target sysroot"
for autoconf_program in autoconf autoheader autom4te autoreconf autoupdate; do
    [[ -x "${ROOTFS_DIR}/usr/bin/${autoconf_program}" ]] \
        || die "autoconf ${autoconf_program} is missing from the target sysroot"
done
# autom4te runs m4 by the path compiled into it at build time, and freezes and
# reads its macro files with that same m4. Both halves are checked here because
# the failure is a build-host mistake that only shows up on the target.
[[ -s "${ROOTFS_DIR}/usr/share/autoconf/autoconf/autoconf.m4f" ]] \
    || die "autoconf's frozen macro files are missing; every autoconf run would reparse them"
grep -q '/usr/bin/m4' "${ROOTFS_DIR}/usr/bin/autom4te" \
    || die "autom4te does not name /usr/bin/m4; it would look for m4 where the image has none"
[[ -x "${ROOTFS_DIR}/usr/bin/pkgconf" ]] || die "pkgconf is missing from the target sysroot"
[[ "$(readlink "${ROOTFS_DIR}/usr/bin/pkg-config")" == pkgconf ]] \
    || die "/usr/bin/pkg-config is not a link to pkgconf; every PKG_CHECK_MODULES would fail"
[[ -f "${ROOTFS_DIR}/usr/share/aclocal/pkg.m4" ]] \
    || die "pkg.m4 is missing; aclocal could not expand PKG_CHECK_MODULES"
# The commands a person expects a Unix to have. Each of these came out of a
# different tarball and most are asserted again beside their own package above,
# but they are worth stating once as a list: this is the shape of the base
# system, and a stage that quietly stopped installing its program is caught here
# rather than by whoever types the name on a booted machine.
for base_command in cat ls cp mv rm mkdir ln date grep sed awk find xargs diff cmp \
    mount umount kill dmesg lsblk curl wget \
    nano man strings less file ping hostname \
    locale localedef iconv \
    login passwd \
    tar gzip gunzip bzip2 bunzip2 xz unxz zstd unzstd zip unzip \
    ps top free uptime pgrep pkill pidof watch \
    lspci lshw dig host nslookup ncdu which; do
    [[ -x "${ROOTFS_DIR}/usr/bin/${base_command}" ]] \
        || die "/usr/bin/${base_command} is missing from the target sysroot; its package installed nothing"
done
# The same statement for the handful that belong in sbin rather than bin,
# because they administer the system rather than serve whoever is logged in.
for base_command in blkid mkfs.ext4 fsck.ext4 mkfs.xfs xfs_repair mkfs.btrfs \
    btrfs mdadm mdmon lvm dmsetup ip ss netstat iptables mtr setpci useradd \
    groupadd sysctl; do
    [[ -e "${ROOTFS_DIR}/usr/sbin/${base_command}" ]] \
        || die "/usr/sbin/${base_command} is missing from the target sysroot; its package installed nothing"
done
[[ -e "${ROOTFS_DIR}/usr/sbin/mkfs.ext4" ]] || die "mkfs.ext4 (e2fsprogs) is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/sbin/mkfs.xfs" ]] || die "mkfs.xfs (xfsprogs) is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/sbin/mkfs.btrfs" ]] || die "mkfs.btrfs (btrfs-progs) is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/etc/mdadm.conf" ]] || die "mdadm.conf is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/etc/lvm/lvm.conf" ]] || die "lvm.conf is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/sbin/mkfs.fat" ]] || die "mkfs.fat (dosfstools) is missing from the target sysroot"
[[ -x "${ROOTFS_DIR}/usr/sbin/grub-install" ]] || die "grub-install is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/usr/lib/grub/i386-pc/boot.img" ]] || die "GRUB i386-pc platform is missing"
[[ -f "${ROOTFS_DIR}/usr/lib/grub/x86_64-efi/moddep.lst" ]] || die "GRUB x86_64-efi platform is missing"
# PID 1 and the commands that drive it. Everything else in the image is a
# convenience by comparison: without these the kernel has nothing to start.
[[ -x "${ROOTFS_DIR}/sbin/init" ]] || die "sowa-init is missing from the target sysroot"
for lifecycle in telinit shutdown halt poweroff reboot runlevel service chkconfig; do
    [[ -x "${ROOTFS_DIR}/sbin/${lifecycle}" ]] \
        || die "${lifecycle} is missing from the target sysroot"
done
[[ -x "${ROOTFS_DIR}/etc/rc.d/rc" ]] || die "the runlevel driver /etc/rc.d/rc is missing"
[[ -f "${ROOTFS_DIR}/etc/rc.d/init.d/functions" ]] \
    || die "the init script function library is missing"
ln -sfn bash "${ROOTFS_DIR}/bin/sh"
ln -sfn ../usr/bin/vim "${ROOTFS_DIR}/bin/vi"
# /bin holds four names and no others, and this is where that is said. It used
# to be a multicall binary and a directory of links into it, and /bin comes
# first on PATH, so every one of those links shadowed the packaged program of
# the same name - which is what the whole deprecation was about. Now the only
# things here are Bash, which is /bin/sh and cannot move without breaking every
# "#!/bin/sh" in existence, its bug-reporting script, and the two traditional
# links this stage just made. A fifth name means a package installed into /bin
# rather than under /usr, and it would silently take precedence over everything.
expected_bin=" bash bashbug sh vi "
while IFS= read -r bin_entry; do
    [[ "${expected_bin}" == *" ${bin_entry} "* ]] \
        || die "/bin/${bin_entry} is a stray; /bin holds only bash, bashbug, sh and vi"
done < <(find "${ROOTFS_DIR}/bin" -mindepth 1 -maxdepth 1 -printf '%P\n')
for bin_entry in bash bashbug sh vi; do
    [[ -e "${ROOTFS_DIR}/bin/${bin_entry}" ]] \
        || die "/bin/${bin_entry} is missing from the image"
done

cp -a "${PROJECT_ROOT}/rootfs-overlay/." "${ROOTFS_DIR}/"

# The convenience installers are an image package of their own rather than
# part of the overlay's sowa-release package. Checking the assembled tree here
# proves the default image actually contains the complete set their stage made.
readonly CUSTOM_INSTALLERS=(bun go node ollama rust uv)
for custom_installer in "${CUSTOM_INSTALLERS[@]}"; do
    [[ -x "${ROOTFS_DIR}/opt/install-${custom_installer}" ]] \
        || die "/opt/install-${custom_installer} is missing from the image"
done

# Configuration supplied by the overlay is checked only after the copy. The
# package-stage parser checks above prove the syntax; these checks prove that
# the assembled image carries the same policy and actually schedules it.
[[ -f "${ROOTFS_DIR}/etc/syslog-ng/syslog-ng.conf" ]] \
    || die "/etc/syslog-ng/syslog-ng.conf is missing; syslog-ng has nothing to read"
grep -q 'unix-dgram("/dev/log")' "${ROOTFS_DIR}/etc/syslog-ng/syslog-ng.conf" \
    || die "the syslog-ng configuration does not listen on /dev/log, which is the whole point of it"
[[ -f "${ROOTFS_DIR}/etc/logrotate.conf" ]] \
    || die "/etc/logrotate.conf is missing; logrotate would rotate nothing"
[[ -f "${ROOTFS_DIR}/etc/logrotate.d/sowa" ]] \
    || die "the base system's rotation rules are missing from /etc/logrotate.d"
[[ -f "${ROOTFS_DIR}/etc/cron.d/logrotate" ]] \
    || die "nothing schedules logrotate; it would never run"
grep -q '/usr/sbin/logrotate /etc/logrotate.conf' "${ROOTFS_DIR}/etc/cron.d/logrotate" \
    || die "the logrotate cron entry does not run logrotate"
# sowa-pkg's own record is one of the files the pattern has to cover, and it is
# the newest of them: a rule written before that log existed would leave the
# one file that grows on every upgrade unrotated.
grep -q '/var/log/\*\.log' "${ROOTFS_DIR}/etc/logrotate.d/sowa" \
    || die "the rotation rules do not cover /var/log/*.log, where every service and sowa-pkg write"
# Git cannot retain the restrictive mode required for a shadow database, so
# apply it after the overlay is copied into the image tree. /etc/gshadow is one
# for the same reason /etc/shadow is: shadow was configured --enable-shadowgrp,
# and a group password readable by everyone is not a password.
chmod 0600 "${ROOTFS_DIR}/etc/shadow" "${ROOTFS_DIR}/etc/gshadow"
for installer in sowa-setup sowa-bootstrap sowa-chroot; do
    [[ -x "${ROOTFS_DIR}/usr/sbin/${installer}" ]] \
        || die "${installer} is missing or not executable"
    # All three source the same library, and a source that fails leaves the
    # program with none of its helpers - including die, so it cannot even say
    # so. Checked here rather than trusted to the overlay copy because the
    # symptom on a booted image is an installer that exits 1 in silence.
    # Through ${SOWA_INSTALL_LIB}, not at a fixed path: that indirection is what
    # lets scripts/make-installer-bundle.sh pack all four files into one
    # relocatable script, and a program that hardcoded /usr/lib/sowa would find
    # nothing there when the bundle runs outside an installed Sowa system.
    # shellcheck disable=SC2016 # matching the literal text, not expanding it
    grep -q '^source "\${SOWA_INSTALL_LIB:-/usr/lib/sowa}/install-functions"$' \
        "${ROOTFS_DIR}/usr/sbin/${installer}" \
        || die "${installer} does not source the shared installer library through SOWA_INSTALL_LIB"
done
# sowa-partitioner is the fourth program in the install story and the only one
# that does not share the library: it touches partition tables, md and LVM
# rather than the root filesystem's contents, so it stands alone and is checked
# on its own terms. Its manual is checked with it, because a full-screen program
# with no documentation is one nobody can be expected to drive.
[[ -x "${ROOTFS_DIR}/usr/sbin/sowa-partitioner" ]] \
    || die "sowa-partitioner is missing or not executable"
[[ -f "${ROOTFS_DIR}/usr/share/man/man8/sowa-partitioner.8" ]] \
    || die "the sowa-partitioner manual is missing from the image"
[[ -f "${ROOTFS_DIR}/usr/lib/sowa/install-functions" ]] \
    || die "the shared installer library is missing from the image"
# It is sourced, never executed, so it must not be executable: a library with
# the bit set is one someone will eventually run, and running this one does
# nothing at all.
[[ ! -x "${ROOTFS_DIR}/usr/lib/sowa/install-functions" ]] \
    || die "the shared installer library is executable; it is meant to be sourced"
# grub-mkconfig support. Without /etc/default/grub grub-mkconfig fails before it
# runs any script, and the overlay's 10_linux is what makes it produce an entry
# at all: upstream's looks for a versioned kernel and an initramfs, neither of
# which Sowa has.
[[ -x "${ROOTFS_DIR}/usr/sbin/grub-mkconfig" ]] || die "grub-mkconfig is missing from the target sysroot"
[[ -f "${ROOTFS_DIR}/etc/default/grub" ]] || die "the grub-mkconfig defaults are missing from the image"
[[ -x "${ROOTFS_DIR}/etc/grub.d/10_linux" ]] || die "the Sowa 10_linux is missing or not executable"
grep -q '^GRUB_CMDLINE_LINUX=' "${ROOTFS_DIR}/etc/default/grub" \
    || die "/etc/default/grub does not set GRUB_CMDLINE_LINUX"
grep -q '/boot/vmlinuz' "${ROOTFS_DIR}/etc/grub.d/10_linux" \
    || die "the Sowa 10_linux does not look for /boot/vmlinuz"
# The three names the image answers with an explanation instead of a program.
# Each is a command people type out of habit whose job here is done by something
# with a different name: lsof by util-linux's lsfd and traceroute by mtr. nc
# points at the optional Nmap package. Each placeholder prints how to reach the
# replacement before
# exiting 127, which is a better answer than "command not found". They
# are ordinary files in the overlay, so what can go wrong is the execute bit -
# which git does track, but which a fresh checkout on a strange umask can still
# lose, and the symptom would be "permission denied" instead of the
# explanation.
for placeholder in lsof traceroute nc; do
    [[ -x "${ROOTFS_DIR}/usr/bin/${placeholder}" ]] \
        || die "the ${placeholder} placeholder is missing or not executable"
done
grep -q 'lsfd' "${ROOTFS_DIR}/usr/bin/lsof" \
    || die "the lsof placeholder does not name lsfd, which is the point of it"
grep -q 'mtr' "${ROOTFS_DIR}/usr/bin/traceroute" \
    || die "the traceroute placeholder does not name mtr, which is the point of it"
grep -q 'sowa-pkg install nmap' "${ROOTFS_DIR}/usr/bin/nc" \
    || die "the nc placeholder does not tell users how to install Nmap"

# named's service. The init script comes with the overlay, so it is checked
# here rather than beside the rest of BIND further up. It ships with no
# runlevel links at all: named is in the image because dig is, and a resolver
# that starts listening on a machine nobody asked is a surprise. The absence is
# asserted so that adding a link later is a decision rather than an accident.
[[ -x "${ROOTFS_DIR}/etc/rc.d/init.d/named" ]] \
    || die "the named init script is missing or not executable"
if compgen -G "${ROOTFS_DIR}/etc/rc.d/rc?.d/S??named" > /dev/null; then
    die "named is enabled at boot; it ships disabled"
fi
# The account named switches to once it has bound port 53, which is the whole
# reason libcap is in the image. Without it named would refuse to start under
# the shipped configuration.
grep -q '^named:' "${ROOTFS_DIR}/etc/passwd" \
    || die "the named account is missing; named could not drop privilege"
grep -q '^named:' "${ROOTFS_DIR}/etc/group" \
    || die "the named group is missing; named could not drop privilege"

# Every directory /etc/profile puts on PATH has to be one that exists, or the
# shell searches a name that resolves to nothing on every command it runs.
# /usr/local is the half that is easy to lose: nothing installs into it, so
# nothing else would notice it had gone.
while IFS= read -r -d ':' path_element; do
    [[ -d "${ROOTFS_DIR}${path_element}" ]] \
        || die "/etc/profile puts ${path_element} on PATH, but the image has no such directory"
done < <(sed -n 's/^export PATH=//p' "${ROOTFS_DIR}/etc/profile" | tr -d '\n'; printf ':')

# readline binds the arrow keys itself and stops there, so Delete, Home, End and
# the rest arrive as sequences nothing has a name for. Elsewhere this file comes
# from the readline package; Bash here uses its bundled copy of the library, so
# nothing would install one and the overlay ships it. SYS_INPUTRC in
# lib/readline/rlconf.h is what makes /etc the place it has to be.
[[ -f "${ROOTFS_DIR}/etc/inputrc" ]] \
    || die "/etc/inputrc is missing; readline would leave the Delete key unbound"
grep -qx '"\\e\[3~": delete-char' "${ROOTFS_DIR}/etc/inputrc" \
    || die "/etc/inputrc does not bind the Delete key"

# The databases the shadow build asks for. packages/shadow.sh configures with
# --enable-shadowgrp and --enable-subordinate-ids, and each names a file that
# the tools open rather than create: gpasswd and newgrp want /etc/gshadow,
# useradd wants /etc/subuid and /etc/subgid. Shipping them empty is the
# difference between a feature that is compiled in and one that works.
for database in gshadow subuid subgid; do
    [[ -f "${ROOTFS_DIR}/etc/${database}" ]] \
        || die "/etc/${database} is missing; shadow was built expecting it"
done
[[ "$(awk -F: 'NR==1 {print $1}' "${ROOTFS_DIR}/etc/gshadow")" == root ]] \
    || die "/etc/gshadow does not begin with the root group"

# A user created after the image was built needs somewhere for their shell
# settings to come from. /etc/skel is what useradd copies into a new home, and
# /etc/bash.bashrc is what an interactive shell reads before it - the pair is
# why "useradd alice" produces a working account rather than a bare prompt.
for skel_file in .bashrc .bash_profile; do
    [[ -f "${ROOTFS_DIR}/etc/skel/${skel_file}" ]] \
        || die "/etc/skel/${skel_file} is missing; a new account would have no shell settings"
done
[[ -f "${ROOTFS_DIR}/etc/bash.bashrc" ]] \
    || die "/etc/bash.bashrc is missing but Bash was built with SYS_BASHRC"
# The file is inert unless the binary was compiled to look for it, and a stage
# stamp is presence-based: editing packages/bash.sh does not by itself rebuild
# Bash. Ask the binary rather than the recipe.
grep -aq '/etc/bash\.bashrc' "${ROOTFS_DIR}/bin/bash" \
    || die "Bash has no SYS_BASHRC; rm work/stamps/packages/bash.done and rebuild it"
# The optional packages are built and published but never installed into the
# image, so every command they carry is a "command not found" on a fresh system.
# /etc/bash.bashrc answers those names with the sowa-pkg line that would install
# them, and this is what keeps that list from going stale: the names come from
# the staging trees the packages were actually cut from, so an optional package
# that grows a command - or a new optional package altogether - fails the build
# here instead of shipping a system with no way to discover it.
system_bashrc="${ROOTFS_DIR}/etc/bash.bashrc"
grep -q '^command_not_found_handle()' "${system_bashrc}" \
    || die "/etc/bash.bashrc defines no command_not_found_handle"
mapfile -t hinted_commands < <(
    sed -n 's/^[[:space:]]*\(.*\))[[:space:]]*package=.*;;$/\1/p' "${system_bashrc}" \
        | tr '|' '\n' | tr -d ' \t' | grep -v '^$'
)
((${#hinted_commands[@]})) \
    || die "command_not_found_handle names no commands; its case statement did not parse"
hinted_names=" ${hinted_commands[*]} "
while IFS= read -r optional_package; do
    pkg_staged "${optional_package}" \
        || die "optional package ${optional_package} has no staged tree; build it first"
    while IFS= read -r optional_command; do
        [[ "${hinted_names}" == *" ${optional_command} "* ]] \
            || die "${optional_command} comes from the optional ${optional_package} package but /etc/bash.bashrc does not offer to install it"
    done < <(
        find "${PKG_STAGE_DIR}/${optional_package}" \
            -mindepth 2 -maxdepth 3 \
            \( -path '*/bin/*' -o -path '*/sbin/*' \) \
            \( -type l -o \( -type f -perm -u+x \) \) \
            -printf '%f\n' | sort -u
    )
done < <(optional_package_names)
# login(1) sets HOME, USER and LOGNAME from the account database, and /etc/profile
# used to overwrite all three with root's. Assigning them unconditionally again
# would give every user root's home directory.
! grep -qE '^export (HOME|USER|LOGNAME)=' "${ROOTFS_DIR}/etc/profile" \
    || die "/etc/profile assigns HOME, USER or LOGNAME unconditionally; login's values must survive"

# agetty prints /etc/issue before the login prompt, and chsh refuses a shell
# that /etc/shells does not name.
[[ -f "${ROOTFS_DIR}/etc/issue" ]] || die "/etc/issue is missing"
# A serial tty is stamped 24x80 by agetty and never corrected, so the size has
# to be asked for. The profile hook is useless without the program it calls.
[[ -x "${ROOTFS_DIR}/usr/bin/resize" ]] \
    || die "/usr/bin/resize is missing or not executable"
[[ -f "${ROOTFS_DIR}/etc/profile.d/winsize.sh" ]] \
    || die "/etc/profile.d/winsize.sh is missing; a serial login would stay 24x80"
grep -qx '/bin/bash' "${ROOTFS_DIR}/etc/shells" \
    || die "/etc/shells does not list /bin/bash"
[[ "$(readlink "${ROOTFS_DIR}/etc/mtab")" == /proc/self/mounts ]] \
    || die "/etc/mtab is not a link to /proc/self/mounts"

# glibc falls back to UTC without complaint when a zone file is missing, so an
# image with no zoneinfo is one that answers every question about local time
# wrongly and silently.
[[ -f "${ROOTFS_DIR}/usr/share/zoneinfo/UTC" ]] \
    || die "the time zone database is missing from the target sysroot"
[[ -L "${ROOTFS_DIR}/etc/localtime" ]] \
    || die "/etc/localtime is not a symlink into the time zone database"

# The compiled locales, which are the same kind of silent failure one layer up:
# glibc falls back to the C locale when the locale it was asked for is not
# there, so an image with no archive is one that is wrong about text everywhere
# and says so only as a setlocale warning nobody reads. The four files are the
# archive programs read, the catalogue and default a person edits, and the
# profile hook without which /etc/locale.conf is a file nothing consults.
[[ -s "${ROOTFS_DIR}/usr/lib/locale/locale-archive" ]] \
    || die "the compiled locale archive is missing from the image; every program would fall back to C"
[[ -x "${ROOTFS_DIR}/usr/sbin/locale-gen" ]] \
    || die "locale-gen is missing from the image; no locale could be added on a running machine"
[[ -s "${ROOTFS_DIR}/etc/locale.gen" ]] \
    || die "/etc/locale.gen is missing from the image"
[[ -f "${ROOTFS_DIR}/etc/locale.conf" ]] \
    || die "/etc/locale.conf is missing from the image"
[[ -f "${ROOTFS_DIR}/etc/profile.d/locale.sh" ]] \
    || die "/etc/profile.d/locale.sh is missing; nothing would export the system locale"
# The two ends have to agree: the locale /etc/locale.conf names has to be one
# the archive holds. Asked of the archive, through the image's own localedef
# run on the image's own loader, because the build host's would answer for its
# own C library.
image_lang="$(locale_conf_lang "${ROOTFS_DIR}/etc/locale.conf")"
[[ -n "${image_lang}" ]] || die "/etc/locale.conf sets no LANG"
image_loader="${ROOTFS_DIR}/lib64/ld-linux-x86-64.so.2"
[[ -e "${image_loader}" ]] || image_loader="${ROOTFS_DIR}/lib/ld-linux-x86-64.so.2"
image_archived="$("${image_loader}" \
    --library-path "${ROOTFS_DIR}/usr/lib64:${ROOTFS_DIR}/lib64" \
    "${ROOTFS_DIR}/usr/bin/localedef" --list-archive \
    "${ROOTFS_DIR}/usr/lib/locale/locale-archive")" \
    || die "the image's locale archive cannot be listed by the image's own localedef"
grep -qxF "$(normalise_locale_name "${image_lang}")" <<< "${image_archived}" \
    || die "/etc/locale.conf sets LANG=${image_lang}, which the image's locale archive does not hold"
[[ -x "${ROOTFS_DIR}/usr/bin/sowa-pkg" ]] \
    || die "the sowa-pkg package manager is missing or not executable"
[[ -f "${ROOTFS_DIR}/etc/sowa/pkg.conf" ]] \
    || die "the package manager configuration is missing from the image"
# Without the repository's public key an installed system can fetch an index but
# never accept one, which is the right default: it fails closed.
[[ -f "${ROOTFS_DIR}/etc/sowa/keys/sowa-repo.pub" ]] \
    || log "warning: no repository key in the image; sowa-pkg update will refuse every index until 'make repo-key' has run and the image is rebuilt"
if grep -q 'example\.org\|example\.com\|example\.invalid' \
    "${ROOTFS_DIR}/etc/sowa/pkg.conf"; then
    log "warning: rootfs-overlay/etc/sowa/pkg.conf still points at the placeholder repository URL; set SOWA_REPO_URL to the server that will host ${DISTRO_NAME}'s packages"
fi
[[ -x "${ROOTFS_DIR}/usr/sbin/sowa-sshd-keygen" ]] \
    || die "sowa-sshd-keygen is missing or not executable"

# Sowa's own programs, and the documentation for them. Everything else in the
# image arrives with the manual pages its upstream wrote; these are the ones
# nobody else would write, and until they existed the only description of any of
# them was the comment at the top of the script.
#
# The list is derived rather than written down: every program the overlay
# installs into bin or sbin has to have a page, so a Sowa program added later
# without one fails the build here instead of shipping undocumented. The three
# exceptions are the placeholders - names the image answers with an explanation
# instead of a program - and each of those prints its own, at length, to
# whoever types it.
declare -A undocumented_by_design=([lsof]=1 [nc]=1 [traceroute]=1)
while IFS= read -r sowa_program; do
    [[ -n "${undocumented_by_design[${sowa_program}]:-}" ]] && continue
    compgen -G "${ROOTFS_DIR}/usr/share/man/man?/${sowa_program}.[0-9]" > /dev/null \
        || die "${sowa_program} comes from the root filesystem overlay but has no manual page"
done < <(cd "${PROJECT_ROOT}/rootfs-overlay" && find usr/bin usr/sbin \
    -mindepth 1 -maxdepth 1 -type f -printf '%f\n')
# The file format that goes with the package manager. It is the one piece of
# Sowa's configuration a person edits by hand and cannot read the answer to
# anywhere else in the image.
[[ -f "${ROOTFS_DIR}/usr/share/man/man5/sowa-pkg.conf.5" ]] \
    || die "the sowa-pkg.conf manual page is missing from the image"
# The init package's own pages, which arrive from a different stage but have to
# be here for "man service" to answer on a booted machine. halt(8) covers
# poweroff and reboot, and is linked to under both names.
for init_page in man5/inittab.5 man8/init.8 man8/telinit.8 man8/shutdown.8 \
    man8/halt.8 man8/poweroff.8 man8/reboot.8 man8/runlevel.8 man8/service.8 \
    man8/chkconfig.8 man8/sowa-boottime.8; do
    [[ -e "${ROOTFS_DIR}/usr/share/man/${init_page}" ]] \
        || die "/usr/share/man/${init_page} is missing from the image"
done
# The completions. bash-completion loads a file named after the command, so
# these paths are the interface: a file under any other name is one that is
# never read. The pair that matters most is chkconfig and service: the generic
# chkconfig completion shipped by bash-completion describes a different
# implementation, and Sowa's is preferred because it is in the directory the
# loader looks in first.
completions_dir="${ROOTFS_DIR}/usr/share/bash-completion/completions"
for completion in sowa-pkg sowa-license sowa-bootstrap sowa-chroot \
    sowa-partitioner service \
    chkconfig telinit init shutdown halt poweroff reboot sowa-boottime; do
    [[ -e "${completions_dir}/${completion}" ]] \
        || die "no bash completion for ${completion} in the image"
    bash -n "${completions_dir}/${completion}" \
        || die "the ${completion} completion is not valid shell"
done
[[ -f "${ROOTFS_DIR}/usr/share/bash-completion/bash_completion" ]] \
    || die "the completions have nothing to load them; bash-completion is missing"
# The howto, which is a directory of topics rather than the one long file it
# used to be: a person looking for the firewall does not want to page past the
# VPNs to reach it, and grep over a directory answers the same question as grep
# over a file. Every topic is checked for being there and for having something
# in it - an empty one is a topic somebody meant to write - and the index is
# checked for naming each of them, since an index that has fallen behind is
# worse than none.
howto_dir="${ROOTFS_DIR}/root/sowa-howto"
[[ -d "${howto_dir}" ]] || die "the /root howto directory is missing from the image"
[[ -s "${howto_dir}/00-index.txt" ]] || die "the howto has no index"
howto_topics=0
while IFS= read -r howto_topic; do
    [[ -s "${howto_dir}/${howto_topic}" ]] \
        || die "the howto topic ${howto_topic} is empty"
    [[ "${howto_topic}" == 00-index.txt ]] && continue
    grep -q "${howto_topic}" "${howto_dir}/00-index.txt" \
        || die "the howto index does not name ${howto_topic}"
    howto_topics=$((howto_topics + 1))
done < <(cd "${howto_dir}" && find . -maxdepth 1 -type f -printf '%P\n')
((howto_topics > 0)) || die "the howto directory has no topics in it"
# The single file the directory replaced. A checkout that still has it would
# ship both, and the stale one would be the one people found first.
[[ ! -e "${ROOTFS_DIR}/root/sowa-howto.txt" ]] \
    || die "the old /root/sowa-howto.txt is still in the image; the howto is a directory now"
# The inittab is the whole of init's configuration, so a boot that goes nowhere
# is almost always one of these entries missing.
inittab="${ROOTFS_DIR}/etc/inittab"
grep -qE '^id:[1-5]:initdefault:' "${inittab}" \
    || die "the shipped inittab has no initdefault; init would not know what to enter"
grep -q '^si::sysinit:/etc/rc.d/rc.sysinit$' "${inittab}" \
    || die "the shipped inittab does not run rc.sysinit; nothing would be mounted"
[[ -x "${ROOTFS_DIR}/etc/rc.d/rc.setup" ]] \
    || die "the ISO setup boot hook is missing or not executable"
[[ -x "${ROOTFS_DIR}/usr/bin/setsid" ]] \
    || die "the ISO setup boot hook cannot claim its console; setsid is missing"
grep -q '^st::bootwait:/etc/rc.d/rc.setup$' "${inittab}" \
    || die "the shipped inittab does not schedule the ISO setup boot hook"
grep -q 'sowa\.setup' "${ROOTFS_DIR}/etc/rc.d/rc.setup" \
    || die "the ISO setup boot hook does not recognize its kernel parameter"
grep -q '/run/sowa/sfs' "${ROOTFS_DIR}/etc/rc.d/rc.setup" \
    || die "the ISO setup boot hook is not restricted to a live-system boot"
for level in 0 1 2 3 4 5 6; do
    grep -q "^l${level}:${level}:wait:/etc/rc.d/rc ${level}\$" "${inittab}" \
        || die "the shipped inittab has no entry for runlevel ${level}"
done
# A getty per console, and both kinds have to be there: the whole point of them
# is that neither the local display nor the serial line depends on which
# "console=" the kernel command line happened to put last, and a missing one
# would only be discovered by whoever is standing in front of that console.
[[ -x "${ROOTFS_DIR}/usr/sbin/agetty" ]] \
    || die "agetty (util-linux) is missing from the target sysroot; the inittab's gettys would not start"
[[ -x "${ROOTFS_DIR}/usr/sbin/serial-getty" ]] \
    || die "serial-getty is missing from the image; the serial login would respawn forever on a machine with no UART"
grep -qE '^[^#:]+:[0-9]+:respawn:@/usr/sbin/agetty .* tty1( |$)' "${inittab}" \
    || die "the shipped inittab has no login prompt on tty1"
grep -qE '^[^#:]+:[0-9]+:respawn:@/usr/sbin/serial-getty ttyS0( |$)' "${inittab}" \
    || die "the shipped inittab has no login prompt on ttyS0"
# The "@" marker is what keeps init from handing a getty /dev/console as its
# controlling terminal, which it could then never let go of; without it the
# prompt appears and no login can start a session on it.
# agetty's compiled-in default login program is /bin/login, which this image
# deliberately does not have - /bin holds four names and none of them is that
# one, as checked above - so every getty has to name shadow's by path instead.
while IFS= read -r getty; do
    [[ "${getty}" == *:respawn:@* ]] \
        || die "an inittab getty is not marked \"@\", so init would give it the console: ${getty}"
    [[ "${getty}" == */serial-getty\ * || "${getty}" == *" -l /usr/bin/login "* ]] \
        || die "an inittab getty does not name shadow's login: ${getty}"
done < <(grep -E '^[^#:]+:[0-9]+:respawn:@?/usr/sbin/(agetty|serial-getty) ' "${inittab}")
grep -q ' -l /usr/bin/login ' "${ROOTFS_DIR}/usr/sbin/serial-getty" \
    || die "serial-getty does not name shadow's login; agetty would look for /bin/login"

# Without devpts there is no slave side for openpty(3), so every sshd session
# dies at "PTY allocation request failed" even though authentication succeeds.
grep -q 'mount -t devpts ' "${ROOTFS_DIR}/etc/rc.d/rc.sysinit" \
    || die "rc.sysinit does not mount devpts; sshd cannot allocate a PTY"
# Without the unified hierarchy on /sys/fs/cgroup no container runtime starts:
# dockerd exits at "Devices cgroup isn't mounted" before it opens its socket.
grep -q 'mount -t cgroup2 ' "${ROOTFS_DIR}/etc/rc.d/rc.sysinit" \
    || die "rc.sysinit does not mount cgroup2; no container runtime can start"
# init creates its control FIFO on /run before rc.sysinit mounts a tmpfs there,
# so without the signal that asks it for a new one, telinit and shutdown would
# write to a FIFO nothing is reading.
grep -q '^kill -USR1 1$' "${ROOTFS_DIR}/etc/rc.d/rc.sysinit" \
    || die "rc.sysinit does not ask init to recreate /run/initctl after mounting /run"
# mount -a walks past a swap line in /etc/fstab without doing anything with it,
# so without this an installed system's swap partition is configured and never
# used - and nothing on the machine would say so.
grep -qE '^[[:space:]]*swapon -a\b' "${ROOTFS_DIR}/etc/rc.d/rc.sysinit" \
    || die "rc.sysinit does not enable the swap /etc/fstab lists"

# The services the image starts, and the links that start them. A dangling link
# is a service that silently does not run.
for service in sshd crond chronyd network syslog-ng openvpn wg-quick zram growroot; do
    [[ -x "${ROOTFS_DIR}/etc/rc.d/init.d/${service}" ]] \
        || die "the ${service} init script is missing or not executable"
    grep -qE '^# chkconfig: ' "${ROOTFS_DIR}/etc/rc.d/init.d/${service}" \
        || die "the ${service} init script has no chkconfig header"
done
# OpenSSH's -e option diverts even authentication records to stderr. Keep the
# daemon in the foreground with -D, but leave normal logging on syslog so the
# secure log promised by the image is not silently empty.
grep -qE '^[[:space:]]*"[$][{]program[}]" -D$' \
    "${ROOTFS_DIR}/etc/rc.d/init.d/sshd" \
    || die "sshd is not started in the foreground"
if grep -q -- '-D -e' "${ROOTFS_DIR}/etc/rc.d/init.d/sshd"; then
    die "sshd sends authentication records to stderr instead of /var/log/secure"
fi
# The two VPN services are installed and switched off. An image ships no
# tunnels, so starting them at boot would at best be a no-op and at worst would
# bring up a tunnel nobody asked for; "chkconfig openvpn on" is how a machine
# says otherwise. They still get a K link on every path to a stopped system, so
# a tunnel started by hand is taken down before the network goes.
for service in openvpn wg-quick; do
    grep -qE '^# chkconfig: - ' "${ROOTFS_DIR}/etc/rc.d/init.d/${service}" \
        || die "the ${service} service must default to off; its chkconfig header enables it"
    for level in 2 3 4 5; do
        if compgen -G "${ROOTFS_DIR}/etc/rc.d/rc${level}.d/S[0-9][0-9]${service}" > /dev/null; then
            die "${service} is started in runlevel ${level}; the image must ship it switched off"
        fi
    done
    for level in 0 1 6; do
        compgen -G "${ROOTFS_DIR}/etc/rc.d/rc${level}.d/K[0-9][0-9]${service}" > /dev/null \
            || die "${service} is not stopped on the way to runlevel ${level}"
    done
done
# growroot ships installed and switched off, like the two VPN services, but for
# a different reason and with a different shape: it is a one-shot with nothing to
# stop, so it has no K links to check, and the machines it is for are the ones
# that boot a disk image rather than a disk sowa-setup filled. The disk image
# stage is what turns it on, in the image and nowhere else.
grep -qE '^# chkconfig: - ' "${ROOTFS_DIR}/etc/rc.d/init.d/growroot" \
    || die "the growroot service must default to off; its chkconfig header enables it"
for level in 2 3 4 5; do
    if compgen -G "${ROOTFS_DIR}/etc/rc.d/rc${level}.d/S[0-9][0-9]growroot" > /dev/null; then
        die "growroot is started in runlevel ${level}; only the disk image ships it enabled"
    fi
done

for service in zram network sshd crond chronyd syslog-ng; do
    compgen -G "${ROOTFS_DIR}/etc/rc.d/rc3.d/S[0-9][0-9]${service}" > /dev/null \
        || die "${service} is not started in the default runlevel"
    compgen -G "${ROOTFS_DIR}/etc/rc.d/rc0.d/K[0-9][0-9]${service}" > /dev/null \
        || die "${service} is not stopped on the way to halt"
done
# The logger starts before everything that might have something to say and
# stops after all of it, which is the only ordering that makes it worth having.
# Both ends are checked rather than left to whoever next edits the header.
compgen -G "${ROOTFS_DIR}/etc/rc.d/rc3.d/S05syslog-ng" > /dev/null \
    || die "syslog-ng does not start before the other services; messages sent during their start-up would be lost"
compgen -G "${ROOTFS_DIR}/etc/rc.d/rc0.d/K95syslog-ng" > /dev/null \
    || die "syslog-ng is stopped too early; messages sent while the machine shuts down would be lost"
# Swap comes before everything, and goes after it. Swap that appears once the
# memory has run out was not there when it was needed, and taking it away while
# services are still running pushes everything on it back into the memory they
# are using - so zram's two priorities are checked rather than left to whoever
# next edits the header.
compgen -G "${ROOTFS_DIR}/etc/rc.d/rc3.d/S04zram" > /dev/null \
    || die "zram is not the first service in the default runlevel"
compgen -G "${ROOTFS_DIR}/etc/rc.d/rc0.d/K96zram" > /dev/null \
    || die "zram is not the last service stopped on the way to halt"
# The network comes up before anything that expects one, and goes down after.
compgen -G "${ROOTFS_DIR}/etc/rc.d/rc3.d/S10network" > /dev/null \
    || die "the network is not the first service in the default runlevel"
while IFS= read -r rc_link; do
    [[ -e "${rc_link}" ]] || die "dangling runlevel link: ${rc_link#"${ROOTFS_DIR}"}"
done < <(find "${ROOTFS_DIR}/etc/rc.d" -name 'rc[0-6].d' -type d -exec find {} -type l -print \;)

# What the zram service is made of. Its own half is four util-linux programs
# and a configuration file; the other half is a kernel symbol, and a kernel
# built without it turns the first service of every runlevel into a failure on
# the console at every boot. image/kernel.sh proves the fragment took effect,
# so what is checked here is that the fragment still asks - the image is what
# depends on it, and this is the file that says which parts of the image are
# real.
for swap_program in zramctl mkswap swapon swapoff; do
    [[ -x "${ROOTFS_DIR}/usr/sbin/${swap_program}" ]] \
        || die "${swap_program} (util-linux) is missing; the zram service could not run"
done
[[ -f "${ROOTFS_DIR}/etc/sowa/zram.conf" ]] \
    || die "/etc/sowa/zram.conf is missing; the zram service would have nothing to read"
grep -q '^ZRAM_SIZE=' "${ROOTFS_DIR}/etc/sowa/zram.conf" \
    || die "/etc/sowa/zram.conf sets no ZRAM_SIZE"
grep -qx 'CONFIG_ZRAM=y' "${PROJECT_ROOT}/config/kernel-x86_64.fragment" \
    || die "the kernel fragment no longer asks for zram, but the image starts it at boot"
grep -qx 'CONFIG_SWAP=y' "${PROJECT_ROOT}/config/kernel-x86_64.fragment" \
    || die "the kernel fragment no longer asks for swap, which zram and fstab both need"
[[ -f "${ROOTFS_DIR}/usr/share/man/man5/zram.conf.5" ]] \
    || die "the zram.conf manual page is missing from the image"

# The services the optional packages bring with them.
#
# An init script for something the image carries comes from the root filesystem
# overlay - that is where sshd's and crond's are, and why they are checked
# against ROOTFS_DIR above. An optional package cannot work that way: it is not
# in the image, and a path the image already has is a conflict its manifest is
# refused for, so its own staging tree is the only place its service can come
# from. Left out, the package installs, its daemon runs for exactly as long as
# somebody keeps a terminal open, and nothing on the machine says what is
# missing.
#
# Every optional package is named here, the ones with no daemon included: an
# entry of "-" is a statement that the package has none, so a new optional
# package is a decision about this rather than a silence.
declare -A optional_service=(
    [7zip]=-
    [sowa-monitor]=sowa-monitor
    [nginx]=nginx
    [haproxy]=haproxy
    [guix]=guix-daemon
    [docker]=docker
    [nmap]=-
)
while IFS= read -r optional_package; do
    optional_initd="${PKG_STAGE_DIR}/${optional_package}/etc/rc.d/init.d"
    package_service="${optional_service[${optional_package}]-}"
    [[ -n "${package_service}" ]] \
        || die "${optional_package} is an optional package; say in image/10-rootfs.sh which daemon it runs, or \"-\" for none"
    if [[ "${package_service}" == - ]]; then
        [[ ! -d "${optional_initd}" ]] \
            || die "${optional_package} is recorded as running no daemon, but it ships an init script"
        continue
    fi
    [[ -x "${optional_initd}/${package_service}" ]] \
        || die "${optional_package} runs ${package_service} but ships no init script for it; installing it could not survive a reboot"
    # Whether the script defaults to off is pkg_check_services' business. This is
    # the other half of the same rule: runlevel links in the package would turn
    # the service on the moment it was unpacked, behind chkconfig's back.
    if compgen -G "${PKG_STAGE_DIR}/${optional_package}/etc/rc.d/rc?.d/*" > /dev/null; then
        die "${optional_package} ships runlevel links; installing it would start a service nobody asked for"
    fi
done < <(optional_package_names)
# Sowa Monitor, nginx and HAProxy are servers, and none is turned on by
# installing it: having one on the disk and publishing it are different
# decisions. It is asserted here as
# well as written in the hooks, because a hook added later would otherwise
# change it quietly.
for quiet_package in sowa-monitor nginx haproxy; do
    package_hooks="$(package_hooks_file "${quiet_package}")"
    [[ -f "${package_hooks}" ]] \
        || die "${quiet_package} declares no steps at all; its daemon would outlive the package it came from"
    if grep -qE '^post-(install|upgrade)\|service-(enable|start)\|' "${package_hooks}"; then
        die "${quiet_package} would be started by installing it; that decision belongs to the machine"
    fi
    grep -q '^pre-remove|service-stop|' "${package_hooks}" \
        || die "${quiet_package} does not stop its daemon before the package is removed"
    grep -q '^pre-remove|service-disable|' "${package_hooks}" \
        || die "${quiet_package} does not take its runlevel links away before the package is removed"
done
# Docker deliberately has the opposite first-install policy: installing the
# engine makes it available immediately and at the next boot. Keep both steps
# explicit here so a hooks edit cannot quietly leave either half behind. They
# are first-install-only; an upgrade must still respect a service an
# administrator disabled or stopped.
docker_hooks="$(package_hooks_file docker)"
[[ -f "${docker_hooks}" ]] || die "docker declares no service steps"
grep -q '^post-install|service-enable|docker$' "${docker_hooks}" \
    || die "installing docker does not enable it at boot"
grep -q '^post-install|service-start|docker$' "${docker_hooks}" \
    || die "installing docker does not start it"
if grep -qE '^post-upgrade\|service-(enable|start)\|docker$' "${docker_hooks}"; then
    die "upgrading docker would override an administrator who disabled or stopped it"
fi
grep -q '^post-upgrade|service-restart|docker$' "${docker_hooks}" \
    || die "upgrading docker does not restart a running engine"
grep -q '^pre-remove|service-stop|docker$' "${docker_hooks}" \
    || die "docker does not stop its daemon before the package is removed"
grep -q '^pre-remove|service-disable|docker$' "${docker_hooks}" \
    || die "docker does not take its runlevel links away before the package is removed"
[[ -f "${ROOTFS_DIR}/etc/crontab" ]] \
    || die "the default system crontab is missing from the image"
[[ "$(stat -c '%a' "${ROOTFS_DIR}/var/spool/cron")" == 700 ]] \
    || die "the Cronie spool must be private"
# The overlay sshd_config replaces the upstream one installed into the sysroot.
grep -q '^PermitEmptyPasswords no' "${ROOTFS_DIR}/etc/ssh/sshd_config" \
    || die "the shipped sshd_config does not refuse empty passwords"
grep -q '^sshd:' "${ROOTFS_DIR}/etc/passwd" \
    || die "the sshd privilege separation user is missing from /etc/passwd"
grep -q '^root:x:' "${ROOTFS_DIR}/etc/passwd" \
    || die "the root account must use the shadow password database"
grep -q '^root:' "${ROOTFS_DIR}/etc/shadow" \
    || die "the root shadow entry is missing from the image"
[[ "$(stat -c '%a' "${ROOTFS_DIR}/etc/shadow")" == 600 ]] \
    || die "the shadow database must be readable only by root"
# A shipped host key would give every installation the same identity.
if compgen -G "${ROOTFS_DIR}/etc/ssh/ssh_host_*" > /dev/null; then
    die "the image must not carry sshd host keys; they are generated at boot"
fi
# Nor may any package own root's authorised keys: whatever a package shipped
# there would be written back over the administrator's file at the next
# upgrade, and an empty file is the worst of the things it could be.
if [[ -e "${ROOTFS_DIR}/root/.ssh/authorized_keys" ]]; then
    die "the image must not carry /root/.ssh/authorized_keys; an upgrade would write it back over root's own keys"
fi
[[ "$(stat -c '%a' "${ROOTFS_DIR}/root/.ssh")" == 700 ]] \
    || die "/root/.ssh must be private; sshd's StrictModes refuses keys otherwise"
# The licence of every package, installed here rather than left to the stage
# that built it.
#
# A component stage does install its own at pkg_merge, and that is what makes a
# freshly built staging tree complete. But a stage is skipped when its stamp and
# its staging tree are both already there, so on any build cache older than
# config/licenses.conf not one of them would run - which is exactly the failure
# this replaced: eighty packages already built, none of them carrying a licence,
# and nothing that would rebuild them. Licence texts are copied out of the
# pinned tarballs rather than compiled, so doing it again here costs a few file
# copies and no compiler, and it makes editing the licence table a "make rootfs"
# instead of a rebuild of the whole system.
#
# It is idempotent: pkg_install_licenses rebuilds each directory from the table,
# so a text that has been renamed or dropped leaves the image with it instead of
# lingering as a file nothing claims.
#
# A package with a staging tree gets its licences in both places - the tree,
# because that is the record ownership is derived from, and the image, because
# the sysroot was copied in long before this point. sowa-base and sowa-release
# have neither: sowa-base is by definition whatever is left over once the
# others have claimed their files, and sowa-release is the overlay, so the
# image is the only place theirs can go. pkg_assign_ownership knows that a
# package owns its own licence directory, which is what keeps sowa-release's
# out of sowa-base. The kernel is not in the tree yet; image/11-initramfs.sh
# installs and asserts its own where it enters.
log "installing the licence of every package into the image"
while IFS= read -r package; do
    [[ "${package}" == linux ]] && continue
    if pkg_staged "${package}"; then
        pkg_install_licenses "${package}" "${PKG_STAGE_DIR}/${package}"
    fi
    pkg_install_licenses "${package}" "${ROOTFS_DIR}"
    # Nothing in the image may be distributed without the terms it was given
    # under, so this is stated for every package rather than for the ones
    # anybody remembered.
    pkg_check_licenses "${package}" "${ROOTFS_DIR}"
done < <(image_package_names)

# The optional packages are cut from their staging trees and never enter the
# image, so theirs go there and nowhere else - and for the same reason as
# above, a guix or nginx tree unpacked before the licence table existed would
# otherwise be published without one.
while IFS= read -r package; do
    pkg_staged "${package}" \
        || die "optional package ${package} has no staged tree; build it first"
    pkg_install_licenses "${package}" "${PKG_STAGE_DIR}/${package}"
    pkg_check_licenses "${package}" "${PKG_STAGE_DIR}/${package}"
done < <(optional_package_names)

[[ -x "${ROOTFS_DIR}/usr/bin/sowa-license" ]] \
    || die "sowa-license is missing or not executable; the image could not report its own licensing"

# Split the assembled tree between the packages that produced it and record the
# result as the image's own package database, so an installed system knows what
# it is made of before it has ever reached the repository. The kernel is added
# by the initramfs stage and registers itself there.
log "assigning package ownership across the root filesystem"
pkg_assign_ownership "${ROOTFS_DIR}"
# Only the packages the image is made of are recorded as installed. An optional
# package has a manifest too, but it belongs to the repository, and writing a
# database entry for it would claim the image ships something it does not.
#
# The two this stage produces itself are held back to the end. Their identity
# includes the key this stage is going to be stamped with, which has to be
# predicted from the pinned sources the stage has asked for so far - and
# describing any other package asks the lock for that package's version. Written
# in catalogue order, they would predict a stage that had not yet looked up
# everything after them in the table, and the repository would compute a
# different identity for the same bytes an hour later. scripts/package.sh
# refuses to publish if that ever happens again.
while IFS= read -r package; do
    case "${package}" in
        sowa-base | sowa-release) continue ;;
    esac
    manifest="${PKG_META_DIR}/${package}.files"
    if [[ ! -s "${manifest}" ]]; then
        log "no files for ${package} yet (registered by a later stage)"
        continue
    fi
    pkg_db_write "${ROOTFS_DIR}" "${package}" "${manifest}"
done < <(image_package_names)

[[ -s "${PKG_META_DIR}/sowa-base.files" ]] \
    || die "sowa-base claimed no files; the base system would not be installable"
[[ -s "${PKG_META_DIR}/sowa-release.files" ]] \
    || die "sowa-release claimed no files; the overlay was not applied"
grep -q '|usr/bin/sowa-pkg$' "${PKG_META_DIR}/sowa-release.files" \
    || die "sowa-pkg is not owned by sowa-release"
[[ -s "${PKG_META_DIR}/custom-installers.files" ]] \
    || die "custom-installers claimed no files; /opt would not be independently upgradable"
for custom_installer in "${CUSTOM_INSTALLERS[@]}"; do
    grep -q "|opt/install-${custom_installer}$" \
        "${PKG_META_DIR}/custom-installers.files" \
        || die "/opt/install-${custom_installer} is not owned by custom-installers"
done

for package in sowa-base sowa-release; do
    pkg_db_write "${ROOTFS_DIR}" "${package}" "${PKG_META_DIR}/${package}.files"
done

log "root filesystem assembled at ${ROOTFS_DIR}"
