#!/usr/bin/env bash
#
# Assembles the binary package repository under DIST_DIR, ready to be served
# over HTTPS.
#
# The repository is a plain directory of files. A client fetches
#
#   ${SOWA_REPO_URL}/index
#   ${SOWA_REPO_URL}/index.sig
#   ${SOWA_REPO_URL}/sowa-<name>-<version>-<arch>-<pkgbuild>.tar.xz
#
# so what this produces is exactly what a web server has to expose, with no
# server-side software of any kind. Whatever URL it is served at belongs in
# /etc/sowa/pkg.conf on the installed systems, which is the only place the
# client reads it from.
#
# Two orderings matter and are deliberate:
#
#   * archives are written before the index, so a client that fetches the index
#     mid-publish can never see it reference an archive that is not there yet
#   * every file is written to a temporary name and renamed into place, so a
#     server reading the directory never sees a half-written file

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

readonly INDEX="${PACKAGE_DIR}/index"
readonly TARGET="${DIST_DIR}/${PKG_ARCH}"

allow_unsigned=0
keep_old=0
while (($# > 0)); do
    case "$1" in
        --allow-unsigned) allow_unsigned=1 ;;
        --keep-old) keep_old=1 ;;
        *) die "usage: $0 [--allow-unsigned] [--keep-old]" ;;
    esac
    shift
done

[[ -f "${INDEX}" ]] || die "no index; run 'make packages' first"
if [[ ! -f "${INDEX}.sig" ]]; then
    if [[ "${allow_unsigned}" != 1 ]]; then
        die "the index is unsigned; run 'make repo-key' and 'make packages', or pass --allow-unsigned to stage it anyway"
    fi
    log "warning: publishing an UNSIGNED index"
    log "warning: a client with SOWA_REQUIRE_SIGNATURE=1 - the default - will refuse it"
    log "warning: self-hosting puts the whole trust of an update on this signature"
fi

# The index is the work list: nothing outside it is published, and everything in
# it has to exist.
declare -A published=()
assets=()
while IFS='|' read -r name _version _arch archive _rest; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    [[ -f "${PACKAGE_DIR}/${archive}" ]] \
        || die "the index lists ${archive}, which is not in ${PACKAGE_DIR}"
    assets+=("${archive}")
    published["${archive}"]=1
done < "${INDEX}"
((${#assets[@]} > 0)) || die "the index describes no packages"

# The serial inside the signed index, or nothing if this index predates the
# header. See index_freshness_header in package.sh.
index_serial() {
    local file="$1"
    local line field key value serial=""
    local -a fields=()

    [[ -f "${file}" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" == \#* || -z "${line}" ]] || break
        [[ "${line}" == '# sowa-repo '* ]] || continue
        read -r -a fields <<< "${line#'# sowa-repo '}"
        for field in "${fields[@]}"; do
            key="${field%%=*}"
            value="${field#*=}"
            [[ "${key}" == serial ]] || continue
            serial="${value}"
        done
        break
    done < "${file}"
    [[ "${serial}" =~ ^[1-9][0-9]{0,17}$ ]] || return 1
    printf '%s\n' "${serial}"
}

install_file() {
    local source="$1"
    local destination="$2"
    local temporary="${destination}.tmp.$$"
    cp "${source}" "${temporary}"
    chmod 0644 "${temporary}"
    mv "${temporary}" "${destination}"
}

claim_terminal_title publish
mkdir -p "${TARGET}"

copied=0
unchanged=0
# What the machines reading this repository currently believe each package is.
# The build id is part of every archive name, so an existing name is immutable:
# different bytes there mean either a broken build identity or a reproducibility
# defect and publication stops instead of changing what a signed old index
# means. A new build at the same human version gets a new name and remains
# visible to both caches and clients.
declare -A previous_build=()
if [[ -f "${TARGET}/index" ]]; then
    while IFS='|' read -r name _version _arch _archive _sha _size _depends \
        _license _copyright build _rest; do
        [[ -z "${name}" || "${name}" == \#* ]] && continue
        [[ "${build}" =~ ^[0-9a-f]{64}$ ]] || build=""
        previous_build["${name}"]="${build}"
    done < "${TARGET}/index"
fi

# Publishing an index whose serial is behind the one already being served is
# what a rollback looks like from the client's side, and clients refuse it: they
# keep the highest serial they have accepted and will not go back to a lower
# one. Catching it here means finding out at the moment of publication rather
# than from a machine that has stopped updating.
new_serial="$(index_serial "${INDEX}")" \
    || die "the index carries no serial; rebuild it with 'make packages'"
if published_serial="$(index_serial "${TARGET}/index")"; then
    ((new_serial >= published_serial)) \
        || die "this index is older than the one already published (serial ${new_serial} against ${published_serial}); rebuild it, or set REPO_INDEX_SERIAL if this is deliberate"
fi

rebuilt=0
for archive in "${assets[@]}"; do
    show_progress "${archive}"
    if [[ -f "${TARGET}/${archive}" ]]; then
        if cmp -s "${PACKAGE_DIR}/${archive}" "${TARGET}/${archive}"; then
            unchanged=$((unchanged + 1))
            continue
        fi
        die "refusing to replace immutable archive ${archive}; its build id names different bytes"
    fi
    install_file "${PACKAGE_DIR}/${archive}" "${TARGET}/${archive}"
    copied=$((copied + 1))
done

while IFS='|' read -r name version _arch _archive _sha _size _depends \
    _license _copyright build _rest; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    was="${previous_build[${name}]:-}"
    if [[ -n "${was}" && "${was}" != "${build}" ]]; then
        log "${name} ${version} is a new build (${was:0:12} -> ${build:0:12})"
        rebuilt=$((rebuilt + 1))
    fi
done < "${INDEX}"

removed=0
if [[ "${keep_old}" != 1 ]]; then
    # Include the old gzip suffix so the first XZ publication withdraws legacy
    # archives too. --keep-old retains both formats when a transition mirror
    # deliberately wants them.
    for path in "${TARGET}"/*.tar.xz "${TARGET}"/*.tar.gz; do
        [[ -f "${path}" ]] || continue
        name="${path##*/}"
        if [[ -z "${published[${name}]:-}" ]]; then
            log "withdrawing ${name}"
            rm -f "${path}"
            removed=$((removed + 1))
        fi
    done
fi

# Last, so the index never promises an archive that has not landed yet.
install_file "${INDEX}" "${TARGET}/index"
if [[ -f "${INDEX}.sig" ]]; then
    install_file "${INDEX}.sig" "${TARGET}/index.sig"
else
    rm -f "${TARGET}/index.sig"
fi

log "published ${#assets[@]} packages to ${TARGET}"
log "index serial ${new_serial}, $(sed -n 's/^# sowa-repo .*valid-until=\([^ ]*\).*/valid until \1/p' "${INDEX}" | head -1)"
log "${copied} written, ${unchanged} already current, ${removed} withdrawn"
if ((rebuilt > 0)); then
    log "${rebuilt} package(s) have a new build id; installed systems will take them"
fi
log "total $(du -sh "${TARGET}" | cut -f1)"
log ""
log "serve that directory over HTTPS and point the installed systems at it by"
log "setting SOWA_REPO_URL in /etc/sowa/pkg.conf, for example:"
log "  SOWA_REPO_URL=\"https://packages.example.org/sowa/${PKG_ARCH}\""
