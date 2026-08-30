#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

linux_source="$(prepare_source linux)"
headers_stage="${BUILD_DIR}/linux-headers"
reset_build_dir "${headers_stage}"

make -C "${linux_source}" O="${headers_stage}" ARCH="${KARCH}" mrproper
make -C "${linux_source}" O="${headers_stage}" ARCH="${KARCH}" headers
find "${headers_stage}/usr/include" -name '.*' -delete
mkdir -p "${SYSROOT}/usr"
cp -a "${headers_stage}/usr/include" "${SYSROOT}/usr/"

test -f "${SYSROOT}/usr/include/linux/version.h"
