#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_command curl
require_command sha256sum

human_size() {
    awk -v bytes="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", unit)
        value = bytes + 0
        unit_index = 1
        while (value >= 1024 && unit_index < 5) {
            value /= 1024
            unit_index++
        }
        if (unit_index == 1) printf "%d %s", value, unit[unit_index]
        else printf "%.1f %s", value, unit[unit_index]
    }'
}

# Print the primary URL followed by matching mirrors, retaining table order and
# suppressing duplicates. Prefix rules cover whole archives such as GNU and
# kernel.org; source rules are an escape hatch for a single awkward upstream.
source_urls() {
    local source_name="$1"
    local primary="$2"
    local kind match replacement candidate
    local -A seen=()

    printf '%s\n' "${primary}"
    seen["${primary}"]=1
    [[ -f "${MIRRORS_FILE}" ]] || return 0

    while IFS='|' read -r kind match replacement; do
        [[ -z "${kind}" || "${kind}" == \#* ]] && continue
        candidate=
        case "${kind}" in
            prefix)
                if [[ "${primary}" == "${match}"* ]]; then
                    candidate="${replacement}${primary#"${match}"}"
                fi
                ;;
            source)
                [[ "${source_name}" == "${match}" ]] && candidate="${replacement}"
                ;;
            *) die "unknown mirror rule '${kind}' in ${MIRRORS_FILE}" ;;
        esac
        [[ -n "${candidate}" && -z "${seen[${candidate}]:-}" ]] || continue
        printf '%s\n' "${candidate}"
        seen["${candidate}"]=1
    done < "${MIRRORS_FILE}"
}

temporary=
cleanup_partial_download() {
    [[ -z "${temporary}" ]] || rm -f -- "${temporary}"
}
trap cleanup_partial_download EXIT

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
        bytes="$(stat -c %s -- "${destination}")"
        log "verified ${name} ${version}: ${archive}, $(human_size "${bytes}") (${bytes} bytes), sha256 ${sha}"
        continue
    fi

    if [[ -f "${destination}" ]]; then
        actual="$(sha256sum -- "${destination}" | awk '{print $1}')"
        log "replace ${archive}: cached sha256 ${actual} does not match the lock"
    fi

    temporary="${destination}.part.$$"
    rm -f -- "${temporary}"
    mapfile -t urls < <(source_urls "${name}" "${url}")
    downloaded=0
    attempt=0
    for candidate in "${urls[@]}"; do
        attempt=$((attempt + 1))
        log "download ${name} ${version} (${attempt}/${#urls[@]}): ${candidate}"
        if metrics="$(curl --fail --location --retry 2 --retry-delay 1 \
            --connect-timeout "${FETCH_CONNECT_TIMEOUT:-20}" \
            --speed-limit "${FETCH_LOW_SPEED_LIMIT:-1024}" \
            --speed-time "${FETCH_LOW_SPEED_TIME:-30}" \
            --progress-bar --show-error \
            --output "${temporary}" \
            --write-out '%{http_code}|%{url_effective}|%{size_download}|%{speed_download}|%{time_total}|%{content_type}' \
            "${candidate}")"; then
            IFS='|' read -r http_code effective_url bytes speed elapsed content_type <<< "${metrics}"
            actual="$(sha256sum -- "${temporary}" | awk '{print $1}')"
            if [[ "${actual}" == "${sha}" ]]; then
                mv -- "${temporary}" "${destination}"
                temporary=
                log "saved ${archive}: $(human_size "${bytes}") (${bytes} bytes), sha256 ${actual}"
                log "response HTTP ${http_code}, ${elapsed}s at $(human_size "${speed}")/s, ${content_type:-unknown type}, ${effective_url}"
                downloaded=1
                break
            fi
            log "checksum mismatch from ${effective_url}: expected ${sha}, got ${actual}; trying next source"
        else
            status=$?
            log "source failed with curl status ${status}; trying next source"
        fi
        rm -f -- "${temporary}"
    done
    (( downloaded == 1 )) || die "could not download and verify ${archive} from ${#urls[@]} source(s)"
done < "${LOCK_FILE}"

log "all sources are present and verified"
