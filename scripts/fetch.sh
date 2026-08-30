#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_command curl
require_command sha256sum

claim_terminal_title fetch
# The lock file is the whole work list, so the title can carry a real position.
total="$(awk -F'|' '$1 != "" && $1 !~ /^#/ { count++ } END { print count + 0 }' "${LOCK_FILE}")"
index=0

while IFS='|' read -r name version archive url sha _directory; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    index=$((index + 1))
    show_progress "[${index}/${total}] ${name} ${version}"
    destination="${DOWNLOAD_DIR}/${archive}"
    if [[ -f "${destination}" ]] && printf '%s  %s\n' "${sha}" "${destination}" | sha256sum -c - >/dev/null 2>&1; then
        log "verified ${name} ${version}"
        continue
    fi

    temporary="${destination}.part.$$"
    rm -f "${temporary}"
    log "download ${name} ${version}"
    curl --fail --location --retry 3 --output "${temporary}" "${url}"
    printf '%s  %s\n' "${sha}" "${temporary}" | sha256sum -c - >/dev/null \
        || { rm -f "${temporary}"; die "checksum mismatch for ${archive}"; }
    mv "${temporary}" "${destination}"
done < "${LOCK_FILE}"

log "all sources are present and verified"
