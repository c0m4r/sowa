#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

bash_completion_source="$(prepare_source bash-completion)"
build_tree="${BUILD_DIR}/bash-completion"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage bash-completion)"

build_triplet="$(sh "${bash_completion_source}/config.guess")"
cd "${build_tree}"
"${bash_completion_source}/configure" \
    --prefix=/usr \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}"
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

[[ -f "${pkgdir}/usr/share/bash-completion/bash_completion" ]] \
    || die "bash-completion main script was not installed"
[[ -f "${pkgdir}/etc/profile.d/bash_completion.sh" ]] \
    || die "bash-completion profile loader was not installed"
[[ -f "${pkgdir}/usr/share/bash-completion/completions-core/htop.bash" ]] \
    || die "bash-completion command definitions were not installed"
pkg_merge bash-completion
log "installed bash-completion $(source_version bash-completion)"
