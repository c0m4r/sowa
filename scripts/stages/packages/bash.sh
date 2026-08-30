#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

require_command patch
bash_source="$(prepare_source bash)"
build_tree="${BUILD_DIR}/bash"
reset_build_dir "${build_tree}"
cp -a "${bash_source}/." "${build_tree}/"
pkgdir="$(pkg_stage bash)"

patch_names=(
    bash53-001 bash53-002 bash53-003 bash53-004 bash53-005
    bash53-006 bash53-007 bash53-008 bash53-009 bash53-010
    bash53-011 bash53-012 bash53-013 bash53-014 bash53-015
)
for patch_name in "${patch_names[@]}"; do
    patch --directory="${build_tree}" --strip=0 \
        --input="$(locked_download_path "${patch_name}")"
done

# Compile command-history syslog support, but leave it disabled at runtime.
# The image has a syslog daemon, so this now works as soon as it is asked for -
# "shopt -s syslog_history" sends every command to /var/log/messages. It stays
# off by default because a shell that records what everyone typed is a policy
# decision, and a machine that wants it says so.
#
# SYS_BASHRC is the system-wide startup file for interactive shells, and
# upstream ships it commented out, so a Bash built as-is reads nothing but
# ~/.bashrc. It is enabled here because otherwise the only way to give an
# account a prompt and aliases is to write them into that account's home
# directory, leaving a user created after the image was built with a bare shell.
# The file it names is shipped by the overlay.
sed -i \
    -e 's@/\* #define SYSLOG_HISTORY \*/@#define SYSLOG_HISTORY@' \
    -e 's@/\* #define SYSLOG_SHOPT 1 \*/@#define SYSLOG_SHOPT 0@' \
    -e 's@/\* #define SYS_BASHRC "/etc/bash.bashrc" \*/@#define SYS_BASHRC "/etc/bash.bashrc"@' \
    "${build_tree}/config-top.h"

build_triplet="$(sh "${build_tree}/support/config.guess")"
target_configure_env
cd "${build_tree}"
bash_cv_strtold_broken=no ./configure \
    --prefix=/usr \
    --bindir=/bin \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --without-bash-malloc \
    --disable-nls
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/bin/bash"
ln -sfn bash "${pkgdir}/bin/sh"
"${TARGET}-readelf" -l "${pkgdir}/bin/bash" | grep -q 'Requesting program interpreter'
"${TARGET}-readelf" -d "${pkgdir}/bin/bash" | grep -q 'libc.so.6'
grep -q '^#define SYSLOG_HISTORY$' "${build_tree}/config-top.h"
grep -q '^#define SYSLOG_SHOPT 0$' "${build_tree}/config-top.h"
grep -q '^#define SYS_BASHRC "/etc/bash.bashrc"$' "${build_tree}/config-top.h"
pkg_merge bash
log "installed GNU Bash $(source_version bash) with opt-in syslog history"
