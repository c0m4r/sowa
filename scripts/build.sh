#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

# stage_key() is normally called through command substitution, so assignments
# made inside it live only in that subshell. Seed what can be seeded now, in
# this process, so every later key calculation inherits it: the shared digest
# and the driver's own package-to-stage table. The toolchain digest is seeded
# separately, in toolchain(), because it is only settled once the toolchain
# stamps are.
stage_shared_digest > /dev/null
load_stage_dispatch

# Package helpers form a dependency graph, but they are ordinary shell
# functions rather than make targets. A full build therefore reaches common
# providers (especially the toolchain) through many branches. Remember a
# successful visit for this driver process so each stage is checked and logged
# once. The recorded stamp value is the guard rather than a bare boolean: when
# a rebuilt provider invalidates a consumer by removing or replacing its stamp,
# the consumer is eligible to be visited again later in the same run.
declare -A VISITED_STAGE_KEYS=()

stage_was_visited() {
    local name="$1"
    local stamp="${STAMP_DIR}/${name}.done"
    [[ -n "${VISITED_STAGE_KEYS[${name}]+x}" && -f "${stamp}" ]] || return 1
    [[ "$(cat "${stamp}")" == "${VISITED_STAGE_KEYS[${name}]}" ]]
}

remember_stage_visit() {
    local name="$1"
    local stamp="${STAMP_DIR}/${name}.done"
    [[ -s "${stamp}" ]] || die "stage ${name} completed without a keyed stamp"
    VISITED_STAGE_KEYS["${name}"]="$(cat "${stamp}")"
}

run_stage_once() {
    local name="$1"
    if stage_was_visited "${name}"; then
        return 0
    fi
    run_stage "$@" || return $?
    remember_stage_visit "${name}"
}

toolchain() {
    run_stage_once toolchain/01-binutils
    run_stage_once toolchain/02-gcc-bootstrap
    run_stage_once toolchain/03-linux-headers
    run_stage_once toolchain/04-glibc-bootstrap
    run_stage_once toolchain/05-libgcc
    run_stage_once toolchain/06-glibc
    run_stage_once toolchain/07-gcc-final
    # This digest must be taken after the toolchain stamps have been checked or
    # rebuilt. Like the shared digest above, keeping it in the driver shell
    # prevents every target stage from recomputing all seven toolchain keys.
    if [[ -z "${STAGE_TOOLCHAIN_DIGEST}" ]]; then
        STAGE_TOOLCHAIN_DIGEST="$(stage_toolchain_digest)"
    fi
    # The two pieces of the toolchain's output that are also part of the image:
    # the GCC support library and the C++ runtime. They install into the sysroot
    # and belong to no component's staging tree, so they run through the
    # rootfs-package helper for the invalidation alone: a root filesystem
    # assembled before they existed has to be assembled again.
    run_rootfs_package_stage toolchain/libgcc-runtime -
    run_rootfs_package_stage toolchain/libstdcxx-runtime -
}

# The stage names config/kernel-x86_64.fragment, so an edited fragment is part
# of its key; invalidate_stale_image_inputs is what carries a rebuilt kernel
# through to the image that wraps it.
kernel() {
    toolchain
    run_stage_once image/kernel
}

# Runs a stage that contributes files to the root filesystem. Its key answers
# for the recipe, the pinned sources and the toolchain (see "stage identity" in
# lib/common.sh); what a key cannot see is the staging tree itself, which is the
# record of which files the package owns, so a tree left behind by a build from
# before packaging existed - or removed by hand - reruns the stage as well.
# "-" marks a stage whose output is an artifact rather than a staged tree.
#
# Trailing arguments are the stamps of the stages that link what this one
# builds. They are removed whenever it actually runs, which is how a rebuilt
# shared library rebuilds its consumers; scripts/lint.sh derives the same lists
# from the staged trees' ELF NEEDED records and reports the ones left out.
run_rootfs_package_stage() {
    local name="$1"
    local package="$2"
    local script
    script="$(stage_script "${name}")"
    shift 2
    if stage_was_visited "${name}"; then
        if [[ "${package}" == - ]] || pkg_staged "${package}"; then
            return 0
        fi
    fi
    if stage_up_to_date "${name}" "${script}" "${package}"; then
        if [[ "${package}" == - ]] || pkg_staged "${package}"; then
            log "skip ${name} (already complete)"
            remember_stage_visit "${name}"
            return 0
        fi
        log "rerun ${name} (no staged tree for package ${package})"
    elif [[ -f "${STAMP_DIR}/${name}.done" ]]; then
        log "rerun ${name} (its inputs changed since it last ran)"
    fi
    stage_execute "${name}" "${script}" "${package}" "${script}" || return $?
    remember_stage_visit "${name}"
    rm -f "${STAMP_DIR}/image/10-rootfs.done" \
        "${STAMP_DIR}/image/11-initramfs.done" "$@"
}

