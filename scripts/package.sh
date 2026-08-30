#!/usr/bin/env bash
#
# Builds the binary packages that make up a Sowa release and the signed index
# that describes them.
#
# Packages are cut out of the assembled root filesystem rather than built
# separately: scripts/stages/image/10-rootfs.sh has already decided which
# package owns each path, so what is published is byte for byte what the image
# ships. The optional packages are the exception the repository exists for -
# they are cut out of their own staging trees, because the image never carried
# them.

set -Eeuo pipefail
# Every package is built inside a command substitution, and bash does not carry
# errexit into one unless it is asked to: without this, a tar or an xz that
# failed halfway through a package would be reported by nothing but the archive
# that came out wrong, since the substitution's status is that of the last
# command in it. That is how a truncated symbolic link once got into a package.
shopt -s inherit_errexit
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/archive.sh
source "$(dirname "$0")/lib/archive.sh"

require_command tar
require_command xz
require_command sha256sum
require_command openssl

readonly META_DIR="${PACKAGE_DIR}/.meta"
# Paths a boot image adds after ownership has been assigned. /init is a property
# of the recovery image - a cpio of the whole tree, which the kernel enters at
# /init - rather than of any package. The live medium has no such file: its
# /init is liveinit, inside the initramfs, and the image stage deletes any left
# behind before building the squashfs.
readonly UNOWNED_IMAGE_PATHS="init"

claim_terminal_title packages
require_keyed_stage_state
# Before the checks below, all of which ask for many stage keys through command
# substitutions. See preheat_stage_digests: without this, each of those forks
# recomputes the whole toolchain digest from cold.
preheat_stage_digests

# Every stage's stamp holds the key it was built under. A stamp whose key no
# longer matches what its inputs say means the tree this repository would be cut
# from is not the tree the current sources describe - a bumped lock row, an
# edited recipe, a new patch - and the package writer takes its versions from
# those current sources. That is how a release could once carry a security
# version bump in its metadata without the fixed binary being in it, so the
# release stops here instead.
stale_stages() {
    local stamp name script

    # Every stamp in every stage group. STAMP_DIR itself holds only the group
    # directories - toolchain, host, packages, image - so a glob that did not
    # descend into them matched nothing, and this check passed by examining no
    # stages at all. The package a stage builds comes from the one parser that
    # answers that question; the local one here could not match a stage name,
    # because a stage name contains a "/" and its character class did not, so
    # every component stage was keyed as though it produced no package.
    while IFS= read -r stamp; do
        name="${stamp#"${STAMP_DIR}/"}"
        name="${name%.done}"
        script="${PROJECT_ROOT}/scripts/stages/${name}.sh"
        [[ -f "${script}" ]] || continue
        stage_up_to_date "${name}" "${script}" \
            "$(stage_package_name "${name}")" \
            || printf '%s\n' "${name}"
    done < <(find "${STAMP_DIR}" -name '*.done' | LC_ALL=C sort)
}

