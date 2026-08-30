SHELL := /bin/bash

.DEFAULT_GOAL := help

.PHONY: help check selftest stage-key fetch check-updates toolchain kernel init bash bash-completion ncurses nano openssl ca-certificates vim htop zlib curl python util-linux e2fsprogs dosfstools grub libxcrypt openssh cron iproute2 iptables sowa-monitor custom-installers nginx docker \
	coreutils grep sed gawk findutils diffutils make perl chrony nic shadow tar gzip bzip2 xz zstd zip unzip 7zip procps pciutils lshw gnupg git wget libcap-ng openvpn wireguard less mandoc binutils gcc m4 autoconf pkgconf file inetutils mtr whois libuv liburcu libcap bind which plocate libpcap tcpdump nmap strace landlock ncdu netbase tzdata locales pcre2 glib json-c syslog-ng logrotate haproxy guix \
	rootfs image iso recovery-image rootfs-tarball disk-image installer-bundle docker-image docker-run docker-push \
	packages repo-key publish-repo release-key release-manifest verify-release \
	run-qemu run-recovery run-iso run-install run-disk run-disk-uefi run-disk-image run-disk-image-uefi all clean distclean

help:
	@sed -n 's/^## //p' Makefile

## make check       - validate the host and build-system files
check:
	@./scripts/host-check.sh
	@./scripts/lint.sh
	@./scripts/selftest.sh

## make selftest    - assert the stamp, sysroot and package-identity rules
selftest:
	@./scripts/selftest.sh

## make stage-key   - show what a stage's stamp key is made of (STAGE=packages/openssh)
stage-key:
	@./scripts/stage-key.sh $(STAGE)

## make fetch       - download and SHA-256 verify all pinned sources
fetch:
	@./scripts/fetch.sh

## make check-updates - compare pinned versions with upstream releases (networked)
check-updates:
	@./scripts/check-updates.py

## make toolchain   - build binutils, GCC, Linux headers, and glibc
toolchain:
	@./scripts/build.sh toolchain

## make kernel      - build the pinned longterm kernel
kernel:
	@./scripts/build.sh kernel

## make init        - build sowa-init, the System V style init and its rc framework
init:
	@./scripts/build.sh init

## make bash        - build GNU Bash for the target root filesystem
bash:
	@./scripts/build.sh bash

## make bash-completion - install programmable completion support for Bash
bash-completion:
	@./scripts/build.sh bash-completion

## make ncurses     - build wide-character ncurses and the terminfo database
ncurses:
	@./scripts/build.sh ncurses

## make nano        - build GNU nano and its ncurses dependency
nano:
	@./scripts/build.sh nano

## make openssl     - build the OpenSSL toolkit and shared libraries
openssl:
	@./scripts/build.sh openssl

## make ca-certificates - install the pinned Mozilla CA certificate bundle
ca-certificates:
	@./scripts/build.sh ca-certificates

## make vim         - build terminal Vim and its ncurses dependency
vim:
	@./scripts/build.sh vim

## make htop        - build htop and its ncurses dependency
htop:
	@./scripts/build.sh htop

## make zlib        - build the zlib shared library
zlib:
	@./scripts/build.sh zlib

## make curl        - build curl and libcurl with HTTPS support
curl:
	@./scripts/build.sh curl

## make python      - build CPython with TLS, zlib, curses, and pip
python:
	@./scripts/build.sh python

## make util-linux  - build mount, blkid, lsblk, fdisk, dmesg, and their libraries
util-linux:
	@./scripts/build.sh util-linux

## make e2fsprogs   - build mke2fs/mkfs.ext4 and the ext filesystem tools
e2fsprogs:
	@./scripts/build.sh e2fsprogs

## make dosfstools  - build mkfs.fat for the UEFI EFI System Partition
dosfstools:
	@./scripts/build.sh dosfstools

