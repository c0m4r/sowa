#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# inih is a small shared C library required by current xfsprogs.  Its Meson
# project defaults to also building a C++ wrapper and its tests; XFS uses only
# the C interface, so neither belongs in this package.
require_command meson
require_command ninja

inih_source="$(prepare_source inih)"
build_tree="${BUILD_DIR}/inih"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage inih)"

target_configure_env
cross_file="${build_tree}/cross.ini"
cat > "${cross_file}" <<EOF
[binaries]
c = '${TARGET}-gcc'
ar = '${TARGET}-ar'
strip = '${TARGET}-strip'

[properties]
sys_root = '${SYSROOT}'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

meson setup "${build_tree}/obj" "${inih_source}" \
    --cross-file="${cross_file}" \
    --prefix=/usr \
    --libdir=lib64 \
    --buildtype=release \
    -Ddefault_library=shared \
    -Ddistro_install=true \
    -Dwith_INIReader=false \
    -Dtests=false
ninja -C "${build_tree}/obj" -j "${JOBS}"
DESTDIR="${pkgdir}" ninja -C "${build_tree}/obj" install

library="$(find "${pkgdir}/usr/lib64" -type f -name 'libinih.so.0*' -print -quit)"
[[ -n "${library}" ]] || die "inih did not install libinih.so.0"
"${TARGET}-strip" --strip-unneeded "${library}"
[[ -f "${pkgdir}/usr/include/ini.h" ]] || die "inih did not install ini.h"
[[ -f "${pkgdir}/usr/lib64/pkgconfig/inih.pc" ]] \
    || die "inih did not install its pkg-config file"
[[ ! -e "${pkgdir}/usr/lib64/libinih.a" ]] \
    || die "inih installed a static library; the image ships none"
"${TARGET}-readelf" -d "${library}" | grep -q 'SONAME.*libinih\.so\.0' \
    || die "libinih carries no libinih.so.0 soname"

pkg_merge inih
log "installed inih $(source_version inih)"
