#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# libstdc++.so.6 - the GNU C++ runtime - copied out of the toolchain and into
# the sysroot, for the same reason and in the same way as libgcc_s.so.1 next
# door: it is part of the image rather than of the build machinery.
#
# Nothing in the image records a NEEDED entry for it, so the library's absence
# has never shown up at build time. What it costs is everything that comes from
# outside: a prebuilt C++ program - a container runtime, a language server,
# clang, node - links libstdc++.so.6 outright and dies at "error while loading
# shared libraries" before main(), and this image ships no compiler to rebuild
# it statically. libgcc_s.so.1 is already here for that argument; this is the
# other half of the same pair, since a C++ binary needs both and libstdc++
# itself links libgcc_s.
#
# It belongs to the runtime ABI a glibc system carries next to libc rather than
# to the compiler, so it goes to /usr/lib64 with every other shared library and
# falls to sowa-base, which already owns the glibc runtime and libgcc_s.
# Nothing runs ldconfig here and there is no /etc/ld.so.cache; /usr/lib64 is one
# of the loader's built-in directories, which is how every other library in it
# is found. Only the soname is installed - the usual libstdc++.so.6.0.NN file
# and its symbolic link say which minor release this is, and nothing without a
# cache to rebuild or a linker to satisfy ever asks.
#
# The path comes from the compiler rather than from a guess at the multilib
# layout: this is the copy its own driver would link and the loader would open.
libstdcxx="$("${TARGET}-g++" -print-file-name=libstdc++.so.6)"
[[ -f "${libstdcxx}" ]] || die "the final GCC did not build libstdc++.so.6"

install -D -m 0755 "${libstdcxx}" "${SYSROOT}/usr/lib64/libstdc++.so.6"
"${TARGET}-strip" "${SYSROOT}/usr/lib64/libstdc++.so.6"

# The soname is the whole point of the file: a foreign binary asks the loader
# for that exact name, so a copy installed under any other one is invisible.
"${TARGET}-readelf" -d "${SYSROOT}/usr/lib64/libstdc++.so.6" \
    | grep -q 'soname: \[libstdc++\.so\.6\]' \
    || die "the installed libstdc++ does not carry the libstdc++.so.6 soname"
# It unwinds through libgcc_s and allocates through libc, and both have to be in
# the image already or this library is one more thing that cannot be loaded.
for needed in libgcc_s.so.1 libc.so.6; do
    "${TARGET}-readelf" -d "${SYSROOT}/usr/lib64/libstdc++.so.6" \
        | grep -q "Shared library: \[${needed}\]" \
        || die "libstdc++.so.6 does not link ${needed}; the C++ runtime is not the expected build"
    [[ -f "${SYSROOT}/usr/lib64/${needed}" || -f "${SYSROOT}/lib64/${needed}" ]] \
        || die "libstdc++.so.6 needs ${needed}, which is not in the sysroot"
done
log "installed libstdc++.so.6 from GCC $(source_version gcc)"
