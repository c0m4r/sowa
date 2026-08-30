#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# libaio supplies the Linux native AIO interface used by LVM2.  Upstream's
# makefile has no out-of-tree mode and installs a static library alongside the
# shared one, so build in a disposable copy and remove the unused archive.
libaio_source="$(prepare_source libaio)"
build_tree="${BUILD_DIR}/libaio"
reset_build_dir "${build_tree}"
cp -a "${libaio_source}/." "${build_tree}/"
pkgdir="$(pkg_stage libaio)"

target_configure_env
make -C "${build_tree}" -j"${JOBS}" \
    CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" \
    CFLAGS='-O2 -DNDEBUG -Wall -I. -fPIC' ENABLE_SHARED=1 all
make -C "${build_tree}" \
    CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" \
    CFLAGS='-O2 -DNDEBUG -Wall -I. -fPIC' ENABLE_SHARED=1 \
    DESTDIR="${pkgdir}" prefix=/usr libdir=/usr/lib64 install

rm -f "${pkgdir}/usr/lib64/libaio.a"
library="${pkgdir}/usr/lib64/libaio.so.1.0.2"
[[ -f "${library}" ]] || die "libaio did not install libaio.so.1.0.2"
"${TARGET}-strip" --strip-unneeded "${library}"
[[ -f "${pkgdir}/usr/include/libaio.h" ]] || die "libaio did not install libaio.h"
for link in libaio.so libaio.so.1; do
    [[ -L "${pkgdir}/usr/lib64/${link}" ]] \
        || die "libaio did not install the ${link} link"
done
"${TARGET}-readelf" -d "${library}" | grep -q 'SONAME.*libaio\.so\.1' \
    || die "libaio carries no libaio.so.1 soname"

pkg_merge libaio
log "installed libaio $(source_version libaio)"
