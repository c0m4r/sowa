#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GCC for the target: the compiler that runs on Sowa rather than the one that
# built it. Stages 02 and 07 produce a cross compiler in work/tools, which never
# enters the image; this is the same 16.2.0 source configured the other way
# round, so that the machine that boots the image can compile for itself.
#
# The triplets are the whole configuration (see packages/binutils.sh, which
# describes them): --build is this host, --host and --target are both Sowa, and
# host equal to target is what makes the result a native compiler rather than a
# second cross one. It drives the assembler and linker from the binutils
# package, which is why that stage comes first.
#
# What the image already carries does the rest of the work. The glibc headers
# and start files are in /usr/include and /usr/lib64, put there by the same
# stages that built the C library; libgcc_s.so.1 and libstdc++.so.6 are
# installed by toolchain/libgcc-runtime.sh and toolchain/libstdcxx-runtime.sh
# and belong to sowa-base; make, the binary this compiler is most often run
# from, is its own package already. With this stage the image is self-hosting:
# everything in the list above can be rebuilt on a running Sowa.

gcc_source="$(prepare_source gcc)"
link_gcc_prerequisites "${gcc_source}"
build_tree="${BUILD_DIR}/gcc-native"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage gcc)"

gcc_version="$(source_version gcc)"
build_triplet="$(gcc -dumpmachine)"
cd "${build_tree}"
# The configuration matches toolchain/07-gcc-final.sh wherever the two are
# asking for the same thing, so the compiler in the image and the compiler that
# built the image agree about the ABI: the same languages, the same threading
# model, the same C++ locale model, __cxa_atexit for the destructors of static
# objects.
#
# The rest is about what the image has. zlib is in it, so GCC links that one
# rather than compiling its own; zstd and isl are not in it, and are refused
# outright rather than left to whatever the build machine happens to have.
# libsanitizer is left out for the reason toolchain/07-gcc-final.sh leaves it
# out.
#
# --with-build-time-tools names the cross binutils this build asks about the
# target's assembler and linker. They are the same 2.47 the binutils package
# installs, so what GCC records here is true of the tools it will actually
# drive - a compiler that believes its assembler cannot do something is one
# that quietly emits worse code for the rest of its life.
"${gcc_source}/configure" \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --target="${TARGET}" \
    --with-build-time-tools="${TOOLS_DIR}/${TARGET}/bin" \
    --with-system-zlib \
    --without-zstd \
    --without-isl \
    --enable-languages=c,c++ \
    --enable-shared \
    --enable-threads=posix \
    --enable-__cxa_atexit \
    --enable-clocale=gnu \
    --disable-bootstrap \
    --disable-multilib \
    --disable-nls \
    --disable-libsanitizer
# The target libraries are compiled without debugging information. They are
# shipped, not debugged: -g on libstdc++ alone is tens of megabytes of an image
# that has no debugger to read them with.
make -j"${JOBS}" CFLAGS_FOR_TARGET='-O2' CXXFLAGS_FOR_TARGET='-O2'
make DESTDIR="${pkgdir}" install

# The C++ and unwinder runtimes belong to sowa-base, which installs them from
# this same GCC (toolchain/libgcc-runtime.sh and
# toolchain/libstdcxx-runtime.sh) so that the image carries them whether or not
# a compiler is installed. GCC's own copies are the same libraries built a
# second time, so they are dropped here and the development links are pointed
# at the sonames sowa-base ships, keeping runtime and development ownership
# separate.
for runtime in libgcc_s.so.1 libstdc++.so.6; do
    [[ -e "${SYSROOT}/usr/lib64/${runtime}" ]] \
        || die "sowa-base has no ${runtime}; the runtime stages must run first"
done
rm -f "${pkgdir}/usr/lib64/libgcc_s.so.1" \
    "${pkgdir}/usr/lib64/libstdc++.so.6" \
    "${pkgdir}"/usr/lib64/libstdc++.so.6.[0-9]*
ln -sfn libstdc++.so.6 "${pkgdir}/usr/lib64/libstdc++.so"
# A pretty-printer script named after the file that was just removed is a file
# nothing will ever load.
rm -f "${pkgdir}"/usr/lib64/libstdc++.so.6.[0-9]*-gdb.py

