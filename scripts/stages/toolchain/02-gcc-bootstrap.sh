#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

gcc_source="$(prepare_source gcc)"
build_tree="${BUILD_DIR}/gcc-bootstrap"

link_gcc_prerequisites "${gcc_source}"

reset_build_dir "${build_tree}"
cd "${build_tree}"
"${gcc_source}/configure" \
    --prefix="${TOOLS_DIR}" \
    --target="${TARGET}" \
    --with-sysroot="${SYSROOT}" \
    --with-newlib \
    --without-headers \
    --enable-languages=c \
    --disable-bootstrap \
    --disable-shared \
    --disable-threads \
    --disable-multilib \
    --disable-nls \
    --disable-libatomic \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libssp \
    --disable-libstdcxx \
    --disable-libvtv \
    --disable-libsanitizer \
    --disable-libmpx
make -j"${JOBS}" all-gcc
make install-gcc

"${TARGET}-gcc" --version | sed -n '1p'