bash_package() {
    toolchain
    run_rootfs_package_stage packages/bash bash
}

# sowa-init is built from src/init, which is part of this repository rather
# than a pinned tarball. The stage names that directory, so an edited source
# file is part of its key exactly as an edited recipe is.
init_package() {
    toolchain
    run_rootfs_package_stage packages/init sowa-init
}

bash_completion_package() {
    bash_package
    run_rootfs_package_stage packages/bash-completion bash-completion
}

ncurses_package() {
    toolchain
    run_rootfs_package_stage packages/ncurses ncurses \
        "${STAMP_DIR}/packages/nano.done" "${STAMP_DIR}/packages/vim.done" \
        "${STAMP_DIR}/packages/htop.done" "${STAMP_DIR}/packages/python.done" \
        "${STAMP_DIR}/packages/util-linux.done" \
        "${STAMP_DIR}/packages/procps.done" \
        "${STAMP_DIR}/packages/gnupg.done" "${STAMP_DIR}/packages/less.done" \
        "${STAMP_DIR}/packages/mtr.done" "${STAMP_DIR}/packages/ncdu.done"
}

nano_package() {
    ncurses_package
    run_rootfs_package_stage packages/nano nano
}

openssl_package() {
    toolchain
    run_rootfs_package_stage packages/openssl openssl \
        "${STAMP_DIR}/packages/python.done" "${STAMP_DIR}/packages/curl.done" \
        "${STAMP_DIR}/packages/openssh.done" \
        "${STAMP_DIR}/packages/nginx.done" \
        "${STAMP_DIR}/packages/haproxy.done" "${STAMP_DIR}/packages/git.done" \
        "${STAMP_DIR}/packages/wget.done" \
        "${STAMP_DIR}/packages/openvpn.done" \
        "${STAMP_DIR}/packages/bind.done" "${STAMP_DIR}/packages/nmap.done" \
        "${STAMP_DIR}/packages/syslog-ng.done"
}

ca_certificates_package() {
    openssl_package
    run_rootfs_package_stage packages/ca-certificates ca-certificates
}

vim_package() {
    ncurses_package
    run_rootfs_package_stage packages/vim vim
}

htop_package() {
    ncurses_package
    run_rootfs_package_stage packages/htop htop
}

zlib_package() {
    toolchain
    run_rootfs_package_stage packages/zlib zlib \
        "${STAMP_DIR}/packages/python.done" "${STAMP_DIR}/packages/curl.done" \
        "${STAMP_DIR}/packages/openssh.done" \
        "${STAMP_DIR}/packages/nginx.done" \
        "${STAMP_DIR}/packages/haproxy.done" \
        "${STAMP_DIR}/packages/gnupg.done" "${STAMP_DIR}/packages/git.done" \
        "${STAMP_DIR}/packages/wget.done" "${STAMP_DIR}/packages/mandoc.done" \
        "${STAMP_DIR}/packages/binutils.done" \
        "${STAMP_DIR}/packages/gcc.done" "${STAMP_DIR}/packages/file.done" \
        "${STAMP_DIR}/packages/zstd.done" "${STAMP_DIR}/packages/nmap.done" \
        "${STAMP_DIR}/packages/sudo.done" "${STAMP_DIR}/packages/glib.done" \
        "${STAMP_DIR}/packages/syslog-ng.done" \
        "${STAMP_DIR}/packages/pciutils.done" \
        "${STAMP_DIR}/packages/lshw.done" \
        "${STAMP_DIR}/packages/btrfs-progs.done"
}

inih_package() {
    toolchain
    run_rootfs_package_stage packages/inih inih \
        "${STAMP_DIR}/packages/xfsprogs.done"
}

libaio_package() {
    toolchain
    run_rootfs_package_stage packages/libaio libaio \
        "${STAMP_DIR}/packages/lvm2.done"
}

# The build python is CPython's own compiler: stage host/python installs the
# pinned release for this machine and stage packages/python freezes the image's
# interpreter with it. Both keys carry the python lock row, so a bump rebuilds
# both without anybody having to ask the installed interpreter its version -
# and the image's stamp goes when the build interpreter is replaced, because an
# image built by the previous one carries its bytecode rather than the new
# one's. That last link is written here rather than left to the toolchain
# digest: the build interpreter is not part of the cross toolchain.
python_package() {
    ncurses_package
    openssl_package
    zlib_package
    if ! stage_up_to_date host/python "$(stage_script host/python)" -; then
        rm -f "${STAMP_DIR}/packages/python.done"
    fi
    run_stage_once host/python
    run_rootfs_package_stage packages/python python
}

# The monitoring backend is Sowa's own dependency-free Python source. It is
# repository-only because publishing machine telemetry is a deployment choice,
# and its stage stops at the package staging tree for that reason.
sowa_monitor_package() {
    python_package
    run_rootfs_package_stage packages/sowa-monitor sowa-monitor
}

