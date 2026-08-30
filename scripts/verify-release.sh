#!/usr/bin/env bash
#
# Verifies a signed Sowa release manifest and the artifacts it names.
#
# This script deliberately does not source the build system. It can be copied
# to a clean machine together with a trusted public key and used before an ISO,
# installer bundle, disk image, container archive, or rootfs tarball is opened.

set -Eeuo pipefail
export LC_ALL=C

PROGRAM="${0##*/}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'usage: %s [--key PUBLIC_KEY] MANIFEST [ARTIFACT ...]\n\n' "${PROGRAM}"
    printf 'Verify MANIFEST.sig, then verify every named artifact. If one or\n'
    printf 'more ARTIFACT paths are given, verify only that downloaded subset.\n'
    exit "${1:-1}"
}

key="${SOWA_RELEASE_PUBLIC_KEY:-${SCRIPT_ROOT}/keys/sowa-release.pub}"
while (($# > 0)); do
    case "$1" in
        --key)
            (($# >= 2)) || usage
            key="$2"
            shift 2
            ;;
        -h | --help) usage 0 ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
    esac
done

if (($# == 0)); then
    shopt -s nullglob
    defaults=("${SCRIPT_ROOT}"/artifacts/*-release.manifest)
    shopt -u nullglob
    ((${#defaults[@]} == 1)) \
        || die "name one release manifest (found ${#defaults[@]} below ${SCRIPT_ROOT}/artifacts)"
    manifest="${defaults[0]}"
else
    manifest="$1"
    shift
fi
signature="${manifest}.sig"

command -v openssl > /dev/null 2>&1 || die "openssl is required"
command -v sha256sum > /dev/null 2>&1 || die "sha256sum is required"
[[ -f "${key}" && ! -L "${key}" ]] \
    || die "the release public key is not a regular file: ${key}"
[[ -f "${manifest}" && ! -L "${manifest}" ]] \
    || die "the release manifest is not a regular file: ${manifest}"
[[ -f "${signature}" && ! -L "${signature}" ]] \
    || die "the release signature is not a regular file: ${signature}"

# Authenticate the bytes before treating any name or size inside them as data.
openssl pkeyutl -verify -rawin -pubin -inkey "${key}" \
    -in "${manifest}" -sigfile "${signature}" > /dev/null 2>&1 \
    || die "the release manifest is not signed by ${key}"

declare -A metadata=() metadata_seen=() checksums=() sizes=()
declare -a manifest_names=()
readonly -a METADATA_ORDER=(distro version arch source dirty created key-sha256)
line_number=0
body_started=0
previous_name=""
metadata_index=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    [[ "${line}" != *[$'\001'-$'\037'$'\177']* ]] \
        || die "${manifest}:${line_number}: control character"
    if ((line_number == 1)); then
        [[ "${line}" == '# sowa-release-manifest|1' ]] \
            || die "${manifest}: unsupported release manifest format"
        continue
    fi
    if [[ "${line}" == '# '* ]]; then
        ((body_started == 0)) \
            || die "${manifest}:${line_number}: metadata appears after artifacts"
        field="${line#'# '}"
        [[ "${field}" == *'|'* && "${field#*|}" != *'|'* ]] \
            || die "${manifest}:${line_number}: malformed metadata"
        name="${field%%|*}"
        value="${field#*|}"
        case "${name}" in
            distro | version | arch | source | dirty | created | key-sha256) ;;
            *) die "${manifest}:${line_number}: unknown metadata field ${name}" ;;
        esac
        [[ "${name}" == "${METADATA_ORDER[${metadata_index}]:-}" ]] \
            || die "${manifest}:${line_number}: metadata is not in canonical order"
        [[ -z "${metadata_seen[${name}]:-}" ]] \
            || die "${manifest}:${line_number}: repeated metadata field ${name}"
        metadata_seen["${name}"]=1
        metadata["${name}"]="${value}"
        metadata_index=$((metadata_index + 1))
        continue
    fi

    body_started=1
    [[ "${line}" =~ ^([0-9a-f]{64})\|([1-9][0-9]{0,18})\|([A-Za-z0-9][A-Za-z0-9._+-]{0,254})$ ]] \
        || die "${manifest}:${line_number}: malformed artifact entry"
    checksum="${BASH_REMATCH[1]}"
    size="${BASH_REMATCH[2]}"
    name="${BASH_REMATCH[3]}"
    [[ -z "${checksums[${name}]:-}" ]] \
        || die "${manifest}:${line_number}: artifact appears twice: ${name}"
    [[ -z "${previous_name}" || "${previous_name}" < "${name}" ]] \
        || die "${manifest}:${line_number}: artifact entries are not in canonical order"
    checksums["${name}"]="${checksum}"
    sizes["${name}"]="${size}"
    manifest_names+=("${name}")
    previous_name="${name}"
done < "${manifest}"

for name in distro version arch source dirty created key-sha256; do
    [[ -n "${metadata[${name}]:-}" ]] \
        || die "${manifest}: missing metadata field ${name}"
done
[[ "${metadata[distro]}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ \
    && "${metadata[version]}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ \
    && "${metadata[arch]}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] \
    || die "${manifest}: invalid release identity metadata"
[[ "${metadata[source]}" =~ ^[0-9a-f]{7,64}$ ]] \
    || die "${manifest}: invalid source revision"
[[ "${metadata[dirty]}" == 0 || "${metadata[dirty]}" == 1 ]] \
    || die "${manifest}: invalid dirty-tree marker"
[[ "${metadata[created]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || die "${manifest}: invalid creation time"
[[ "${metadata[key-sha256]}" =~ ^[0-9a-f]{64}$ ]] \
    || die "${manifest}: invalid key fingerprint"
((${#manifest_names[@]} > 0)) || die "${manifest}: no artifacts"

fingerprint="$(openssl pkey -pubin -in "${key}" -outform DER 2> /dev/null \
    | sha256sum | cut -d' ' -f1)"
[[ "${fingerprint}" == "${metadata[key-sha256]}" ]] \
    || die "the trusted key fingerprint does not match the signed manifest"

manifest_directory="$(cd "$(dirname -- "${manifest}")" && pwd -P)"
declare -a names_to_verify=()
declare -A selected_paths=() selected=()
if (($# == 0)); then
    names_to_verify=("${manifest_names[@]}")
    for name in "${names_to_verify[@]}"; do
        selected_paths["${name}"]="${manifest_directory}/${name}"
    done
else
    for path in "$@"; do
        name="${path##*/}"
        [[ -n "${checksums[${name}]:-}" ]] \
            || die "${name} is not listed in ${manifest}"
        if [[ "${path}" == */* ]]; then
            parent="$(cd "$(dirname -- "${path}")" 2> /dev/null && pwd -P)" \
                || die "cannot resolve the directory containing ${path}"
            [[ "${parent}" == "${manifest_directory}" ]] \
                || die "${path} is not beside ${manifest}"
            path="${parent}/${name}"
        else
            path="${manifest_directory}/${name}"
        fi
        [[ -z "${selected[${name}]:-}" ]] \
            || die "artifact selected twice: ${name}"
        selected["${name}"]=1
        selected_paths["${name}"]="${path}"
        names_to_verify+=("${name}")
    done
fi

for name in "${names_to_verify[@]}"; do
    path="${selected_paths[${name}]}"
    [[ -f "${path}" && ! -L "${path}" ]] \
        || die "artifact is not a regular file: ${path}"
    actual_size="$(stat -c %s -- "${path}")"
    [[ "${actual_size}" == "${sizes[${name}]}" ]] \
        || die "size mismatch for ${name}: expected ${sizes[${name}]}, got ${actual_size}"
    actual_checksum="$(sha256sum -- "${path}" | cut -d' ' -f1)"
    [[ "${actual_checksum}" == "${checksums[${name}]}" ]] \
        || die "SHA-256 mismatch for ${name}"
done

printf 'verified %d artifact(s) for %s %s (%s), source %s%s\n' \
    "${#names_to_verify[@]}" "${metadata[distro]}" "${metadata[version]}" \
    "${metadata[arch]}" "${metadata[source]}" \
    "$([[ "${metadata[dirty]}" == 1 ]] && printf ' [dirty build]')"
