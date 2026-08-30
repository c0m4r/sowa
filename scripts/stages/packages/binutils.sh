#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# binutils again, and the same tarball stage 01 builds - but that one produced a
# cross assembler and linker that run on the build machine, and this one is the
# assembler and linker that run on the target. GCC is nothing without them: the
# compiler proper writes assembly and then execs "as" and "ld", so a machine
# with gcc and no binutils cannot produce an object file, let alone a program.
#
# Three triplets rather than two, and each says something different:
#
#   --build   the machine doing the compiling, this host
#   --host    the machine that runs the result, which is the target
#   --target  the machine the result emits code for, also the target
#
# host and target being equal is what makes this a native binutils: ld's
# configuration adds the system library directories only when it is building a
# native linker, and the tools are installed under their plain names rather than
# behind a triplet prefix. build being different from host is what makes it a
# cross build of one - the "Canadian cross" the GNU build system is named for -
# and it is why the checks below can only read the output rather than run it.
#
# Nothing here calls target_configure_env: that names the cross compiler in CC,
# AS, LD and the rest, and this tree distinguishes the build, host and target
# compilers itself from the triplets above. Telling it twice is how a Canadian
# cross ends up building the host's programs with the build machine's tools.

binutils_source="$(prepare_source binutils)"
build_tree="${BUILD_DIR}/binutils-native"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage binutils)"

build_triplet="$(gcc -dumpmachine)"
cd "${build_tree}"
# The flags stage 01 uses, plus --with-system-zlib: the image has zlib, and a
# second copy of it compiled into these programs is a copy nothing would ever
# update. zstd is deliberately off. It is built later in a clean traversal, but
# remains in an incremental sysroot; leaving its probe on auto would therefore
# make cached and clean builds of binutils link different libraries.
# --with-sysroot=/ makes the search paths sysroot-relative, so ld reads them out
# of whatever root it is pointed at rather than out of a path fixed when this
# was built - which is what makes "ld --sysroot" work on the target.
"${binutils_source}/configure" \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --target="${TARGET}" \
    --with-sysroot=/ \
    --with-system-zlib \
    --without-zstd \
    --disable-nls \
    --disable-werror \
    --disable-multilib \
    --disable-gprofng \
    --enable-default-hash-style=gnu \
    --enable-new-dtags
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

# binutils installs a second copy of the tools GCC drives into the "tool
# directory", /usr/<triplet>/bin, which is one of the places the compiler looks
# before PATH. The copies are byte-for-byte the programs in /usr/bin and cost
# some twenty megabytes in an image whose whole point is that it is small, so
# they become relative symbolic links into ../../bin - the compiler follows one
# exactly as it would open the other.
tooldir="${pkgdir}/usr/${TARGET}/bin"
if [[ -d "${tooldir}" ]]; then
    while IFS= read -r tool; do
        name="$(basename "${tool}")"
        [[ -f "${pkgdir}/usr/bin/${name}" ]] \
            || die "the tool directory carries ${name}, which is not in /usr/bin"
        ln -sfn "../../bin/${name}" "${tool}"
    done < <(find "${tooldir}" -type f)
fi

for program in addr2line ar as c++filt elfedit ld ld.bfd nm objcopy objdump \
    ranlib readelf size strings strip; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] \
        || die "binutils did not install ${program}"
done
while IFS= read -r program; do
    "${TARGET}-strip" "${program}"
done < <(find "${pkgdir}/usr/bin" -type f -perm -u+x -print)
# libbfd, libopcodes and libctf are what a program that reads object files links
# against, and they are compiled with debugging information the way everything
# in this tree is. Removing it leaves libraries that still link - the symbol
# table a linker reads is not the debug information - at a third of the size.
while IFS= read -r archive; do
    "${TARGET}-strip" --strip-debug "${archive}"
done < <(find "${pkgdir}/usr/lib64" -name '*.a' -print)

# These run on the target, so nothing here can execute one to ask it a
# question; what can be read is the file. A native binutils built by mistake for
# the build machine is the failure this catches, and it would otherwise be found
# by a user whose first "cc hello.c" says "cannot execute binary file".
"${TARGET}-readelf" -h "${pkgdir}/usr/bin/ld" \
    | grep -q 'Advanced Micro Devices X86-64' \
    || die "ld was not built for the target architecture"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/ld" | grep -q 'libc.so.6'
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/ld" | grep -q 'libz.so.1' \
    || die "ld did not link the image's zlib; --with-system-zlib did not take"
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/ld" | grep -q 'libzstd.so'; then
    die "ld links zstd even though it is not a declared binutils dependency"
fi
# The links that replaced the tool directory's copies have to resolve inside the
# staging tree, or the compiler follows one to nothing.
while IFS= read -r link; do
    [[ -e "${link}" ]] || die "dangling tool directory link: ${link#"${pkgdir}"}"
done < <(find "${pkgdir}/usr/${TARGET}/bin" -type l 2>/dev/null)
cross_gcc_version="$("${TARGET}-gcc" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/ld" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "binutils was not built with the cross compiler"
pkg_merge binutils
log "installed native binutils $(source_version binutils)"