# The on-demand language/runtime installers are Sowa-owned shell scripts, but
# every command they invoke is supplied by another image package. Visiting
# those providers here keeps a direct "make custom-installers" topological as
# well as making the runtime dependency row true of a clean build.
custom_installers_package() {
    bash_package
    coreutils_package
    grep_package
    sed_package
    findutils_package
    curl_package
    tar_package
    gzip_package
    xz_package
    zstd_package
    unzip_package
    gnupg_package
    run_rootfs_package_stage packages/custom-installers custom-installers
}

curl_package() {
    ca_certificates_package
    zlib_package
    run_rootfs_package_stage packages/curl curl \
        "${STAMP_DIR}/packages/git.done"
}

# e2fsprogs declines libblkid and libuuid and links util-linux's instead, so
# that stage has to have run first.
e2fsprogs_package() {
    util_linux_package
    run_rootfs_package_stage packages/e2fsprogs e2fsprogs
}

# LVM2 is built against xfsprogs' public XFS headers - that is what its
# HAVE_XFS_XFS_H assertion checks - so a rebuilt xfsprogs has to carry through
# to it. The link is a header rather than a shared library, which is exactly why
# it has to be written down here: scripts/lint.sh derives the rest of these
# lists from ELF NEEDED records, and a header dependency leaves no such trace.
xfsprogs_package() {
    inih_package
    util_linux_package
    liburcu_package
    run_rootfs_package_stage packages/xfsprogs xfsprogs \
        "${STAMP_DIR}/packages/lvm2.done"
}

btrfs_progs_package() {
    util_linux_package
    zlib_package
    zstd_package
    run_rootfs_package_stage packages/btrfs-progs btrfs-progs
}

dosfstools_package() {
    toolchain
    run_rootfs_package_stage packages/dosfstools dosfstools
}

grub_package() {
    toolchain
    run_rootfs_package_stage packages/grub grub
}

libxcrypt_package() {
    toolchain
    run_rootfs_package_stage packages/libxcrypt libxcrypt \
        "${STAMP_DIR}/packages/openssh.done" \
        "${STAMP_DIR}/packages/nginx.done" "${STAMP_DIR}/packages/perl.done" \
        "${STAMP_DIR}/packages/haproxy.done" \
        "${STAMP_DIR}/packages/shadow.done" \
        "${STAMP_DIR}/packages/inetutils.done" \
        "${STAMP_DIR}/packages/sudo.done"
}

openssh_package() {
    openssl_package
    zlib_package
    libxcrypt_package
    run_rootfs_package_stage packages/openssh openssh
}

cron_package() {
    toolchain
    run_rootfs_package_stage packages/cronie cronie
}

iproute2_package() {
    toolchain
    run_rootfs_package_stage packages/iproute2 iproute2
}

iptables_package() {
    toolchain
    run_rootfs_package_stage packages/iptables iptables
}

# nginx is published to the repository but never shipped in the image, so its
# stage stops at the staging tree. The rootfs stage still has to see that tree -
# it is where the package's manifest is cut from - which is why this belongs to
# the build like any other component and not to 'make packages'.
# The init script the package ships comes from src/nginx rather than from the
# tarball - upstream's idea of a service is a systemd unit - and the stage names
# that directory, so an edit to it is part of the key.
nginx_package() {
    openssl_package
    zlib_package
    run_rootfs_package_stage packages/nginx nginx
}

# Docker is also repository-only, but its one package combines eight upstream
# components, including a separately pinned Compose plugin binary. Each of them
# reaches the stage through lock_record, so each is in the recorded source list
# its key is built from, and its service glue in src/docker is named by the
# stage - which is the whole of what the hand-written input list here used to
# have to keep up with.
docker_package() {
    toolchain
    run_rootfs_package_stage packages/docker docker
}

# util-linux owns libblkid, libmount and libuuid, so e2fsprogs is rebuilt
# whenever it is - the tools that link those libraries have to be built against
# the copy that ends up in the image.
util_linux_package() {
    ncurses_package
    run_rootfs_package_stage packages/util-linux util-linux \
        "${STAMP_DIR}/packages/e2fsprogs.done" \
        "${STAMP_DIR}/packages/xfsprogs.done" \
        "${STAMP_DIR}/packages/btrfs-progs.done" \
        "${STAMP_DIR}/packages/lvm2.done"
}

mdadm_package() {
    toolchain
    run_rootfs_package_stage packages/mdadm mdadm
}

lvm2_package() {
    util_linux_package
    libaio_package
    xfsprogs_package
    run_rootfs_package_stage packages/lvm2 lvm2
}

coreutils_package() {
    toolchain
    run_rootfs_package_stage packages/coreutils coreutils
}

grep_package() {
    toolchain
    run_rootfs_package_stage packages/grep grep
}

sed_package() {
    toolchain
    run_rootfs_package_stage packages/sed sed
}

gawk_package() {
    toolchain
    run_rootfs_package_stage packages/gawk gawk
}

