#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

build_tree="${BUILD_DIR}/gcc-bootstrap"
[[ -f "${build_tree}/Makefile" ]] || die "GCC bootstrap build directory is missing"

make -C "${build_tree}" -j"${JOBS}" all-target-libgcc
make -C "${build_tree}" install-target-libgcc