# "cc" is the name Make's built-in rules and two generations of configure
# scripts use, and GCC has never installed it.
ln -sfn gcc "${pkgdir}/usr/bin/cc"

for program in gcc g++ cpp c++ gcov "${TARGET}-gcc" "${TARGET}-g++"; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] || die "GCC did not install ${program}"
done
# The compiler proper. gcc is a driver: it decides what to run and runs cc1 for
# C, cc1plus for C++, then the assembler and the linker. Without these there is
# a command called gcc that cannot compile anything.
libexec="${pkgdir}/usr/libexec/gcc/${TARGET}/${gcc_version}"
for backend in cc1 cc1plus collect2 lto1; do
    [[ -x "${libexec}/${backend}" ]] || die "GCC did not install ${backend}"
done
# The internal directory: the start files that run before main, the static half
# of libgcc, and the headers GCC provides rather than glibc.
internal="${pkgdir}/usr/lib64/gcc/${TARGET}/${gcc_version}"
for object in crtbegin.o crtend.o libgcc.a libgcc_eh.a; do
    [[ -f "${internal}/${object}" ]] || die "GCC did not install ${object}"
done
[[ -f "${internal}/include/stddef.h" ]] \
    || die "GCC installed no header directory of its own"
# The C++ standard library, whose headers are the larger half of what "g++
# hello.cc" needs and are installed by this package rather than by glibc.
[[ -f "${pkgdir}/usr/include/c++/${gcc_version}/vector" ]] \
    || die "the C++ standard headers are missing"
[[ -f "${pkgdir}/usr/lib64/libstdc++.a" ]] || die "libstdc++.a is missing"
[[ "$(readlink "${pkgdir}/usr/lib64/libstdc++.so")" == libstdc++.so.6 ]] \
    || die "libstdc++.so does not point at the soname sowa-base installs"
for runtime in libgcc_s.so.1 libstdc++.so.6; do
    [[ ! -e "${pkgdir}/usr/lib64/${runtime}" ]] \
        || die "the gcc package claims ${runtime}, which belongs to sowa-base"
done

while IFS= read -r binary; do
    "${TARGET}-readelf" -h "${binary}" > /dev/null 2>&1 || continue
    "${TARGET}-strip" "${binary}"
done < <(find "${pkgdir}/usr/bin" "${pkgdir}/usr/libexec/gcc" -type f -perm -u+x)
while IFS= read -r archive; do
    "${TARGET}-strip" --strip-debug "${archive}"
done < <(find "${pkgdir}/usr/lib64" -name '*.a' -print)
while IFS= read -r library; do
    "${TARGET}-strip" --strip-unneeded "${library}"
done < <(find "${pkgdir}/usr/lib64" -name '*.so.*' -type f -print)

# Read out of the files, since nothing here can run one. A compiler accidentally
# built for the build machine is the failure this catches, and it is the sort
# that is only noticed on the target, by the first person to type "cc".
for binary in "${pkgdir}/usr/bin/gcc" "${libexec}/cc1plus"; do
    "${TARGET}-readelf" -h "${binary}" | grep -q 'Advanced Micro Devices X86-64' \
        || die "${binary##*/} was not built for the target architecture"
done
"${TARGET}-readelf" -d "${libexec}/cc1" | grep -q 'libz.so.1' \
    || die "cc1 did not link the image's zlib; --with-system-zlib did not take"
# GMP, MPFR and MPC are compiled into cc1 from the in-tree copies. If any of
# them had been picked up as a shared library instead, this would be a compiler
# that cannot start on a machine that has no such library - which the image is.
for absent in libgmp libmpfr libmpc libzstd libisl; do
    if "${TARGET}-readelf" -d "${libexec}/cc1" | grep -q "${absent}"; then
        die "cc1 links ${absent} dynamically; the image has no such library"
    fi
done
cross_gcc_version="$("${TARGET}-gcc" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/gcc" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "GCC was not built with the cross compiler"
pkg_merge gcc
log "installed native GCC ${gcc_version}"