findutils_package() {
    toolchain
    run_rootfs_package_stage packages/findutils findutils
}

diffutils_package() {
    toolchain
    run_rootfs_package_stage packages/diffutils diffutils
}

make_package() {
    toolchain
    run_rootfs_package_stage packages/make make
}

perl_package() {
    libxcrypt_package
    run_rootfs_package_stage packages/perl perl
}

chrony_package() {
    toolchain
    run_rootfs_package_stage packages/chrony chrony
}

nic_package() {
    toolchain
    run_rootfs_package_stage packages/nic nic
}

# The account tools. login is on the boot path - the inittab respawns it - so
# this is not a package the image can be built without.
shadow_package() {
    libxcrypt_package
    run_rootfs_package_stage packages/shadow shadow
}

tar_package() {
    toolchain
    run_rootfs_package_stage packages/tar tar
}

gzip_package() {
    toolchain
    run_rootfs_package_stage packages/gzip gzip
}

# unzip is built against libbz2 so it can read bzip2-compressed members, so a
# rebuilt bzip2 has to invalidate it the way util-linux invalidates e2fsprogs.
bzip2_package() {
    toolchain
    run_rootfs_package_stage packages/bzip2 bzip2 \
        "${STAMP_DIR}/packages/zip.done" "${STAMP_DIR}/packages/unzip.done" \
        "${STAMP_DIR}/packages/gnupg.done" "${STAMP_DIR}/packages/file.done"
}

xz_package() {
    toolchain
    run_rootfs_package_stage packages/xz xz \
        "${STAMP_DIR}/packages/file.done" "${STAMP_DIR}/packages/zstd.done"
}

zip_package() {
    toolchain
    run_rootfs_package_stage packages/zip zip
}

unzip_package() {
    bzip2_package
    run_rootfs_package_stage packages/unzip unzip
}

sevenzip_package() {
    toolchain
    run_rootfs_package_stage packages/7zip 7zip
}

# procps-ng needs ncurses for top and watch, so it follows that stage the way
# nano, vim and htop do.
procps_package() {
    ncurses_package
    run_rootfs_package_stage packages/procps procps
}

# pciutils keeps the PCI name database compressed and exposes libpci as a
# shared development interface, so its library follows zlib. lshw reads that
# same database instead of carrying the older copy in its own release tarball;
# it also links zlib directly for its other compressed hardware tables.
pciutils_package() {
    zlib_package
    run_rootfs_package_stage packages/pciutils pciutils
}

lshw_package() {
    pciutils_package
    run_rootfs_package_stage packages/lshw lshw
}

# GnuPG and the seven other tarballs it is built from. pinentry needs ncurses,
# gpg compresses with zlib and bzip2, and dirmngr verifies a keyserver against
# the same CA bundle curl uses.
gnupg_package() {
    ncurses_package
    zlib_package
    bzip2_package
    ca_certificates_package
    run_rootfs_package_stage packages/gnupg gnupg
}

# Git links libcurl for its HTTP transports, which brings OpenSSL, zlib and the
# CA bundle with it, and installs Perl scripts that the image's Perl runs.
git_package() {
    curl_package
    perl_package
    run_rootfs_package_stage packages/git git
}

# Wget links OpenSSL for https:// and zlib for a gzip-encoded response, and
# verifies certificates against the bundle the ca-certificates package installs
# where OpenSSL looks by default.
wget_package() {
    ca_certificates_package
    zlib_package
    run_rootfs_package_stage packages/wget wget
}

# libcap-ng is in the image because OpenVPN 2.7 will not configure without it -
# the check is unconditional on Linux - so a rebuilt libcap-ng has to invalidate
# the package that links it.
libcap_ng_package() {
    toolchain
    run_rootfs_package_stage packages/libcap-ng libcap-ng \
        "${STAMP_DIR}/packages/openvpn.done"
}

# OpenVPN links OpenSSL for the TLS control channel and libcap-ng for the
# capability it keeps across --user.
openvpn_package() {
    openssl_package
    libcap_ng_package
    run_rootfs_package_stage packages/openvpn openvpn
}

# wireguard-tools links nothing: wg carries its own netlink code and wg-quick is
# a Bash script. What it depends on is the kernel - CONFIG_WIREGUARD - and, at
# run time, the ip, iptables and sysctl commands wg-quick drives, all of which
# are already in the image.
wireguard_package() {
    toolchain
    run_rootfs_package_stage packages/wireguard-tools wireguard-tools
}

# mandoc links zlib and nothing else: it reads a compressed manual page itself
# rather than piping one through a decompressor.
mandoc_package() {
    zlib_package
    run_rootfs_package_stage packages/mandoc mandoc
}

# less is the pager mandoc compiles in as BINM_PAGER, so a rebuilt less has to
# redo mandoc: the path is baked into the binary, and a man that pages through a
# program which is not there prints nothing at all.
less_package() {
    ncurses_package
    run_rootfs_package_stage packages/less less \
        "${STAMP_DIR}/packages/mandoc.done"
}