## make grub        - build GRUB (i386-pc and x86_64-efi) for on-disk installs
grub:
	@./scripts/build.sh grub

## make libxcrypt   - build libxcrypt, the crypt(3) glibc no longer provides
libxcrypt:
	@./scripts/build.sh libxcrypt

## make openssh     - build the OpenSSH client and server
openssh:
	@./scripts/build.sh openssh

## make cron        - build Cronie, the cron daemon and crontab command
cron:
	@./scripts/build.sh cron

## make iproute2    - build ip, ss (also netstat), tc, and the rest of the netlink tools
iproute2:
	@./scripts/build.sh iproute2

## make iptables    - build iptables-legacy, ip6tables, and the xtables extensions
iptables:
	@./scripts/build.sh iptables

## make nginx       - build nginx for the repository (it is not part of the image)
nginx:
	@./scripts/build.sh nginx

## make sowa-monitor - build the read-only monitoring dashboard for the repository
sowa-monitor:
	@./scripts/build.sh sowa-monitor

## make custom-installers - package the pinned /opt language and runtime installers
custom-installers:
	@./scripts/build.sh custom-installers

## make docker      - build Docker Engine for the repository (it is not part of the image)
docker:
	@./scripts/build.sh docker

## make coreutils   - build the GNU core utilities: ls, cp, cat, date and the rest
coreutils:
	@./scripts/build.sh coreutils

## make grep        - build GNU grep, egrep, and fgrep
grep:
	@./scripts/build.sh grep

## make sed         - build GNU sed
sed:
	@./scripts/build.sh sed

## make gawk        - build GNU awk
gawk:
	@./scripts/build.sh gawk

## make findutils   - build GNU find and xargs
findutils:
	@./scripts/build.sh findutils

## make diffutils   - build GNU diff, cmp, diff3, and sdiff
diffutils:
	@./scripts/build.sh diffutils

## make make        - build GNU make
make:
	@./scripts/build.sh make

## make perl        - build Perl 5 and its core modules
perl:
	@./scripts/build.sh perl

## make chrony      - build chronyd and chronyc, the NTP client and server
chrony:
	@./scripts/build.sh chrony

## make nic         - build nic, the declarative network configuration tool
nic:
	@./scripts/build.sh nic

## make shadow      - build shadow: useradd, usermod, groupadd, login, passwd, su
shadow:
	@./scripts/build.sh shadow

## make tar         - build GNU tar
tar:
	@./scripts/build.sh tar

## make gzip        - build GNU gzip and the z* scripts
gzip:
	@./scripts/build.sh gzip

## make bzip2       - build bzip2, bunzip2 and libbz2
bzip2:
	@./scripts/build.sh bzip2

## make xz          - build XZ Utils: xz, lzma, and liblzma
xz:
	@./scripts/build.sh xz

## make zstd        - build Zstandard: zstd, unzstd, and libzstd
zstd:
	@./scripts/build.sh zstd

## make zip         - build Info-ZIP zip
zip:
	@./scripts/build.sh zip

## make unzip       - build Info-ZIP unzip
unzip:
	@./scripts/build.sh unzip

## make 7zip        - build 7-Zip for the repository, installed as 7zz and 7z
7zip:
	@./scripts/build.sh 7zip

## make procps      - build procps-ng: ps, top, free, uptime, vmstat, w, sysctl
procps:
	@./scripts/build.sh procps

## make pciutils    - build lspci, setpci, pcilmr, the PCI ID database, and libpci
pciutils:
	@./scripts/build.sh pciutils

## make lshw        - build the detailed hardware inventory tool
lshw:
	@./scripts/build.sh lshw

## make gnupg       - build GnuPG, its libraries, and pinentry
gnupg:
	@./scripts/build.sh gnupg

## make git         - build Git with its HTTPS and SSH transports
git:
	@./scripts/build.sh git

## make wget        - build GNU Wget, the recursive downloader
wget:
	@./scripts/build.sh wget

