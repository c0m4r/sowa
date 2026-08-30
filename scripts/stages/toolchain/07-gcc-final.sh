#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

gcc_source="$(prepare_source gcc)"
build_tree="${BUILD_DIR}/gcc-final"
reset_build_dir "${build_tree}"

cd "${build_tree}"
"${gcc_source}/configure" \
    --prefix="${TOOLS_DIR}" \
    --target="${TARGET}" \
    --with-sysroot="${SYSROOT}" \
    --enable-languages=c,c++ \
    --enable-shared \
    --enable-threads=posix \
    --enable-__cxa_atexit \
    --enable-clocale=gnu \
    --disable-bootstrap \
    --disable-multilib \
    --disable-nls \
    --disable-libsanitizer
make -j"${JOBS}" all-gcc all-target-libgcc all-target-libatomic \
    all-target-libstdc++-v3
make install-gcc install-target-libgcc install-target-libatomic \
    install-target-libstdc++-v3

printf 'int main(void) { return 0; }\n' | "${TARGET}-gcc" -x c - -o conftest
"${TARGET}-readelf" -l conftest | grep -q 'Requesting program interpreter'

printf '#include <iostream>\nint main() { std::cout << "sowa"; }\n' \
    | "${TARGET}-g++" -x c++ - -o conftest-cxx
"${TARGET}-readelf" -d conftest-cxx | grep -q 'libstdc++.so'
