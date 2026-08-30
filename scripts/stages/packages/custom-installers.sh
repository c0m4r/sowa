#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# These small, repository-owned installers fetch pinned upstream toolchains on
# demand. They are packaged separately from sowa-release so an administrator
# can remove or update the convenience layer without replacing the system's
# configuration and package manager.
source_dir="${PROJECT_ROOT}/src/custom-installers"
pkgdir="$(pkg_stage custom-installers)"
install -d -m 0755 "${pkgdir}/opt"

mapfile -t installers < <(find "${source_dir}" -mindepth 1 -maxdepth 1 \
    -type f -name 'install-*' -printf '%f\n' | LC_ALL=C sort)
((${#installers[@]} > 0)) \
    || die "no custom installers were found in ${source_dir}"

unexpected="$(find "${source_dir}" -mindepth 1 -maxdepth 1 \
    \( ! -type f -o ! -name 'install-*' \) -print -quit)"
[[ -z "${unexpected}" ]] \
    || die "unexpected custom-installer source: ${unexpected}"

for installer in "${installers[@]}"; do
    install -m 0755 "${source_dir}/${installer}" "${pkgdir}/opt/${installer}"
    [[ "$(stat -c '%a' "${pkgdir}/opt/${installer}")" == 755 ]] \
        || die "/opt/${installer} is not executable"
    grep -qx '#!/bin/sh' "${pkgdir}/opt/${installer}" \
        || die "/opt/${installer} does not use the system shell"
    sh -n "${pkgdir}/opt/${installer}" \
        || die "/opt/${installer} is not valid shell"
done

for installer in install-bun install-go install-node install-ollama install-rust \
    install-uv; do
    [[ -x "${pkgdir}/opt/${installer}" ]] \
        || die "the ${installer#install-} installer was not packaged"
done

pkg_merge custom-installers
log "installed custom installers ${DISTRO_VERSION}"
