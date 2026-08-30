#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

build_tree="${BUILD_DIR}/glibc"
[[ -f "${build_tree}/Makefile" ]] || die "glibc bootstrap build directory is missing"

make -C "${build_tree}" -j"${JOBS}"
make -C "${build_tree}" install DESTDIR="${SYSROOT}"

loader="${SYSROOT}/lib64/ld-linux-x86-64.so.2"
if [[ ! -e "${loader}" ]]; then
    loader="${SYSROOT}/lib/ld-linux-x86-64.so.2"
fi
[[ -e "${loader}" ]] || die "glibc dynamic loader was not installed"