## make libcap-ng   - build libcap-ng and the pscap, netcap and filecap tools
libcap-ng:
	@./scripts/build.sh libcap-ng

## make openvpn     - build the OpenVPN daemon, its client, and the down-root plugin
openvpn:
	@./scripts/build.sh openvpn

## make wireguard   - build wg and wg-quick for the in-kernel WireGuard tunnel
wireguard:
	@./scripts/build.sh wireguard

## make less        - build GNU less, the pager man and git page through
less:
	@./scripts/build.sh less

## make mandoc      - build mandoc: the man, apropos, whatis and makewhatis commands
mandoc:
	@./scripts/build.sh mandoc

## make binutils    - build the native as, ld, ar, nm, objdump and strip for the image
binutils:
	@./scripts/build.sh binutils

## make gcc         - build the native C and C++ compiler for the image
gcc:
	@./scripts/build.sh gcc

## make m4          - build GNU m4, the macro processor autoconf runs on
m4:
	@./scripts/build.sh m4

## make autoconf    - build GNU autoconf for the image
autoconf:
	@./scripts/build.sh autoconf

## make pkgconf     - build pkgconf, installed as pkg-config
pkgconf:
	@./scripts/build.sh pkgconf

## make file        - build file(1) and libmagic
file:
	@./scripts/build.sh file

## make inetutils   - build inetutils ping, ping6, hostname and telnet
inetutils:
	@./scripts/build.sh inetutils

## make mtr         - build mtr, the combined traceroute and ping
mtr:
	@./scripts/build.sh mtr

## make whois       - build the whois client
whois:
	@./scripts/build.sh whois

## make libuv       - build libuv, the asynchronous I/O library BIND needs
libuv:
	@./scripts/build.sh libuv

## make liburcu     - build Userspace RCU, the read-copy-update library BIND needs
liburcu:
	@./scripts/build.sh liburcu

## make libcap      - build libcap and the setcap, getcap and capsh commands
libcap:
	@./scripts/build.sh libcap

## make bind        - build ISC BIND 9: named, dig, host, nslookup and the DNSSEC tools
bind:
	@./scripts/build.sh bind

## make which       - build GNU which
which:
	@./scripts/build.sh which

## make plocate     - build plocate, which provides locate and updatedb
plocate:
	@./scripts/build.sh plocate

## make libpcap     - build libpcap, the packet capture and filtering library
libpcap:
	@./scripts/build.sh libpcap

## make tcpdump     - build tcpdump, the command-line packet capture tool
tcpdump:
	@./scripts/build.sh tcpdump

## make nmap        - build Nmap, Ncat and Nping for the repository
nmap:
	@./scripts/build.sh nmap

## make strace      - build strace, the Linux system-call tracer
strace:
	@./scripts/build.sh strace

## make landlock    - build landlock-sandboxer, which runs a command under a Landlock policy
landlock:
	@./scripts/build.sh landlock

## make ncdu        - build ncdu, the interactive disk-usage browser
ncdu:
	@./scripts/build.sh ncdu

## make netbase     - install the pinned IANA service and protocol name tables
netbase:
	@./scripts/build.sh netbase

## make tzdata      - compile the IANA time zone database into /usr/share/zoneinfo
tzdata:
	@./scripts/build.sh tzdata

## make locales     - compile the locales config/locales.conf names into the locale archive
locales:
	@./scripts/build.sh locales

## make glib        - build GLib, the C utility library syslog-ng is written against
glib:
	@./scripts/build.sh glib

## make json-c      - build the shared JSON library required by syslog-ng
json-c:
	@./scripts/build.sh json-c

## make pcre2       - build the shared regular-expression library used by GLib and syslog-ng
pcre2:
	@./scripts/build.sh pcre2

## make syslog-ng   - build syslog-ng, the daemon that answers /dev/log
syslog-ng:
	@./scripts/build.sh syslog-ng

