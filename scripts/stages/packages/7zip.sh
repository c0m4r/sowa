#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# 7-Zip, from Igor Pavlov's own sources rather than from the long-unmaintained
# p7zip fork. Upstream's Linux build is the "Alone2" bundle, which is the whole
# command-line program: 7z, xz, zip, tar, rar and the rest of the formats in one
# binary, called 7zz.
#
# The source tarball has no top-level directory - it unpacks Asm, C, CPP and DOC
# straight into the current directory - so it is taken apart in the build tree
# rather than through prepare_source.

archive="$(locked_download_path 7zip)"
build_tree="${BUILD_DIR}/7zip"
reset_build_dir "${build_tree}"
validate_archive_members "${archive}"
tar -xf "${archive}" -C "${build_tree}"
pkgdir="$(pkg_stage 7zip)"

[[ -d "${build_tree}/CPP/7zip/Bundles/Alone2" ]] \
    || die "the 7-Zip sources do not contain the Alone2 bundle"

target_configure_env
cd "${build_tree}/CPP/7zip/Bundles/Alone2"
# This is the only C++ program in the image, and it stays statically linked
# against the C++ runtime. The image does carry libstdc++.so.6 and
# libgcc_s.so.1 now - toolchain/libstdcxx-runtime.sh and
# toolchain/libgcc-runtime.sh install both - but they are there for binaries
# brought in from outside, which link them outright and have no compiler here
# to be rebuilt with. Nothing Sowa builds depends on the C++ runtime, and this
# is the one stage that could change that; keeping the flags is what keeps the
# statement true. The readelf check below holds it in place.
#
# CROSS_COMPILE is the variable upstream's makefiles derive CC and CXX from;
# CXX is then overridden outright to carry the static-runtime flags.
#
# Upstream compiles with -Werror against a warning set it tunes per GCC
# release, which means every compiler newer than the one it was tuned for turns
# a new diagnostic into a failed build - GCC 16 does exactly that here. The
# warnings are kept and the error promotion is dropped: this is a released
# upstream tarball, and a warning in it is not Sowa's to fix.
make -j"${JOBS}" -f ../../cmpl_gcc.mak \
    CROSS_COMPILE="${TARGET}-" \
    CXX="${TARGET}-g++ -static-libstdc++ -static-libgcc" \
    CFLAGS_WARN_WALL="-Wall -Wextra" \
    IS_X64=1

[[ -x b/g/7zz ]] || die "7-Zip did not produce the 7zz binary"
install -D -m 0755 b/g/7zz "${pkgdir}/usr/bin/7zz"
# Also provide the established "7z" name used by scripts and documentation.
ln -s 7zz "${pkgdir}/usr/bin/7z"

"${TARGET}-strip" "${pkgdir}/usr/bin/7zz"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/7zz" | grep -q 'libc.so.6'
for unwanted in libstdc++ libgcc_s; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/7zz" | grep -q "${unwanted}"; then
        die "7zz links ${unwanted} dynamically; no program Sowa builds may depend on the C++ runtime"
    fi
done
"${TARGET}-readelf" -h "${pkgdir}/usr/bin/7zz" \
    | grep -q 'Advanced Micro Devices X86-64' \
    || die "7zz was not built for the target architecture"
pkg_keep_staged 7zip
log "staged 7-Zip $(source_version 7zip) for the repository"
