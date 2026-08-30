#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

targets=("${BUILD_DIR}" "${SYSROOT}" "${TOOLS_DIR}" "${ROOTFS_DIR}" "${STAMP_DIR}" "${ARTIFACT_DIR}" \
    "${PKG_STAGE_DIR}" "${PKG_META_DIR}" "${PKG_MERGED_DIR}" "${PACKAGE_DIR}")
if [[ "${1:-}" == --all ]]; then
    targets+=("${SOURCE_DIR}" "${DOWNLOAD_DIR}")
fi

for target_path in "${targets[@]}"; do
    case "${target_path}" in
        "${WORK_DIR}"/*|"${DOWNLOAD_DIR}"|"${ARTIFACT_DIR}") ;;
        *) die "refusing to remove unexpected path: ${target_path}" ;;
    esac
    if [[ -e "${target_path}" ]]; then
        log "remove ${target_path}"
        # The package staging trees include the Guix store, whose read-only
        # directories plain rm cannot empty.
        remove_tree "${target_path}"
    fi
done
