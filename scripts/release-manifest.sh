#!/usr/bin/env bash
#
# Signs the release artifacts already present in ARTIFACT_DIR.
#
# Adjacent .sha256 files detect a damaged copy but authenticate nothing: anyone
# able to replace an image can replace the checksum beside it. This manifest is
# the authority. Its Ed25519 signature covers the release identity, source
# revision, public-key fingerprint, and the exact name, size and SHA-256 of
# every current release artifact in the directory.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_command openssl
require_command sha256sum
require_command stat

readonly RELEASE_PRIVATE_KEY="${RELEASE_KEY:-${HOME}/.config/sowa/release-ed25519.key}"
readonly RELEASE_PUBLIC="${RELEASE_PUBLIC_KEY:-${PROJECT_ROOT}/keys/sowa-release.pub}"
readonly RELEASE_BASENAME="${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}-release.manifest"
readonly RELEASE_MANIFEST="${ARTIFACT_DIR}/${RELEASE_BASENAME}"
readonly RELEASE_SIGNATURE="${RELEASE_MANIFEST}.sig"

allow_dirty="${RELEASE_ALLOW_DIRTY:-0}"
case "${1:-}" in
    '') ;;
    --allow-dirty) allow_dirty=1 ;;
    *) die "usage: $0 [--allow-dirty]" ;;
esac
[[ "${allow_dirty}" == 0 || "${allow_dirty}" == 1 ]] \
    || die "RELEASE_ALLOW_DIRTY must be 0 or 1"

for value in "${DISTRO_NAME}" "${DISTRO_VERSION}" "${ARTIFACT_ARCH}"; do
    [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] \
        || die "release identity contains a character the manifest cannot represent: ${value}"
done

[[ -f "${RELEASE_PRIVATE_KEY}" && ! -L "${RELEASE_PRIVATE_KEY}" ]] \
    || die "no regular release private key at ${RELEASE_PRIVATE_KEY}; run 'make release-key'"
[[ -f "${RELEASE_PUBLIC}" && ! -L "${RELEASE_PUBLIC}" ]] \
    || die "no regular release public key at ${RELEASE_PUBLIC}; run 'make release-key'"
private_mode="$(stat -c %a "${RELEASE_PRIVATE_KEY}")"
(( (8#${private_mode} & 8#077) == 0 )) \
    || die "the release private key is accessible to group or other (mode ${private_mode})"

derived_public="$(mktemp "${TMPDIR:-/tmp}/sowa-release-public.XXXXXX")"
trap 'rm -f "${derived_public}"' EXIT
openssl pkey -in "${RELEASE_PRIVATE_KEY}" -pubout -out "${derived_public}"
cmp -s "${derived_public}" "${RELEASE_PUBLIC}" \
    || die "${RELEASE_PUBLIC} does not belong to ${RELEASE_PRIVATE_KEY}"
rm -f "${derived_public}"
trap - EXIT

revision="${RELEASE_SOURCE_REVISION:-}"
dirty=0
if command -v git > /dev/null 2>&1 \
    && git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    # A checkout has one authoritative revision. An override is for an exported
    # source tree with no .git, not a way to label this checkout as another one.
    revision="$(git -C "${PROJECT_ROOT}" rev-parse HEAD)"
    if [[ -n "$(git -C "${PROJECT_ROOT}" status --porcelain)" ]]; then
        dirty=1
    fi
elif [[ -z "${revision}" ]]; then
    die "cannot identify the release source; set RELEASE_SOURCE_REVISION for an exported tree"
fi
[[ "${revision}" =~ ^[0-9a-f]{7,64}$ ]] \
    || die "the release source revision must be 7 to 64 lowercase hexadecimal characters"
if ((dirty == 1 && allow_dirty == 0)); then
    die "the source tree is dirty; commit it before signing, or use --allow-dirty for a non-release test"
fi

is_release_artifact() {
    local name="$1"
    case "${name}" in
        "${RELEASE_BASENAME}" | "${RELEASE_BASENAME}.sig" | *.sha256)
            return 1
            ;;
        sowa-install)
            return 0
            ;;
        "${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}"*)
            [[ "${name}" != *.tmp && "${name}" != *.tmp.* ]]
            ;;
        vmlinuz-*-"${ARTIFACT_ARCH}" | kernel-*-"${ARTIFACT_ARCH}.config")
            return 0
            ;;
        *) return 1 ;;
    esac
}