# zstd is built before file: libmagic links libzstd, so the library has to be in
# the sysroot by the time that stage configures, and a rebuilt zstd has to redo
# it the way the other three compression libraries do.
zstd_package() {
    zlib_package
    xz_package
    run_rootfs_package_stage packages/zstd zstd \
        "${STAMP_DIR}/packages/file.done" \
        "${STAMP_DIR}/packages/plocate.done" \
        "${STAMP_DIR}/packages/btrfs-progs.done"
}

# file reads inside compressed files, so all four compression libraries in the
# image are ahead of it and a rebuild of any of them has to redo this stage.
file_package() {
    zlib_package
    bzip2_package
    xz_package
    zstd_package
    run_rootfs_package_stage packages/file file
}

inetutils_package() {
    toolchain
    run_rootfs_package_stage packages/inetutils inetutils
}

mtr_package() {
    ncurses_package
    run_rootfs_package_stage packages/mtr mtr
}

whois_package() {
    toolchain
    run_rootfs_package_stage packages/whois whois
}

# The three libraries BIND 9.20 refuses to configure without. Each is its own
# package rather than a static copy private to bind: five BIND libraries link
# them, so a private copy would be five copies, and libcap brings setcap,
# getcap and capsh, which the image had no equivalent of. All three are found
# through pkg-config, so a rebuild of any of them has to redo packages/bind - the
# trailing entry that fails silently when it is left out.
libuv_package() {
    toolchain
    run_rootfs_package_stage packages/libuv libuv \
        "${STAMP_DIR}/packages/bind.done"
}

liburcu_package() {
    toolchain
    run_rootfs_package_stage packages/liburcu liburcu \
        "${STAMP_DIR}/packages/bind.done" \
        "${STAMP_DIR}/packages/xfsprogs.done"
}

libcap_package() {
    toolchain
    run_rootfs_package_stage packages/libcap libcap \
        "${STAMP_DIR}/packages/bind.done"
}

bind_package() {
    openssl_package
    libuv_package
    liburcu_package
    libcap_package
    run_rootfs_package_stage packages/bind bind
}

# tcpdump uses libpcap for the Linux packet socket and BPF compiler.  Keep the
# library distinct: it is a public development interface in this self-hosting
# image and is useful to programs beyond tcpdump itself.
libpcap_package() {
    toolchain
    run_rootfs_package_stage packages/libpcap libpcap \
        "${STAMP_DIR}/packages/tcpdump.done" \
        "${STAMP_DIR}/packages/nmap.done"
}

tcpdump_package() {
    libpcap_package
    run_rootfs_package_stage packages/tcpdump tcpdump
}

# Nmap shares libpcap with tcpdump, but bundles the smaller libraries it needs
# privately.  Keeping that split means programs built on the target use the
# image's libpcap ABI instead of acquiring a second, private copy through
# Nmap's source tree.
nmap_package() {
    openssl_package
    zlib_package
    libpcap_package
    pcre2_package
    run_rootfs_package_stage packages/nmap nmap
}

strace_package() {
    toolchain
    run_rootfs_package_stage packages/strace strace
}

# The userspace side of the kernel's Landlock support: one program compiled from
# samples/ in the same tarball image/kernel is built from, so it needs nothing
# but the C library and the uapi headers toolchain/03-linux-headers installed.
landlock_package() {
    toolchain
    run_rootfs_package_stage packages/landlock landlock
}

ncdu_package() {
    ncurses_package
    run_rootfs_package_stage packages/ncdu ncdu
}

sudo_package() {
    libxcrypt_package
    run_rootfs_package_stage packages/sudo sudo
}

which_package() {
    toolchain
    run_rootfs_package_stage packages/which which
}

plocate_package() {
    zstd_package
    run_rootfs_package_stage packages/plocate plocate
}

# The three packages that make the shipped GCC usable on something other than a
# single .c file: m4 and the autoconf written in it, and the pkg-config every
# configure script queries. autoconf freezes its macros with the host's m4 but
# records the image's, so a rebuilt m4 has to redo it.
m4_package() {
    toolchain
    run_rootfs_package_stage packages/m4 m4 \
        "${STAMP_DIR}/packages/autoconf.done"
}

autoconf_package() {
    m4_package
    perl_package
    run_rootfs_package_stage packages/autoconf autoconf
}

pkgconf_package() {
    toolchain
    run_rootfs_package_stage packages/pkgconf pkgconf
}

# The native toolchain: the assembler and linker GCC drives, and GCC itself.
# binutils links the image's zlib for the compressed debug sections it reads and
# writes, so it follows that stage; everything else it needs is the C library.
binutils_package() {
    zlib_package
    run_rootfs_package_stage packages/binutils binutils \
        "${STAMP_DIR}/packages/gcc.done"
}

