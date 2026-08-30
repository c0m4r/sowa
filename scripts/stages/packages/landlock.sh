#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# The userspace side of CONFIG_SECURITY_LANDLOCK.
#
# Landlock needs no daemon, no library and no configuration file: a program
# calls three system calls and is restricted from then on. So unlike
# wireguard-tools, which exists because an in-kernel tunnel cannot be created
# without something to speak netlink to it, nothing here is required for the
# kernel feature to work. What is required is a way to use it from a shell, and
# a way to find out whether the kernel this image booted actually has it -
# neither of which anyone should have to write C to get.
#
# That program is samples/landlock/sandboxer.c, from the same pinned tarball
# image/kernel builds the kernel from and toolchain/03-linux-headers installs
# the uapi headers from. Taking it from there rather than pinning a separate
# project is the whole reason it is worth shipping: the access types it knows
# how to ask for and the ones this kernel knows how to enforce are the same
# release by construction, so the "you should update the running kernel" and
# "you should update this sandboxer" hints it prints on a mismatch can never
# fire on a Sowa image. It is upstream's demonstration program, and it is named
# landlock-sandboxer rather than sandboxer because "sandboxer" says nothing
# about which sandbox on a system that also has seccomp and capabilities.
#
# Nothing else in the image uses Landlock. sshd is sandboxed with seccomp, which
# is a different mechanism answering a different question - which system calls
# are reachable, rather than which files and ports are.

linux_source="$(prepare_source linux)"
sandboxer_source="${linux_source}/samples/landlock/sandboxer.c"
[[ -f "${sandboxer_source}" ]] \
    || die "samples/landlock/sandboxer.c is not in the Linux tarball; upstream moved or removed it"
build_tree="${BUILD_DIR}/landlock"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage landlock)"

target_configure_env
program="${build_tree}/landlock-sandboxer"
# One translation unit, one link, no build system: the sample's own Makefile is
# a kbuild userprogs stub that only works inside a configured kernel tree, and
# what it amounts to is this line plus an include path for the headers that are
# already in the sysroot. -Werror is deliberately not here - a 2017 program
# compiled by GCC 16 warns about things that were not warnings when it was
# written, and a new upstream warning must not be the reason an image cannot be
# built. The hardening flags are the ones packages/docker compiles tini with.
"${CC}" -std=gnu11 -Wall -Wextra -O2 -D_FORTIFY_SOURCE=2 \
    -fstack-protector-strong --param=ssp-buffer-size=4 -Wformat \
    -Wl,-z,relro,-z,now \
    -o "${program}" "${sandboxer_source}"

install -D -m 0755 "${program}" "${pkgdir}/usr/bin/landlock-sandboxer"
"${TARGET}-strip" "${pkgdir}/usr/bin/landlock-sandboxer"
[[ "$(stat -c '%a' "${pkgdir}/usr/bin/landlock-sandboxer")" == 755 ]] \
    || die "landlock-sandboxer is not mode 0755"
# The manual page is Sowa's: upstream documents the sandboxer in
# Documentation/userspace-api/landlock.rst, which is not a manual page and is
# not in the image, and a command whose only documentation is the usage it
# prints on stderr is a command nobody reads about before running.
install -D -m 0644 "${PROJECT_ROOT}/src/landlock/man/landlock-sandboxer.1" \
    "${pkgdir}/usr/share/man/man1/landlock-sandboxer.1"

# mandoc finds a page by the directory it is in and the name of the file, so a
# page whose .Dt says something else is one man finds and apropos files
# elsewhere.
page="${pkgdir}/usr/share/man/man1/landlock-sandboxer.1"
grep -qi '^\.Dt LANDLOCK-SANDBOXER 1$' "${page}" \
    || die "landlock-sandboxer.1 does not declare itself as landlock-sandboxer(1)"
grep -q '^\.Os ' "${page}" \
    || die "landlock-sandboxer.1 has no .Os line; mandoc would put the build host's uname in its footer"

# What the compiler produced. The architecture check is the one that catches a
# stage that picked up the build machine's cc, since a host binary and a cross
# one are otherwise the same kind of file.
"${TARGET}-readelf" -h "${pkgdir}/usr/bin/landlock-sandboxer" \
    | grep -q 'Advanced Micro Devices X86-64' \
    || die "landlock-sandboxer was not built for the target architecture"
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/landlock-sandboxer" \
    | grep -qE 'RPATH|RUNPATH'; then
    die "landlock-sandboxer carries a run-time library path"
fi
needed="$("${TARGET}-readelf" -d "${pkgdir}/usr/bin/landlock-sandboxer" \
    | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p')"
[[ "${needed}" == "libc.so.6" ]] \
    || die "landlock-sandboxer links ${needed:-nothing}; it should need the C library and nothing else"
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/landlock-sandboxer" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "landlock-sandboxer was not built with the cross compiler"

# The policy the program reads is its whole interface, and it is read from the
# environment rather than from arguments - so a build that had somehow lost it
# would still compile, still link, still run, and simply sandbox nothing. These
# are the names, in the binary.
for setting in LL_FS_RO LL_FS_RW LL_TCP_BIND LL_TCP_CONNECT LL_SCOPED; do
    grep -aqF "${setting}" "${pkgdir}/usr/bin/landlock-sandboxer" \
        || die "landlock-sandboxer does not name ${setting}; its policy interface did not reach the binary"
done
# The ABI the sandboxer was compiled to use, taken from the source rather than
# assumed, and the newest access type that ABI has. If a kernel bump raises the
# sample's LANDLOCK_ABI_LAST, the uapi headers in the sysroot rise with it and
# this keeps saying so; if the two ever disagree the compile fails first, which
# is the point of taking both from one tarball.
abi_last="$(sed -n 's/^#define LANDLOCK_ABI_LAST[[:space:]]\+\([0-9]\+\)$/\1/p' \
    "${sandboxer_source}")"
[[ -n "${abi_last}" ]] \
    || die "the sandboxer source no longer defines LANDLOCK_ABI_LAST"
grep -q 'LANDLOCK_RESTRICT_SELF_LOG_NEW_EXEC_ON' \
    "${SYSROOT}/usr/include/linux/landlock.h" \
    || die "the installed linux/landlock.h predates Landlock ABI 7; the sysroot headers and the sandboxer come from different kernels"

# The build-path check, over the compiler's output rather than over the whole
# staging tree. The other file this package installs is the manual page, which
# is repository text copied in verbatim and cannot carry a build path - but it
# does name /root/sowa-howto/sandboxing.txt, and a checkout at /sowa makes the
# build root a substring of that. packages/locales installs a page naming
# /root/sowa-howto/locale.txt for the same reason and runs no such check at all;
# what is worth asserting here is that nothing about this machine was compiled
# into the binary, and that is what this asks.
if grep -aqF "${PROJECT_ROOT}" "${pkgdir}/usr/bin/landlock-sandboxer"; then
    die "landlock-sandboxer has the build path compiled into it"
fi
pkg_merge landlock
log "installed landlock-sandboxer, Landlock ABI ${abi_last}, from Linux $(source_version linux)"