declare -a artifacts=()
shopt -s nullglob
for path in "${ARTIFACT_DIR}"/*; do
    name="${path##*/}"
    case "${name}" in
        "${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}"*.tmp \
            | "${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}"*.tmp.* \
            | sowa-install.tmp | sowa-install.tmp.*)
            die "an artifact is still being written: ${path}"
            ;;
    esac
    is_release_artifact "${name}" || continue
    [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,254}$ ]] \
        || die "artifact name cannot be represented safely: ${name}"
    [[ -f "${path}" && ! -L "${path}" ]] \
        || die "release artifact is not a regular file: ${path}"
    [[ -s "${path}" ]] || die "release artifact is empty: ${path}"
    artifacts+=("${path}")
done
shopt -u nullglob
((${#artifacts[@]} > 0)) \
    || die "no ${DISTRO_NAME} ${DISTRO_VERSION} release artifacts in ${ARTIFACT_DIR}"

mapfile -t artifacts < <(printf '%s\n' "${artifacts[@]}" | LC_ALL=C sort)
fingerprint="$(openssl pkey -pubin -in "${RELEASE_PUBLIC}" -outform DER \
    | sha256sum | cut -d' ' -f1)"
created="$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ')"

manifest_temporary="${RELEASE_MANIFEST}.tmp.$$"
signature_temporary="${RELEASE_SIGNATURE}.tmp.$$"
trap 'rm -f "${manifest_temporary}" "${signature_temporary}"' EXIT
{
    printf '# sowa-release-manifest|1\n'
    printf '# distro|%s\n' "${DISTRO_NAME}"
    printf '# version|%s\n' "${DISTRO_VERSION}"
    printf '# arch|%s\n' "${ARTIFACT_ARCH}"
    printf '# source|%s\n' "${revision}"
    printf '# dirty|%s\n' "${dirty}"
    printf '# created|%s\n' "${created}"
    printf '# key-sha256|%s\n' "${fingerprint}"
    for path in "${artifacts[@]}"; do
        name="${path##*/}"
        checksum="$(sha256sum -- "${path}" | cut -d' ' -f1)"
        size="$(stat -c %s -- "${path}")"
        printf '%s|%s|%s\n' "${checksum}" "${size}" "${name}"
    done
} > "${manifest_temporary}"
chmod 0644 "${manifest_temporary}"

openssl pkeyutl -sign -rawin -inkey "${RELEASE_PRIVATE_KEY}" \
    -in "${manifest_temporary}" -out "${signature_temporary}"
chmod 0644 "${signature_temporary}"
openssl pkeyutl -verify -rawin -pubin -inkey "${RELEASE_PUBLIC}" \
    -in "${manifest_temporary}" -sigfile "${signature_temporary}" \
    > /dev/null 2>&1 \
    || die "the release manifest signature does not verify against ${RELEASE_PUBLIC}"

# Both files were complete and mutually verified before either public name was
# touched. The manifest moves last: a reader seeing the new manifest can never
# see a partially written signature, and static release publication should copy
# this pair only after all artifacts have landed.
mv "${signature_temporary}" "${RELEASE_SIGNATURE}"
mv "${manifest_temporary}" "${RELEASE_MANIFEST}"
trap - EXIT

bytes=0
for path in "${artifacts[@]}"; do
    bytes=$((bytes + $(stat -c %s -- "${path}")))
done
log "signed ${#artifacts[@]} release artifact(s), $((bytes / 1048576)) MiB total"
log "manifest:  ${RELEASE_MANIFEST}"
log "signature: ${RELEASE_SIGNATURE}"
if ((dirty == 1)); then
    log "source:    ${revision} (dirty development build)"
else
    log "source:    ${revision}"
fi
log "key:       sha256:${fingerprint}"