# GCC is built after binutils and not only packaged after it: the compiler's
# configure looks for the assembler and linker it will drive and records what
# they can do, so building it against anything but the binutils the image ships
# would bake in the wrong answers.
gcc_package() {
    binutils_package
    run_rootfs_package_stage packages/gcc gcc
}

# netbase: the IANA service and protocol name tables. Nothing is built - it is
# four data files - but they belong to the base system rather than to any one
# program, because getaddrinfo(3) resolves a service name through them for
# whatever asks. It depends on nothing here for the same reason.
netbase_package() {
    run_rootfs_package_stage packages/netbase netbase
}

# tzdata: the IANA time zone database. Data again, and base-system data for the
# same reason netbase is - glibc resolves a TZ name through it on behalf of
# whatever asked, so it belongs to no one program. The only thing compiled is
# zic, and that is built for this machine rather than the target, so the stage
# depends on nothing here either.
tzdata_package() {
    run_rootfs_package_stage packages/tzdata tzdata
}

# The compiled locales. Data again, and the third stage in a row that belongs
# to no one program: what it produces is /usr/lib/locale/locale-archive, which
# every program in the image reads through setlocale(3). It depends on the
# toolchain rather than on nothing, unlike netbase and tzdata, because the
# program that writes the archive is the sysroot's own localedef - the pinned
# glibc's, run through the sysroot's loader, so that no part of the build
# host's C library decides what this image's locales look like.
#
# The stage names both of its other inputs - config/locales.conf and the
# locale-gen sources in src/locales - so both are in its key.
locales_package() {
    toolchain
    run_rootfs_package_stage packages/locales locales
}

# PCRE2 is shared because both GLib and syslog-ng link it directly. Keeping one
# copy also gives both consumers the same regular-expression implementation.
pcre2_package() {
    toolchain
    run_rootfs_package_stage packages/pcre2 pcre2 \
        "${STAMP_DIR}/packages/glib.done" \
        "${STAMP_DIR}/packages/syslog-ng.done" \
        "${STAMP_DIR}/packages/nmap.done"
}

# GLib exists in this image for syslog-ng. Its stage absorbs private libffi,
# links shared PCRE2, and links the image's zlib for GIO's compressor.
glib_package() {
    pcre2_package
    zlib_package
    run_rootfs_package_stage packages/glib glib \
        "${STAMP_DIR}/packages/syslog-ng.done"
}

# syslog-ng 4.12 makes json-c a hard dependency. It is a shared package so the
# daemon core and its loadable JSON module resolve the same implementation.
json_c_package() {
    toolchain
    run_rootfs_package_stage packages/json-c json-c \
        "${STAMP_DIR}/packages/syslog-ng.done"
}

# syslog-ng: the daemon that answers /dev/log. It links GLib, which it dlopens
# its modules against, plus OpenSSL for the TLS transport.
syslog_ng_package() {
    glib_package
    json_c_package
    openssl_package
    run_rootfs_package_stage packages/syslog-ng syslog-ng
}

# logrotate depends on nothing built here - popt is absorbed statically by its
# own stage - but it runs gzip to compress what it rotates, which is a run-time
# dependency rather than a link and is written down in config/packages.conf.
logrotate_package() {
    toolchain
    run_rootfs_package_stage packages/logrotate logrotate
}

# GNU Guix, the third of the packages the image does not ship - and the only
# component that is unpacked rather than built, so it depends on nothing here:
# the store in the tarball carries its own C library and its own interpreter.
# The glue in the package comes from src/guix rather than from the tarball, and
# the stage names that directory, so an edit to it is part of the key.
guix_package() {
    run_rootfs_package_stage packages/guix guix
}

# HAProxy is published to the repository and left out of the image, exactly as
# nginx is - and, like nginx, it takes its init script from src/ rather than
# from upstream, which the stage names and its key therefore covers.
haproxy_package() {
    openssl_package
    zlib_package
    libxcrypt_package
    run_rootfs_package_stage packages/haproxy haproxy
}

