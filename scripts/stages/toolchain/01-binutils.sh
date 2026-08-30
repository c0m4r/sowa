#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

source_tree="$(prepare_source binutils)"
build_tree="${BUILD_DIR}/binutils"
reset_build_dir "${build_tree}"

cd "${build_tree}"
"${source_tree}/configure" \
    --prefix="${TOOLS_DIR}" \
    --target="${TARGET}" \
    --with-sysroot="${SYSROOT}" \
    --disable-nls \
    --disable-werror \
    --disable-multilib \
    --disable-gprofng \
    --enable-default-hash-style=gnu \
    --enable-new-dtags
make -j"${JOBS}"
make install

"${TARGET}-ld" --version | sed -n '1p'
