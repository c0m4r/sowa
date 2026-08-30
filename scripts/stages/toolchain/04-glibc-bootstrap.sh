#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

glibc_source="$(prepare_source glibc)"
build_tree="${BUILD_DIR}/glibc"
build_triplet="$("${glibc_source}/scripts/config.guess")"
reset_build_dir "${build_tree}"

cd "${build_tree}"
CC="${TARGET}-gcc" \
CXX="${TARGET}-g++" \
AR="${TARGET}-ar" \
RANLIB="${TARGET}-ranlib" \
"${glibc_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-headers="${SYSROOT}/usr/include" \
    --enable-kernel="${GLIBC_MIN_KERNEL}" \
    --disable-nscd \
    --disable-werror

make install-bootstrap-headers=yes install-headers DESTDIR="${SYSROOT}"
make -j"${JOBS}" csu/subdir_lib
mkdir -p "${SYSROOT}/usr/lib" "${SYSROOT}/usr/include/gnu"
install -m 0644 csu/crt1.o csu/crti.o csu/crtn.o "${SYSROOT}/usr/lib/"
"${TARGET}-gcc" -nostdlib -nostartfiles -shared -x c /dev/null \
    -o "${SYSROOT}/usr/lib/libc.so"
touch "${SYSROOT}/usr/include/gnu/stubs.h"