# The rootfs stage copies the overlay in and splits ownership using the package
# table. It builds no package of its own, so its key carries the whole of both
# tables as well as the overlay it names: a new repository key, a changed
# pkg.conf or a bumped package release all reassemble the tree.
rootfs() {
    # sowa-init's package metadata names Bash as a runtime dependency, and
    # dependency stage keys are part of a consumer's identity. Visit Bash
    # first so a clean build records its real key rather than "absent" and
    # needing a second make invocation to converge.
    bash_package
    init_package
    bash_completion_package
    nano_package
    ca_certificates_package
    vim_package
    htop_package
    python_package
    sowa_monitor_package
    curl_package
    util_linux_package
    e2fsprogs_package
    xfsprogs_package
    btrfs_progs_package
    mdadm_package
    lvm2_package
    dosfstools_package
    grub_package
    openssh_package
    cron_package
    iproute2_package
    iptables_package
    nginx_package
    coreutils_package
    grep_package
    sed_package
    gawk_package
    findutils_package
    diffutils_package
    make_package
    perl_package
    chrony_package
    nic_package
    shadow_package
    tar_package
    gzip_package
    bzip2_package
    xz_package
    zip_package
    unzip_package
    sevenzip_package
    procps_package
    pciutils_package
    lshw_package
    gnupg_package
    git_package
    wget_package
    libcap_ng_package
    openvpn_package
    wireguard_package
    # Ahead of mandoc, which compiles the pager's path in: building less first
    # keeps the stage that depends on it from being invalidated behind its back.
    less_package
    mandoc_package
    binutils_package
    gcc_package
    m4_package
    autoconf_package
    pkgconf_package
    zstd_package
    file_package
    inetutils_package
    mtr_package
    whois_package
    bind_package
    tcpdump_package
    nmap_package
    strace_package
    landlock_package
    ncdu_package
    sudo_package
    which_package
    plocate_package
    netbase_package
    tzdata_package
    locales_package
    glib_package
    json_c_package
    syslog_ng_package
    logrotate_package
    custom_installers_package
    haproxy_package
    guix_package
    # Docker is the last of the optional packages, and belongs here for the
    # same reason nginx and guix do rather than only behind "make docker": the
    # rootfs stage cuts every optional package's manifest and licence set from
    # its staging tree, and checks the command_not_found hints against the
    # commands it carries. None of that can be done for a package the build has
    # not produced, so a full build has to produce all of them - it is built
    # last because it is the longest optional package and nothing else waits on it.
    docker_package
    run_stage_once image/10-rootfs
}

# A stage key says whether a stage's own inputs changed. It cannot say that a
# stage this one consumes has run again, and image/11-initramfs consumes two
# whose output is not among its inputs: the assembled root filesystem, and the
# kernel.
#
# The root filesystem is the case with a trap in it. A rootfs can be assembled
# on its own after an image has been made, and that deliberately removes the
# kernel again - image/10-rootfs starts from the sysroot, while
# image/11-initramfs is the stage that adds /boot/vmlinuz and its licences - so
# a surviving image stamp must not make the image look complete. The kernel is the plain case: a
# rebuilt kernel is a different image. liveinit needs no rule of its own, since
# the stage compiles it from src/liveinit and therefore names it.
invalidate_stale_image_inputs() {
    local stamp="${STAMP_DIR}/image/11-initramfs.done"
    local input
    [[ -f "${stamp}" ]] || return 0
    for input in image/10-rootfs image/kernel; do
        if [[ "${STAMP_DIR}/${input}.done" -nt "${stamp}" ]]; then
            log "${input} ran since the image was made; redoing the image"
            rm -f "${stamp}"
            return 0
        fi
    done
}

image() {
    kernel
    rootfs
    invalidate_stale_image_inputs
    run_stage_once image/11-initramfs
}

iso() {
    image
    # The ISO wraps the current kernel and release initramfs, so it is always
    # regenerated rather than stamp-gated; the heavy inputs are cached by image.
    begin_stage image/iso
    "$(stage_script image/iso)"
}

# The rootfs tarball is cut from the assembled root filesystem after the image
# stage has embedded the kernel, so its stamp has to answer to that stage rather
# than to a source tree of its own: whenever the image is regenerated the
# tarball it was packed from is stale.
invalidate_stale_rootfs_tarball() {
    local stamp="${STAMP_DIR}/image/rootfs-tarball.done"
    local image_stamp="${STAMP_DIR}/image/11-initramfs.done"
    [[ -f "${stamp}" ]] || return 0
    if [[ ! -f "${image_stamp}" || "${image_stamp}" -nt "${stamp}" ]]; then
        log "the image changed since the rootfs tarball was last built; redoing it"
        rm -f "${stamp}"
    fi
}

rootfs_tarball() {
    image
    invalidate_stale_rootfs_tarball
    run_stage_once image/rootfs-tarball
}

# The disk image is cut from the same assembled tree as the tarball and is stale
# for the same reason: a regenerated image is a different system. An edit to the
# stage itself - a different size, a different boot menu - is already in its
# key, since it is the only artifact whose contents the stage script decides
# rather than only copies.
invalidate_stale_disk_image() {
    local stamp="${STAMP_DIR}/image/disk-image.done"
    local image_stamp="${STAMP_DIR}/image/11-initramfs.done"
    [[ -f "${stamp}" ]] || return 0
    if [[ ! -f "${image_stamp}" || "${image_stamp}" -nt "${stamp}" ]]; then
        log "the image changed since the disk image was last built; redoing it"
        rm -f "${stamp}"
    fi
}

disk_image() {
    image
    invalidate_stale_disk_image
    run_stage_once image/disk-image
}

readonly GOAL="${1:-all}"
claim_terminal_title "${GOAL}"
require_keyed_stage_state