# Collected rather than piped into head: stale_stages recomputes a key per
# stamp and would be killed by SIGPIPE partway through, which under pipefail
# ends this script with status 141 and nothing said.
log "checking that every stage is as new as its inputs"
mapfile -t stale_stage_names < <(stale_stages)
if ((${#stale_stage_names[@]} > 0)); then
    stale_tail=""
    ((${#stale_stage_names[@]} <= 5)) || stale_tail=" and more"
    die "${#stale_stage_names[@]} stage(s) are older than their inputs (${stale_stage_names[*]:0:5}${stale_tail}); rebuild before packaging"
fi

[[ -d "${ROOTFS_DIR}" && -n "$(ls -A "${ROOTFS_DIR}")" ]] \
    || die "no root filesystem; run 'make image' first"
[[ -f "${PKG_META_DIR}/rootfs.manifest" ]] \
    || die "no package manifests; run 'make rootfs' first"
[[ -f "${STAMP_DIR}/image/10-rootfs.done" && -f "${STAMP_DIR}/image/11-initramfs.done" ]] \
    || die "the image is not complete; run 'make image' first"
[[ ! "${STAMP_DIR}/image/10-rootfs.done" -nt "${STAMP_DIR}/image/11-initramfs.done" ]] \
    || die "the root filesystem was assembled after the image; run 'make image' first"
[[ -s "${PKG_META_DIR}/linux.files" ]] \
    || die "the kernel has not been packaged; run 'make image' first"
while IFS= read -r package; do
    pkg_staged "${package}" \
        || die "the optional package ${package} has not been built; run 'make ${package}' first"
    [[ -s "${PKG_META_DIR}/${package}.files" ]] \
        || die "${package} has no manifest; run 'make rootfs' again"
done < <(optional_package_names)

# A package's build id is what tells an installed machine that bytes it already
# has were built again. It is computed twice for everything the image ships:
# once by image/10-rootfs, into the database the image carries, and once here,
# into the index. The two have to agree, or every fresh installation opens by
# offering to reinstall packages it received minutes earlier - which is what
# happened while image/10-rootfs described sowa-base and sowa-release out of a
# source record it had not finished writing. Nothing downstream can notice the
# disagreement: both sides look internally consistent, and the client is right
# to believe them.

# Every package's build identity, worked out once.
#
# It is asked for three times per package - to check the image agrees with it,
# to name the archive, and to write the index - and all three answers are the
# same. Computing it once is worth doing on its own; it also gives the run one
# place to say what it is doing, because on a tree with nothing to rebuild this
# is the only part of "make packages" that takes any time at all.
declare -A BUILD_ID=()
load_build_ids() {
    local package count=0
    while IFS= read -r package; do
        count=$((count + 1))
        show_progress "[${count}/${total}] build id ${package}"
        BUILD_ID["${package}"]="$(pkg_build_id "${package}" \
            "${PKG_META_DIR}/${package}.files")"
    done < <(package_names)
}

total="$(package_names | wc -l)"
optional="$(optional_package_names | wc -l)"
log "working out the build identity of ${total} packages"
load_build_ids

log "checking that the image and the repository agree on every build id"
while IFS= read -r package; do
    installed="$(sed -n 's/^pkgbuild=//p' \
        "${ROOTFS_DIR}/var/lib/sowa/db/${package}/desc" 2> /dev/null)"
    [[ -n "${installed}" ]] \
        || die "${package} has no build id in the image database; run 'make image' first"
    computed="${BUILD_ID[${package}]}"
    [[ "${installed}" == "${computed}" ]] \
        || die "${package} is ${computed} here and ${installed} in the image; the image would ask to reinstall it on first update"
done < <(image_package_names)

# Every path the image carries has to belong to exactly one package, or an
# installed system could never be brought up to date as a whole. The manifests
# are compared against the tree they were cut from instead of being trusted.
manifest_path_set() {
    awk -F'|' '{ print $5 }' "$@" | sort -u
}

verify_ownership() {
    local union="${PKG_META_DIR}/.union"
    local everything="${PKG_META_DIR}/.everything"
    local claimed="${PKG_META_DIR}/.claimed"
    local present="${PKG_META_DIR}/.present"
    local name unowned duplicated missing

    : > "${union}"
    while IFS= read -r name; do
        [[ -f "${PKG_META_DIR}/${name}.files" ]] \
            || die "package ${name} has no manifest; run 'make rootfs' again"
        cat "${PKG_META_DIR}/${name}.files" >> "${union}"
    done < <(image_package_names)

    # The optional packages are not in the image and so take no part in the
    # comparison against it, but no two packages may hand an installed system
    # the same file whichever side they are on.
    cp "${union}" "${everything}"
    while IFS= read -r name; do
        cat "${PKG_META_DIR}/${name}.files" >> "${everything}"
    done < <(optional_package_names)

    # Directories are shared by nature - /usr/bin belongs to everything that
    # installs a program - so only the files and links have a single owner.
    duplicated="$(awk -F'|' '$1 != "d" { print $5 }' "${everything}" \
        | sort | uniq -d | head -n 5)"
    [[ -z "${duplicated}" ]] \
        || die "these paths are claimed by more than one package: ${duplicated}"

    # The kernel joins the tree after ownership has been assigned, so the image
    # it was assigned from is the root filesystem plus the kernel package.
    manifest_path_set "${union}" > "${claimed}"
    manifest_path_set "${PKG_META_DIR}/rootfs.manifest" \
        "${PKG_META_DIR}/linux.files" > "${present}"

    unowned="$(comm -23 "${present}" "${claimed}" \
        | awk -v skip="${UNOWNED_IMAGE_PATHS}" '$0 != skip' | head -n 5)"
    [[ -z "${unowned}" ]] || die "no package owns: ${unowned}"

    missing="$(comm -13 "${present}" "${claimed}" | head -n 5)"
    [[ -z "${missing}" ]] \
        || die "packages claim paths the image does not have: ${missing}"

    rm -f "${union}" "${everything}" "${claimed}" "${present}"
}

# No archive leaves here without the terms it may be redistributed under. The
# manifest is what is checked rather than the tree, because the manifest is
# what the archive is cut from: a licence directory that exists but is not
# claimed would be a licence the package does not actually carry.
verify_licenses() {
    local name directory
    while IFS= read -r name; do
        directory="$(license_directory "${name}")"
        awk -F'|' -v prefix="${directory}/" '
            $1 == "f" && index($5, prefix) == 1 { found = 1 }
            END { exit !found }
        ' "${PKG_META_DIR}/${name}.files" \
            || die "${name} owns no file below /${directory}; it may not be published"
    done < <(package_names)
}

# Normalized tar options: a package built twice from the same tree has to be the
# same package. GNU tar's default extended-header name carries the writer's PID,
# which would otherwise change on every run.
tar_options() {
    printf '%s\n' \
        --format=pax \
        --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
        --owner=0 --group=0 --numeric-owner \
        --mtime=@"${SOURCE_DATE_EPOCH}" \
        --no-recursion
}

build_package() {
    local name="$1"
    local manifest="${PKG_META_DIR}/${name}.files"
    local metadata="${META_DIR}/${name}"
    local temporary="${PACKAGE_DIR}/.${name}.tar"
    local archive content message hooks build
    local -a options members=(.PKGINFO .FILES)
    build="$(pkg_build_id "${name}" "${manifest}")"
    archive="${PACKAGE_DIR}/$(release_package_archive_name "${name}" "${build}")"
    # An image package is cut out of the image; an optional one never entered it
    # and is cut out of the tree its stage installed instead.
    content="${ROOTFS_DIR}"
    if package_is_optional "${name}"; then
        content="${PKG_STAGE_DIR}/${name}"
    fi

    [[ -s "${manifest}" ]] || die "package ${name} owns no files"
    mapfile -t options < <(tar_options)

    rm -rf "${metadata}"
    mkdir -p "${metadata}"
    pkg_write_info "${name}" "${manifest}" "${metadata}/.PKGINFO"
    cp "${manifest}" "${metadata}/.FILES"
    # .MESSAGE is metadata rather than a file the package owns: it is not in
    # .FILES, nothing is written to the installed system for it, and a package
    # without one is carried exactly as before.
    message="$(package_message_file "${name}")"
    if [[ -f "${message}" ]]; then
        cp "${message}" "${metadata}/.MESSAGE"
        members+=(.MESSAGE)
    fi
    # .HOOKS is metadata for the same reasons, and is checked against this
    # package's own manifest before it is carried: a "setup" naming a path the
    # package does not own is refused by the client, so it is refused here.
    hooks="$(package_hooks_file "${name}")"
    if [[ -f "${hooks}" ]]; then
        pkg_check_hooks "${name}" "${manifest}"
        cp "${hooks}" "${metadata}/.HOOKS"
        members+=(.HOOKS)
    fi

    rm -f "${temporary}" "${temporary}.content"
    tar --create --file="${temporary}" --directory="${metadata}" \
        "${options[@]}" "${members[@]}"
    pkg_manifest_paths "${manifest}" \
        | tr '\n' '\0' \
        | tar --create --file="${temporary}.content" --directory="${content}" \
            "${options[@]}" --null --files-from=-
    # The content is built as an archive of its own and joined on rather than
    # appended to the metadata directly, because "tar --append" writes the
    # members it adds in the format it finds in the archive instead of the one
    # asked for here: a symbolic link whose target is longer than the 100
    # characters a ustar header holds is then written *truncated*, with a
    # warning and a non-zero exit that a previous version of this script did not
    # notice. Guix is where that surfaced - a store path is around 60 characters
    # before anything is appended to it - but nothing guarantees it is the only
    # package that could ever hit it. --concatenate copies whole members,
    # extended headers and all, so both archives keep the format they were
    # written in.
    tar --concatenate --file="${temporary}" "${temporary}.content"
    rm -f "${temporary}.content"
    xz_compress_default < "${temporary}" > "${archive}.tmp"
    mv "${archive}.tmp" "${archive}"
    rm -f "${temporary}"
    printf '%s\n' "${archive}"
}

# The two numbers that let an installed system tell this index from an older
# copy of one somebody kept: a serial that never goes backwards, and the moment
# after which this index is not to be believed at all. Both are in the signed
# bytes, and both are comments, so a client that predates them reads the index
# exactly as before. See check_index_freshness in sowa-pkg.
index_freshness_header() {
    local serial expires

    serial="${REPO_INDEX_SERIAL:-$(date -u +%s)}"
    [[ "${serial}" =~ ^[1-9][0-9]{0,17}$ ]] \
        || die "REPO_INDEX_SERIAL must be a positive count of seconds since the epoch"
    [[ "${REPO_INDEX_VALIDITY_DAYS}" =~ ^[1-9][0-9]{0,4}$ ]] \
        || die "REPO_INDEX_VALIDITY_DAYS must be a positive number of days"
    expires=$((serial + REPO_INDEX_VALIDITY_DAYS * 86400))
    printf '# sowa-repo serial=%s expires=%s published=%s valid-until=%s\n' \
        "${serial}" "${expires}" \
        "$(date -u -d "@${serial}" '+%Y-%m-%dT%H:%M:%SZ')" \
        "$(date -u -d "@${expires}" '+%Y-%m-%dT%H:%M:%SZ')"
}

write_index() {
    local index="${PACKAGE_DIR}/index"
    local name archive checksum size build

    {
        printf '# Sowa %s binary package repository for %s\n' \
            "${DISTRO_VERSION}" "${PKG_ARCH}"
        index_freshness_header
        # The reproducible build epoch the archives were stamped with, which is
        # a property of the build rather than of this publication; the line
        # above is when the index was written.
        printf '# built %s\n' "$(package_build_date)"
        # The licence is in the index as well as in every archive, so that
        # "sowa-license list --available" and "sowa-pkg info" can answer for a
        # package this machine has never installed. The description stays last,
        # because it is the one free-text field.
        # pkgbuild is what makes a rebuild visible to a machine that already
        # has the package at this version: the client compares it as well as the
        # version, and reinstalls when it differs. See pkg_build_id.
        # pkgbuild sits immediately before the free-text description. Older
        # clients assign all remaining fields to their final description
        # variable, so they continue to parse dependencies and licences while a
        # new sowa-release package bootstraps the build-aware client.
        printf '# name|version|arch|archive|sha256|size|depends|license|copyright|pkgbuild|description\n'
        while IFS= read -r name; do
            build="${BUILD_ID[${name}]}"
            archive="$(release_package_archive_name "${name}" "${build}")"
            read -r checksum _ < <(sha256sum "${PACKAGE_DIR}/${archive}")
            size="$(stat -c '%s' "${PACKAGE_DIR}/${archive}")"
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "${name}" "$(package_version "${name}")" "${PKG_ARCH}" \
                "${archive}" "${checksum}" "${size}" \
                "$(package_depends "${name}")" "$(package_license "${name}")" \
                "$(package_copyright "${name}")" "${build}" \
                "$(package_description "${name}")"
        done < <(package_names)
    } > "${index}.tmp"
    mv "${index}.tmp" "${index}"
    printf '%s\n' "${index}"
}

# The index is the only thing that has to be trusted: every archive is pinned by
# a SHA-256 inside it. Signing it therefore covers the whole repository.
sign_index() {
    local index="$1"
    local public="${REPO_PUBLIC_KEY}"

    if [[ ! -f "${REPO_KEY}" ]]; then
        log "warning: no repository key at ${REPO_KEY}; the index is unsigned"
        log "warning: run 'make repo-key' and rebuild the image before publishing"
        rm -f "${index}.sig"
        return 0
    fi
    openssl pkeyutl -sign -rawin -inkey "${REPO_KEY}" \
        -in "${index}" -out "${index}.sig"
    [[ -f "${public}" ]] \
        || die "the image carries no public key; run 'make repo-key' and rebuild"
    openssl pkeyutl -verify -rawin -pubin -inkey "${public}" \
        -in "${index}" -sigfile "${index}.sig" > /dev/null \
        || die "the index signature does not verify against the key in the image"
    log "signed the index with ${REPO_KEY}"
}

# Compressing a few hundred megabytes takes long enough that a silent start
# looks like a hang, so say what is about to happen, and announce each package
# before compressing it rather than after.
log "${DISTRO_NAME} ${DISTRO_VERSION} binary packages for ${PKG_ARCH}"
log "cutting $((total - optional)) packages out of ${ROOTFS_DIR}, and ${optional} the image does not ship out of ${PKG_STAGE_DIR}"
log "$(wc -l < "${PKG_META_DIR}/rootfs.manifest") paths, $(du -sh "${ROOTFS_DIR}" | cut -f1) uncompressed, into ${PACKAGE_DIR}"
log "each package is compressed with XZ defaults; no preset level is forced"

log "checking that every path in the image belongs to exactly one package"
verify_ownership
log "checking that every package carries its licence"
verify_licenses

# Archive names carry the package's complete build identity and are written by
# rename, so an existing current name is a completed package that can be reused
# after an interrupted or repeated run. The index and its signature still have
# to be regenerated from the complete current set.
rm -rf "${META_DIR}"
rm -f "${PACKAGE_DIR}"/index "${PACKAGE_DIR}"/index.sig
mkdir -p "${META_DIR}"
count=0
built=0
reused=0
declare -A current_archives=()
while IFS= read -r package; do
    count=$((count + 1))
    version="$(package_version "${package}")"
    build="${BUILD_ID[${package}]}"
    archive="${PACKAGE_DIR}/$(release_package_archive_name "${package}" "${build}")"
    current_archives["${archive##*/}"]=1
    show_progress "[${count}/${total}] ${package} ${version}"
    # Printed without a newline and completed once the archive exists, so the
    # line appears when the work starts and gains its size when it finishes.
    printf '==> [%2d/%d] %-18s %-14s ' "${count}" "${total}" "${package}" "${version}"
    if [[ -f "${archive}" ]]; then
        printf '%s (already exists, skipped)\n' "$(du -h "${archive}" | cut -f1)"
        reused=$((reused + 1))
        continue
    fi
    archive="$(build_package "${package}")"
    built=$((built + 1))
    printf '%s\n' "$(du -h "${archive}" | cut -f1)"
done < <(package_names)

# Keep PACKAGE_DIR a repository of the current release rather than allowing
# archives from older package versions or build identities to accumulate. This
# happens only after every current archive exists, so a failed run remains
# resumable from everything it completed.
for archive in "${PACKAGE_DIR}"/*.tar.gz "${PACKAGE_DIR}"/*.tar.xz; do
    [[ -f "${archive}" ]] || continue
    [[ -n "${current_archives[${archive##*/}]:-}" ]] || rm -f "${archive}"
done

show_progress "index"
index="$(write_index)"
sign_index "${index}"

log "built ${built} packages and reused ${reused}, $(du -sh "${PACKAGE_DIR}" | cut -f1) in ${PACKAGE_DIR}"
log "publish them with: make publish-repo"