## make logrotate   - build logrotate, which rotates and compresses /var/log
logrotate:
	@./scripts/build.sh logrotate

## make haproxy     - build HAProxy for the repository (it is not part of the image)
haproxy:
	@./scripts/build.sh haproxy

## make guix        - package GNU Guix from its binary tarball (not part of the image)
guix:
	@./scripts/build.sh guix

## make rootfs      - assemble the target root filesystem from the packaged trees
rootfs:
	@./scripts/build.sh rootfs

## make image       - create the live payload: the squashfs root and its initramfs
image:
	@./scripts/build.sh image

## make iso         - build a hybrid BIOS/UEFI bootable ISO from the live payload
iso:
	@./scripts/build.sh iso

## make rootfs-tarball - pack the assembled root filesystem into a bootable .tar.xz
rootfs-tarball:
	@./scripts/build.sh rootfs-tarball

## make disk-image  - build a ready-to-write disk image (.img and .qcow2, both xz)
disk-image:
	@./scripts/build.sh disk-image

## make installer-bundle - pack the three installers into one portable script
installer-bundle:
	@./scripts/make-installer-bundle.sh

## make docker-image - pack the root filesystem into a loadable container image
docker-image:
	@./scripts/make-docker-image.sh

## make docker-run   - load that image and run a shell in it (ARGS= for a command)
docker-run:
	@./scripts/run-docker-image.sh $(ARGS)

## make docker-push  - publish that image (needs SOWA_IMAGE_DESTINATION=host/repo:tag)
docker-push:
	@./scripts/push-docker-image.sh

## make recovery-image - pack the whole root filesystem into one bootable initramfs
recovery-image:
	@./scripts/recovery-image.sh

## make repo-key    - create the Ed25519 key that signs the package repository
repo-key:
	@./scripts/repo-key.sh

## make packages    - cut the image into signed binary packages and an index
packages:
	@./scripts/package.sh

## make publish-repo - assemble the repository under dist/ for an HTTPS server
publish-repo:
	@./scripts/publish-repo.sh

## make release-key   - create the separate offline Ed25519 release-signing key
release-key:
	@./scripts/release-key.sh

## make release-manifest - sign a manifest of every current release artifact
release-manifest:
	@./scripts/release-manifest.sh

## make verify-release - verify the signed release manifest and every artifact
verify-release:
	@./scripts/verify-release.sh

## make run-qemu    - boot the live payload in QEMU, without the boot loader
run-qemu: iso
	@./scripts/run-qemu.sh

## make run-recovery - build and boot the single-initramfs recovery image in QEMU
run-recovery: recovery-image
	@./scripts/run-qemu.sh --recovery

## make run-iso     - build and boot the release ISO in QEMU
run-iso: iso
	@./scripts/run-qemu.sh --iso

## make run-install - boot the ISO in QEMU with a blank disk to run sowa-setup
run-install: iso
	@./scripts/run-qemu.sh --install

## make run-disk    - boot the installed disk in QEMU on legacy BIOS
run-disk:
	@./scripts/run-qemu.sh --disk

## make run-disk-uefi - boot the installed disk in QEMU on UEFI (OVMF) firmware
run-disk-uefi:
	@./scripts/run-qemu.sh --disk-uefi

## make run-disk-image - boot the prebuilt disk image in QEMU on legacy BIOS
run-disk-image:
	@./scripts/run-qemu.sh --disk-image

## make run-disk-image-uefi - boot the prebuilt disk image in QEMU on UEFI (OVMF)
run-disk-image-uefi:
	@./scripts/run-qemu.sh --disk-image-uefi

## make all         - build all pinned components, the rootfs, and the image
all:
	@./scripts/build.sh all

## make clean       - remove builds, sysroot, stamps, and artifacts
clean:
	@./scripts/clean.sh

## make distclean   - also remove downloaded and extracted sources
distclean:
	@./scripts/clean.sh --all