case "${GOAL}" in
    toolchain) toolchain ;;
    kernel) kernel ;;
    bash) bash_package ;;
    init) init_package ;;
    bash-completion) bash_completion_package ;;
    ncurses) ncurses_package ;;
    nano) nano_package ;;
    openssl) openssl_package ;;
    ca-certificates) ca_certificates_package ;;
    vim) vim_package ;;
    htop) htop_package ;;
    zlib) zlib_package ;;
    inih) inih_package ;;
    libaio) libaio_package ;;
    curl) curl_package ;;
    python) python_package ;;
    sowa-monitor) sowa_monitor_package ;;
    custom-installers) custom_installers_package ;;
    e2fsprogs) e2fsprogs_package ;;
    xfsprogs) xfsprogs_package ;;
    # "brfs-progs" is the same compatibility spelling sowa-setup accepts for
    # SOWA_SETUP_ROOT_FILESYSTEM; the real name is the first one.
    btrfs-progs | brfs-progs) btrfs_progs_package ;;
    dosfstools) dosfstools_package ;;
    grub) grub_package ;;
    libxcrypt) libxcrypt_package ;;
    openssh) openssh_package ;;
    cron) cron_package ;;
    iproute2) iproute2_package ;;
    iptables) iptables_package ;;
    nginx) nginx_package ;;
    docker) docker_package ;;
    util-linux) util_linux_package ;;
    mdadm) mdadm_package ;;
    lvm2) lvm2_package ;;
    coreutils) coreutils_package ;;
    grep) grep_package ;;
    sed) sed_package ;;
    gawk) gawk_package ;;
    findutils) findutils_package ;;
    diffutils) diffutils_package ;;
    make) make_package ;;
    perl) perl_package ;;
    chrony) chrony_package ;;
    nic) nic_package ;;
    shadow) shadow_package ;;
    tar) tar_package ;;
    gzip) gzip_package ;;
    bzip2) bzip2_package ;;
    xz) xz_package ;;
    zip) zip_package ;;
    unzip) unzip_package ;;
    7zip) sevenzip_package ;;
    procps) procps_package ;;
    pciutils) pciutils_package ;;
    lshw) lshw_package ;;
    gnupg) gnupg_package ;;
    git) git_package ;;
    wget) wget_package ;;
    libcap-ng) libcap_ng_package ;;
    openvpn) openvpn_package ;;
    wireguard) wireguard_package ;;
    mandoc) mandoc_package ;;
    less) less_package ;;
    file) file_package ;;
    inetutils) inetutils_package ;;
    mtr) mtr_package ;;
    whois) whois_package ;;
    libuv) libuv_package ;;
    liburcu) liburcu_package ;;
    libcap) libcap_package ;;
    bind) bind_package ;;
    libpcap) libpcap_package ;;
    tcpdump) tcpdump_package ;;
    nmap) nmap_package ;;
    strace) strace_package ;;
    landlock) landlock_package ;;
    ncdu) ncdu_package ;;
    sudo) sudo_package ;;
    which) which_package ;;
    plocate) plocate_package ;;
    m4) m4_package ;;
    autoconf) autoconf_package ;;
    pkgconf) pkgconf_package ;;
    zstd) zstd_package ;;
    binutils) binutils_package ;;
    gcc) gcc_package ;;
    netbase) netbase_package ;;
    tzdata) tzdata_package ;;
    locales) locales_package ;;
    pcre2) pcre2_package ;;
    glib) glib_package ;;
    json-c) json_c_package ;;
    syslog-ng) syslog_ng_package ;;
    logrotate) logrotate_package ;;
    haproxy) haproxy_package ;;
    guix) guix_package ;;
    rootfs) rootfs ;;
    image) image ;;
    iso) iso ;;
    rootfs-tarball) rootfs_tarball ;;
    disk-image) disk_image ;;
    all) image ;;
    *) die "usage: $0 [toolchain|kernel|init|bash|bash-completion|ncurses|nano|openssl|ca-certificates|vim|htop|zlib|inih|libaio|curl|python|sowa-monitor|custom-installers|util-linux|e2fsprogs|xfsprogs|btrfs-progs (brfs-progs)|mdadm|lvm2|dosfstools|grub|libxcrypt|openssh|cron|iproute2|iptables|nginx|docker|coreutils|grep|sed|gawk|findutils|diffutils|make|perl|chrony|nic|shadow|tar|gzip|bzip2|xz|zstd|zip|unzip|7zip|procps|pciutils|lshw|gnupg|git|wget|libcap-ng|openvpn|wireguard|less|mandoc|binutils|gcc|m4|autoconf|pkgconf|file|inetutils|mtr|whois|libuv|liburcu|libcap|bind|which|plocate|libpcap|tcpdump|nmap|strace|landlock|ncdu|netbase|tzdata|locales|pcre2|glib|json-c|syslog-ng|logrotate|haproxy|guix|rootfs|image|iso|rootfs-tarball|disk-image|all]" ;;
esac
