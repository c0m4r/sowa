#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# libgcc_s.so.1 - the GCC support library and unwinder - copied out of the
# toolchain and into the sysroot, so that it is part of the image rather than of
# the build machinery.
#
# Nothing in the image records a NEEDED entry for it: GCC links libgcc
# statically into a C program. That is why the image has gone without it, and
# why its absence shows up nowhere at build time. It is needed anyway, for two
# reasons that have nothing to do with how these programs are linked:
#
#   - glibc dlopens it by name the first time a thread unwinds. pthread_exit and
#     pthread_cancel are implemented as a forced unwind and the unwinder lives
#     here, so a threaded program calling either one dies with "libgcc_s.so.1
#     must be installed for pthread_exit to work" - which is what "haproxy -v"
#     does today.
#   - a binary built anywhere else links it outright. Rust and C++ programs
#     unwind through it, so a prebuilt program - rustup-init is the first one
#     most people run - cannot start without it.
#
# It belongs to the runtime ABI a glibc system carries next to libc itself
# rather than to the compiler, so it goes to /usr/lib64 with every other shared
# library and falls to sowa-base, which already owns the glibc runtime. Nothing
# runs ldconfig here and there is no /etc/ld.so.cache; /usr/lib64 is one of the
# loader's built-in directories, which is how every other library in it is
# found.
#
# The path comes from the compiler rather than from a guess at the multilib
# layout: this is the copy its own driver would link and the loader would open.
libgcc="$("${TARGET}-gcc" -print-file-name=libgcc_s.so.1)"
[[ -f "${libgcc}" ]] || die "the final GCC did not build libgcc_s.so.1"

install -D -m 0755 "${libgcc}" "${SYSROOT}/usr/lib64/libgcc_s.so.1"
"${TARGET}-strip" "${SYSROOT}/usr/lib64/libgcc_s.so.1"

# The soname is the whole point of the file: glibc's dlopen asks for that exact
# name, so a copy installed under any other one would be invisible to it.
"${TARGET}-readelf" -d "${SYSROOT}/usr/lib64/libgcc_s.so.1" \
    | grep -q 'soname: \[libgcc_s\.so\.1\]' \
    || die "the installed libgcc_s does not carry the libgcc_s.so.1 soname"
"${TARGET}-readelf" -d "${SYSROOT}/usr/lib64/libgcc_s.so.1" | grep -q 'libc.so.6'
log "installed libgcc_s.so.1 from GCC $(source_version gcc)"
