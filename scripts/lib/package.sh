#!/usr/bin/env bash
#
# Packaging helpers shared by the component stages, the root filesystem
# assembly, and the repository driver.
#
# The build stays a single sysroot: every stage still installs into
# ${SYSROOT} and later stages still link against it. The only change is that a
# stage installs into its own staging tree first and that tree is then merged
# into the sysroot. The staging trees are what make per-package file ownership
# knowable after the fact, so the shipped image and the published packages are
# derived from one another instead of being maintained side by side.
#
# This file is sourced from lib/common.sh and assumes its variables.

readonly NEWLINE=$'\n'

package_record() {
    local wanted="$1"
    local name source release depends profile description

    while IFS='|' read -r name source release depends profile description; do
        [[ -z "${name}" || "${name}" == \#* ]] && continue
        if [[ "${name}" == "${wanted}" ]]; then
            printf '%s|%s|%s|%s|%s|%s\n' "${name}" "${source}" "${release}" \
                "${depends}" "${profile}" "${description}"
            return 0
        fi
    done < "${PACKAGES_CONF}"

    die "package '${wanted}' is not present in ${PACKAGES_CONF}"
}

package_names() {
    local name rest
    while IFS='|' read -r name rest; do
        [[ -z "${name}" || "${name}" == \#* ]] && continue
        printf '%s\n' "${name}"
    done < "${PACKAGES_CONF}"
}

package_profile() {
    local _name _source _release _depends profile _description
    IFS='|' read -r _name _source _release _depends profile _description \
        < <(package_record "$1")
    printf '%s\n' "${profile}"
}

package_is_optional() {
    [[ "$(package_profile "$1")" == optional ]]
}

# The packages the image is made of, and the ones only the repository carries.
# Nothing but these two lists partitions config/packages.conf, so a path in the
# image is always looked for among the former and never among the latter.
image_package_names() {
    local name
    while IFS= read -r name; do
        if ! package_is_optional "${name}"; then
            printf '%s\n' "${name}"
        fi
    done < <(package_names)
}

optional_package_names() {
    local name
    while IFS= read -r name; do
        if package_is_optional "${name}"; then
            printf '%s\n' "${name}"
        fi
    done < <(package_names)
}

# A package can move from the image to the repository between builds. Component
# stages merge into SYSROOT incrementally, so files from its former image build
# would otherwise survive there and be copied into the next rootfs. The previous
# rootfs manifest records those paths. Remove only paths no current image stage
# or overlay supplies, then remove any package-specific directories left empty.
pkg_prune_optional_sysroot_residue() {
    local target_root="$1"
    local name manifest staged_manifest type mode value size path image_name removed=0
    local -a directories=()
    local -A supplied=()

    while IFS= read -r path; do
        supplied["${path}"]=1
    done < <(cd "${PROJECT_ROOT}/rootfs-overlay" && find . -mindepth 1 -printf '%P\n')
    while IFS= read -r image_name; do
        pkg_staged "${image_name}" || continue
        while IFS= read -r path; do
            supplied["${path}"]=1
        done < <(cd "${PKG_STAGE_DIR}/${image_name}" && find . -mindepth 1 -printf '%P\n')
    done < <(image_package_names)

    while IFS= read -r name; do
        staged_manifest="${PKG_META_DIR}/.${name}.prune"
        if pkg_staged "${name}"; then
            pkg_tree_manifest "${PKG_STAGE_DIR}/${name}" "${staged_manifest}"
        else
            staged_manifest=
        fi
        for manifest in "${PKG_META_DIR}/${name}.files" "${staged_manifest}"; do
            [[ -n "${manifest}" && -f "${manifest}" ]] || continue
            while IFS='|' read -r type mode value size path; do
                [[ -n "${path}" ]] || continue
                [[ -n "${supplied[${path}]:-}" ]] && continue
                if [[ "${type}" == d ]]; then
                    directories+=("${path}")
                elif [[ -e "${target_root}/${path}" || -L "${target_root}/${path}" ]]; then
                    rm -f "${target_root}/${path}"
                    ((removed += 1))
                fi
            done < "${manifest}"
        done
        [[ -z "${staged_manifest}" ]] || rm -f "${staged_manifest}"
    done < <(optional_package_names)

    if ((${#directories[@]})); then
        while IFS= read -r path; do
            rmdir "${target_root}/${path}" 2>/dev/null || true
        done < <(printf '%s\n' "${directories[@]}" | sort -r)
    fi
    (( removed == 0 )) || log "removed ${removed} stale optional-package paths from the sysroot"
}

package_depends() {
    local _name _source _release depends _profile _description
    IFS='|' read -r _name _source _release depends _profile _description \
        < <(package_record "$1")
    printf '%s\n' "${depends}"
}

package_description() {
    local _name _source _release _depends _profile description
    IFS='|' read -r _name _source _release _depends _profile description \
        < <(package_record "$1")
    printf '%s\n' "${description}"
}

# The full "upstream-release" human version. The client uses version ordering
# to describe an upgrade or downgrade and compares the machine-derived pkgbuild
# as well, so an unchanged human version no longer hides rebuilt bytes.
package_version() {
    local _name source release _depends _profile _description version
    IFS='|' read -r _name source release _depends _profile _description \
        < <(package_record "$1")
    if [[ "${source}" == - ]]; then
        version="${DISTRO_VERSION}"
    else
        version="$(source_version "${source}")"
    fi
    # A pinned git commit is a legitimate lock version but an unreadable
    # package version; the first 12 hex digits identify it unambiguously.
    if [[ "${version}" =~ ^[0-9a-f]{40}$ ]]; then
        version="${version:0:12}"
    fi
    printf '%s-%s\n' "${version}" "${release}"
}

package_archive_name() {
    local name="$1"
    local build="$2"
    [[ "${build}" =~ ^[0-9a-f]{64}$ ]] \
        || die "package ${name} has an invalid build id: ${build:-empty}"
    printf '%s-%s-%s-%s-%s.tar.gz\n' \
        "${DISTRO_NAME}" "${name}" "$(package_version "${name}")" \
        "${PKG_ARCH}" "${build}"
}

# Where a package's post-install note lives, if it has one. Most packages are
# finished by being unpacked and say nothing; the ones that are not - guix has
# to be told about the machine before there is a guix command - would otherwise
# install successfully and look broken. The file is optional by design, so this
# only names it and the caller decides whether it is there.
package_message_file() {
    printf '%s\n' "${PROJECT_ROOT}/config/messages/$1.txt"
}

# The events and actions a hook line may name. sowa-pkg implements exactly
# these and refuses anything else, so a package that asks for something outside
# the list is stopped here, at the build, rather than on the machine that
# installs it.
readonly PACKAGE_HOOK_EVENTS="post-install post-upgrade pre-remove"
readonly PACKAGE_HOOK_ACTIONS="service-start service-stop service-restart \
service-enable service-disable setup"

# Where a package's install and removal steps live, if it has any. As with the
# note, the file is optional and this only names it.
package_hooks_file() {
    printf '%s\n' "${PROJECT_ROOT}/config/hooks/$1.hooks"
}

# Checks a hooks file before it is packaged: the vocabulary against what the
# client implements, and every "setup" against the package's own manifest.
#
# The second check is the one that matters. sowa-pkg refuses to run a program a
# package does not own, so a path that is misspelled - or that moved when the
# stage that installs it was rewritten - would not run anything at all, and the
# machine would be told a step failed after the files were already in place.
# Here it is a build that stops.
pkg_check_hooks() {
    local name="$1"
    local manifest="$2"
    local file event action argument
    file="$(package_hooks_file "${name}")"

    [[ -f "${file}" ]] || return 0

    awk -F'|' \
        -v package="${name}" \
        -v events="${PACKAGE_HOOK_EVENTS}" \
        -v actions="${PACKAGE_HOOK_ACTIONS}" '
        BEGIN {
            split(events, list, " ")
            for (index_ in list) { known_event[list[index_]] = 1 }
            split(actions, list, " ")
            for (index_ in list) { known_action[list[index_]] = 1 }
        }
        NR == FNR {
            if ($1 == "f") { mode[$5] = $2 }
            next
        }
        /^[[:space:]]*(#|$)/ { next }
        {
            if (NF != 3) {
                printf "%s:%d: expected 3 hook fields, got %d\n", \
                    FILENAME, FNR, NF > "/dev/stderr"
                bad = 1
                next
            }
            if (!($1 in known_event)) {
                printf "%s:%d: %s is not a hook event\n", \
                    FILENAME, FNR, $1 > "/dev/stderr"
                bad = 1
            }
            if (!($2 in known_action)) {
                printf "%s:%d: %s is not a hook action\n", \
                    FILENAME, FNR, $2 > "/dev/stderr"
                bad = 1
                next
            }
            if ($2 == "setup") {
                path = $3
                if (path !~ /^\//) {
                    printf "%s:%d: setup needs an absolute path, not %s\n", \
                        FILENAME, FNR, path > "/dev/stderr"
                    bad = 1
                    next
                }
                sub(/^\//, "", path)
                if (!(path in mode)) {
                    printf "%s:%d: setup names /%s, which %s does not own\n", \
                        FILENAME, FNR, path, package > "/dev/stderr"
                    bad = 1
                } else if (mode[path] !~ /[1357][0-7][0-7]$/) {
                    printf "%s:%d: /%s is mode %s and could not be run\n", \
                        FILENAME, FNR, path, mode[path] > "/dev/stderr"
                    bad = 1
                }
            } else if ($3 !~ /^[A-Za-z0-9_.-]+$/) {
                printf "%s:%d: %s is not a service name\n", \
                    FILENAME, FNR, $3 > "/dev/stderr"
                bad = 1
            }
        }
        END { exit bad }
    ' "${manifest}" "${file}" \
        || die "${name} declares hooks that would not run"

    # A service action naming an init script nothing installs is a hook that
    # does nothing and says so on every install. The script is either one the
    # package itself carries or one the image already has.
    while IFS='|' read -r event action argument; do
        [[ -z "${event}" || "${event}" == \#* ]] && continue
        [[ "${action}" == service-* ]] || continue
        [[ -e "${ROOTFS_DIR}/etc/rc.d/init.d/${argument}" \
            || -e "${PKG_STAGE_DIR}/${name}/etc/rc.d/init.d/${argument}" \
            || -e "${PROJECT_ROOT}/rootfs-overlay/etc/rc.d/init.d/${argument}" ]] \
            || die "${name} declares a hook for the service ${argument}, which no init script provides"
    done < "${file}"
}

# Checks the init scripts a package ships, at the one point every package passes
# through on its way to being packaged.
#
# An init script is a file the build never runs, so nothing else here would
# notice that it lost its execute bit, stopped parsing, or has no header for
# chkconfig(8) to read. Each of those is discovered on the machine that
# installed the package, as a service that cannot be turned on - and by then the
# files are already in place and the daemon is already expected to work.
#
# The last rule is the one with a decision behind it rather than a mistake. A
# package the image does not carry is installed onto a machine that is already
# running, and a listener that appears because somebody installed a program is a
# listener nobody asked for. So an optional package's services default to off,
# and "chkconfig NAME on" is the whole of the decision to run one. The image's
# own services are the other case - the image is what the machine chose when it
# was installed - and image/10-rootfs.sh is where those are settled.
pkg_check_services() {
    local name="$1"
    local directory="$2"
    local initd="${directory}/etc/rc.d/init.d"
    local script service

    [[ -d "${initd}" ]] || return 0
    while IFS= read -r script; do
        service="${script##*/}"
        # The library every init script sources, which is not one itself.
        [[ "${service}" == functions ]] && continue
        [[ -x "${script}" ]] \
            || die "${name} ships /etc/rc.d/init.d/${service} without the execute bit; nothing could run it"
        bash -n "${script}" \
            || die "${name} ships an init script that is not valid shell: ${service}"
        grep -qE '^# chkconfig: ' "${script}" \
            || die "${name}'s ${service} init script has no chkconfig header; chkconfig could not place its links"
        grep -qE '^# description: ' "${script}" \
            || die "${name}'s ${service} init script has no description line"
        grep -qxF '. /etc/rc.d/init.d/functions' "${script}" \
            || die "${name}'s ${service} init script does not source the rc functions"
        package_is_optional "${name}" || continue
        grep -qE '^# chkconfig: - ' "${script}" \
            || die "${name} is installed on demand, so its ${service} service must default to off"
    done < <(find "${initd}" -maxdepth 1 -type f -print | sort)
}

# Timestamps in packages and database entries follow SOURCE_DATE_EPOCH so a
# rebuild of the same sources produces the same metadata.
package_build_date() {
    date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ'
}

# Resets and prints the staging tree for a package. A stage installs into it
# with DESTDIR and verifies its own output there, so what is inspected is
# exactly what is packaged.
pkg_stage() {
    local name="$1"
    local directory="${PKG_STAGE_DIR}/${name}"
    package_record "${name}" > /dev/null
    case "${directory}" in
        "${PKG_STAGE_DIR}"/*) ;;
        *) die "refusing to reset a staging path outside ${PKG_STAGE_DIR}: ${directory}" ;;
    esac
    # remove_tree rather than rm: the guix staging tree is a Guix store, and its
    # items are read-only directories that nothing can be unlinked from until
    # they are not.
    remove_tree "${directory}"
    mkdir -p "${directory}"
    printf '%s\n' "${directory}"
}

pkg_staged() {
    [[ -d "${PKG_STAGE_DIR}/$1" ]]
}

# What a package put into the sysroot the last time it was merged.
pkg_merged_manifest() {
    printf '%s\n' "${PKG_MERGED_DIR}/$1.paths"
}

package_is_in_image() {
    local wanted="$1"
    local name found=1
    while IFS= read -r name; do
        [[ "${name}" == "${wanted}" ]] && found=0
    done < <(image_package_names)
    return "${found}"
}

# Restore an obsolete path from the first remaining claimant in
# config/packages.conf. That is the same fixed priority order ownership uses at
# the rootfs boundary. Merge timestamps are deliberately irrelevant: otherwise
# rebuilding an earlier package could change a shared path merely because its
# record became newer, making an incremental tree differ from a clean one.
pkg_restore_other_claim() {
    local departed="$1"
    local path="$2"
    local record name source
    local -a image_names=()

    mapfile -t image_names < <(image_package_names)
    for name in "${image_names[@]}"; do
        [[ "${name}" != "${departed}" ]] || continue
        record="$(pkg_merged_manifest "${name}")"
        [[ -f "${record}" ]] || continue
        grep -Fqx -- "${path}" "${record}" || continue
        source="${PKG_STAGE_DIR}/${name}/${path}"
        [[ -e "${source}" || -L "${source}" ]] || continue
        if [[ -d "${source}" && ! -L "${source}" ]]; then
            mkdir -p "${SYSROOT}/${path}"
            chmod --reference="${source}" "${SYSROOT}/${path}"
        else
            mkdir -p "$(dirname -- "${SYSROOT}/${path}")"
            cp -a --remove-destination "${source}" "${SYSROOT}/${path}"
        fi
        return 0
    done
    return 1
}

# Reassert deterministic precedence where two component staging trees contain
# the same non-directory path. This is uncommon but real: many GNU packages
# install usr/share/info/dir. Simply copying the package that happened to be
# rebuilt last would make history, rather than the selected source revision,
# decide those bytes. The first claimant in packages.conf is also the owner
# selected by pkg_assign_ownership(), so put that claimant's bytes back after
# every incremental merge.
pkg_reassert_merge_precedence() {
    local merged="$1"
    local incoming="$2"
    local incoming_paths="$3"
    local scratch record other path candidate source
    local -a image_names=()

    mapfile -t image_names < <(image_package_names)
    scratch="${PKG_MERGED_DIR}/.${merged}.overlaps"
    : > "${scratch}"
    for other in "${image_names[@]}"; do
        [[ "${other}" != "${merged}" ]] || continue
        record="$(pkg_merged_manifest "${other}")"
        [[ -f "${record}" ]] || continue
        comm -12 <(LC_ALL=C sort -u "${record}") "${incoming_paths}" \
            >> "${scratch}"
    done
    LC_ALL=C sort -u -o "${scratch}" "${scratch}"

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        for candidate in "${image_names[@]}"; do
            if [[ "${candidate}" == "${merged}" ]]; then
                record="${incoming_paths}"
                source="${incoming}/${path}"
            else
                record="$(pkg_merged_manifest "${candidate}")"
                source="${PKG_STAGE_DIR}/${candidate}/${path}"
            fi
            [[ -f "${record}" ]] || continue
            grep -Fqx -- "${path}" "${record}" || continue
            [[ -e "${source}" || -L "${source}" ]] || continue
            if [[ -d "${source}" && ! -L "${source}" ]]; then
                die "package path collision changes type at /${path}"
            fi
            if [[ "${candidate}" != "${merged}" ]]; then
                mkdir -p "$(dirname -- "${SYSROOT}/${path}")"
                cp -a --remove-destination "${source}" "${SYSROOT}/${path}"
            fi
            break
        done
    done < "${scratch}"
    rm -f "${scratch}"
}

# Takes back the sysroot paths a package no longer installs.
#
# pkg_merge copies a staged tree over the sysroot, which every later stage
# compiles and links against and which the root filesystem starts life as a copy
# of. A copy replaces the paths that are in the new tree and says nothing about
# the paths that are not, so a package that stopped installing a program,
# renamed a shared library or dropped a header left the old one behind - where
# the next rootfs picked it up. An incremental build could therefore ship a file
# that a clean build of the same revision does not contain, and ownership
# assignment would hand that file to sowa-base rather than to whatever really
# put it there, which is what made such a file hard to trace back.
#
# So a merge records the paths it merged, and the next one begins by removing
# the recorded paths that the new tree does not supply. A path another current
# package also supplies is restored from the first claimant in package-table
# order. Directories are shared by nature - every package that installs a
# program supplies /usr/bin - and are removed with rmdir, so one that still has
# anything in it survives whatever the manifests say.
#
# An empty incoming tree means the package is not part of the image any more,
# and everything it merged goes.
pkg_sysroot_reconcile() {
    local name="$1"
    local incoming="$2"
    local record scratch path removed=0 restored=0
    record="$(pkg_merged_manifest "${name}")"

    [[ -f "${record}" ]] || return 0
    scratch="${PKG_MERGED_DIR}/.${name}.reconcile"
    rm -rf "${scratch}"
    mkdir -p "${scratch}"

    if [[ -n "${incoming}" ]]; then
        pkg_tree_paths "${incoming}" > "${scratch}/keep"
    else
        : > "${scratch}/keep"
    fi

    # Deepest first, so a directory is only tried once whatever was inside it
    # has already gone.
    LC_ALL=C sort -u "${record}" \
        | comm -23 - "${scratch}/keep" \
        | LC_ALL=C sort -r > "${scratch}/obsolete"

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        if pkg_restore_other_claim "${name}" "${path}"; then
            restored=$((restored + 1))
            continue
        fi
        if [[ -L "${SYSROOT}/${path}" || -f "${SYSROOT}/${path}" ]]; then
            rm -f "${SYSROOT}/${path}"
            removed=$((removed + 1))
        elif [[ -d "${SYSROOT}/${path}" ]]; then
            if rmdir "${SYSROOT}/${path}" 2> /dev/null; then
                removed=$((removed + 1))
            fi
        fi
    done < "${scratch}/obsolete"

    rm -rf "${scratch}"
    ((removed == 0)) \
        || log "took back ${removed} sysroot path(s) ${name} no longer installs"
    ((restored == 0)) \
        || log "restored ${restored} shared sysroot path(s) after reconciling ${name}"
}

# Records belonging to a package that was deleted from packages.conf, renamed,
# or moved out of the image otherwise have no stage left to reconcile them.
# The rootfs boundary is the final authority: only current image packages may
# have a contribution in the sysroot copied into a release.
pkg_reconcile_orphaned_merges() {
    local record name
    for record in "${PKG_MERGED_DIR}"/*.paths; do
        [[ -f "${record}" ]] || continue
        name="${record##*/}"
        name="${name%.paths}"
        package_is_in_image "${name}" && continue
        pkg_sysroot_reconcile "${name}" ""
        rm -f "${record}"
    done
}

# Every path below a tree, relative and sorted: what a merge records and what
# the next reconciliation compares against.
pkg_tree_paths() {
    (cd "$1" && find . -mindepth 1 -printf '%P\n') | LC_ALL=C sort
}

# Merges a staged tree into the sysroot, which every later stage compiles and
# links against. --remove-destination replaces the symlinks and read-only
# files an earlier build left behind instead of writing through them.
pkg_merge() {
    local name="$1"
    local directory="${PKG_STAGE_DIR}/${name}"
    local record incoming_non_directories dirty dirty_tmp
    [[ -d "${directory}" ]] || die "package ${name} has no staged tree"
    ! package_is_optional "${name}" \
        || die "${name} is an optional package and must not enter the sysroot"
    # The licences go in here rather than in each of the eighty stages, because
    # here is the one place every stage passes through, and because a licence
    # installed after the stage's own checks cannot be what a stage forgot.
    # They enter the staging tree before the merge, so the same files reach the
    # sysroot, the image and the package.
    pkg_install_licenses "${name}" "${directory}"
    pkg_check_licenses "${name}" "${directory}"
    pkg_check_services "${name}" "${directory}"
    record="$(pkg_merged_manifest "${name}")"
    pkg_tree_paths "${directory}" > "${record}.tmp.$$"
    incoming_non_directories="${PKG_MERGED_DIR}/.${name}.non-directories.$$"
    (cd "${directory}" && find . -mindepth 1 ! -type d -printf '%P\n') \
        | LC_ALL=C sort -u > "${incoming_non_directories}"
    # A failed copy can have introduced a path that the last successful merge
    # record does not know. Do not let another stage build against that mixed
    # sysroot: the next invocation requires a clean tree. The marker is replaced
    # atomically and removed only after both the copy and its record are durable.
    dirty="${PKG_MERGED_DIR}/.dirty"
    dirty_tmp="${PKG_MERGED_DIR}/.dirty.$$"
    printf '%s\n' "${name}" > "${dirty_tmp}"
    mv "${dirty_tmp}" "${dirty}"
    pkg_sysroot_reconcile "${name}" "${directory}"
    cp -a --remove-destination "${directory}/." "${SYSROOT}/"
    pkg_reassert_merge_precedence "${name}" "${directory}" \
        "${incoming_non_directories}"
    rm -f "${incoming_non_directories}"
    # Written after the copy rather than before it: the record is a statement
    # about the sysroot, and a merge that died halfway through leaves the stage
    # without a stamp and the record describing the merge before it.
    mv "${record}.tmp.$$" "${record}"
    rm -f "${dirty}"
    log "staged ${name} $(package_version "${name}") ($(package_license "${name}")) for packaging"
}

# What an optional package's stage calls instead of pkg_merge. Nothing in the
# image links against it and the image must not carry it, so its staged tree
# stays where it is and the package is cut from there rather than from the
# assembled root filesystem.
pkg_keep_staged() {
    local name="$1"
    local directory="${PKG_STAGE_DIR}/${name}"
    [[ -d "${directory}" ]] || die "package ${name} has no staged tree"
    package_is_optional "${name}" \
        || die "${name} is part of the image; merge it into the sysroot instead"
    pkg_install_licenses "${name}" "${directory}"
    pkg_check_licenses "${name}" "${directory}"
    pkg_check_services "${name}" "${directory}"
    # A package that used to be in the image has files in the sysroot from the
    # last time it was merged there. It is not in the image now, so they go -
    # the same reconciliation, against nothing.
    pkg_sysroot_reconcile "${name}" ""
    rm -f "$(pkg_merged_manifest "${name}")"
    log "staged ${name} $(package_version "${name}") ($(package_license "${name}")) for the repository only"
}

# Describes a directory tree as "type|mode|hash-or-target|size|path" lines,
# sorted by path. Regular files carry a SHA-256 so an installed system can be
# verified against the package that placed it there.
pkg_tree_manifest() {
    local root="$1"
    local output="$2"
    local scratch raw hashes unsupported unrepresentable

    [[ -d "${root}" ]] || die "cannot describe a missing tree: ${root}"
    require_command find
    require_command xargs
    require_command sha256sum

    unsupported="$(find "${root}" -mindepth 1 ! -type f ! -type d ! -type l \
        -print -quit)"
    [[ -z "${unsupported}" ]] \
        || die "unsupported file type below ${root}: ${unsupported}"
    unrepresentable="$(find "${root}" -mindepth 1 \
        \( -name '*|*' -o -name '*\\*' -o -name "*${NEWLINE}*" \) -print -quit)"
    [[ -z "${unrepresentable}" ]] \
        || die "path cannot be expressed in a manifest: ${unrepresentable}"

    scratch="${PKG_META_DIR}/.manifest"
    rm -rf "${scratch}"
    mkdir -p "${scratch}"
    raw="${scratch}/entries"
    hashes="${scratch}/sha256"

    find "${root}" -mindepth 1 -printf '%y|%m|%s|%l|%P\n' \
        | sort -t'|' -k5 > "${raw}"
    (
        cd "${root}" || exit 1
        awk -F'|' '$1 == "f" { print $5 }' "${raw}" \
            | tr '\n' '\0' \
            | xargs -0 -r sha256sum --
    ) > "${hashes}"

    awk -F'|' -v hashfile="${hashes}" '
        BEGIN {
            while ((getline line < hashfile) > 0) {
                sums[substr(line, 67)] = substr(line, 1, 64)
            }
        }
        $1 == "f" {
            if (!($5 in sums)) {
                printf "no checksum for %s\n", $5 > "/dev/stderr"
                bad = 1
                next
            }
            printf "f|%s|%s|%s|%s\n", $2, sums[$5], $3, $5
            next
        }
        $1 == "d" { printf "d|%s|-|0|%s\n", $2, $5; next }
        $1 == "l" { printf "l|0777|%s|0|%s\n", $4, $5; next }
        { printf "unsupported manifest entry: %s\n", $0 > "/dev/stderr"; bad = 1 }
        END { exit bad }
    ' "${raw}" > "${output}" || die "could not describe ${root}"
    rm -rf "${scratch}"
}

# Total size of the regular files a manifest lists.
pkg_manifest_size() {
    awk -F'|' '$1 == "f" { total += $4 } END { printf "%d\n", total }' "$1"
}

pkg_manifest_paths() {
    awk -F'|' '{ print $5 }' "$1"
}

# The build identity of a package: a digest of its installed state and the
# provenance that produced it.
#
# A package version is an upstream version and a release counter somebody
# maintains by hand, and nothing derives it from what was actually built.
# Rebuilding curl against a new OpenSSL, correcting a recipe or adding a patch
# produces different bytes under the same version - and the client plans an
# install only where the versions differ, so those bytes never reach the
# machines that already have the package. The release counter exists for
# exactly that case and has to be remembered.
#
# This is the same statement made by the build rather than by a person. It
# covers the manifest (including a SHA-256 per file), installed metadata, hooks
# and note, plus the producer stage key, compiler/toolchain identity and direct
# dependency stage keys. Two builds can therefore differ even when their output
# happens to be byte-identical: the id records which audited inputs produced
# it. It travels in the .PKGINFO, database entry, archive filename and index;
# sowa-pkg reinstalls a package whose version has not changed and whose build id
# has.
#
# Bumping the release counter is still worth doing - it is the number a person
# reads - but forgetting it no longer makes a rebuild invisible.
pkg_build_id() {
    local name="$1"
    local manifest="$2"
    local stage producer_key dependency dependency_stage version

    # Most packages have a component stage. The two packages assembled from
    # shared outputs use the stage that actually produces those bytes.
    case "${name}" in
        linux) stage=image/kernel ;;
        sowa-base | sowa-release) stage=image/10-rootfs ;;
        *) stage="$(package_stage_name "${name}")" ;;
    esac
    # The version comes out of the lock, and asking for it is what records the
    # lock row against the running stage. Ask before predicting, never after:
    # the prediction below is of a key that carries those rows, so a row this
    # call is itself about to add has to be in the record already.
    version="$(package_version "${name}")"
    if [[ "${name}" == sowa-base || "${name}" == sowa-release ]]; then
        # Their database entries are written by image/10-rootfs while that
        # stage is running, before its successful stamp can exist. Compute the
        # same key the driver will record at the end; otherwise the image would
        # contain producer=absent while the repository built a moment later
        # contained producer=<image/10-rootfs>, and a fresh installation would
        # immediately plan a needless rebuild of both packages.
        producer_key="$(stage_key image/10-rootfs \
            "$(stage_script image/10-rootfs)" -)"
    else
        producer_key="$(recorded_stage_key "${stage:-absent}")"
    fi
    {
        printf 'name %s\n' "${name}"
        printf 'version %s\n' "${version}"
        printf 'arch %s\n' "${PKG_ARCH}"
        printf 'toolchain %s\n' "$(stage_toolchain_digest)"
        printf 'producer %s %s\n' "${stage:-absent}" "${producer_key}"
        # Keep direct dependency fingerprints explicit even though a normal
        # producer key already carries them. This also covers packages such as
        # sowa-release whose contents are assembled rather than built by a
        # component stage.
        while IFS= read -r dependency; do
            [[ -n "${dependency}" && "${dependency}" != - ]] || continue
            dependency_stage="$(package_stage_name "${dependency}")"
            printf 'dependency %s %s %s\n' "${dependency}" \
                "${dependency_stage:-absent}" \
                "$(recorded_stage_key "${dependency_stage:-absent}")"
        done < <(package_depends "${name}" | tr ',' '\n' | LC_ALL=C sort -u)
        printf 'depends %s\n' "$(package_depends "${name}")"
        printf 'license %s\n' "$(package_license "${name}")"
        printf 'copyright %s\n' "$(package_copyright "${name}")"
        printf 'description %s\n' "$(package_description "${name}")"
        printf 'hooks %s\n' "$(hash_file "$(package_hooks_file "${name}")")"
        printf 'message %s\n' "$(hash_file "$(package_message_file "${name}")")"
        printf 'files\n'
        cat "${manifest}"
    } | sha256sum | cut -c1-64
}

# Writes the .PKGINFO carried by a package archive and mirrored, with the
# install date added, as the local database entry.
pkg_write_info() {
    local name="$1"
    local manifest="$2"
    local output="$3"
    {
        printf 'pkgname=%s\n' "${name}"
        printf 'pkgver=%s\n' "$(package_version "${name}")"
        # What the version cannot say: which build this is. See pkg_build_id.
        printf 'pkgbuild=%s\n' "$(pkg_build_id "${name}" "${manifest}")"
        printf 'arch=%s\n' "${PKG_ARCH}"
        printf 'distro=%s %s\n' "${DISTRO_NAME}" "${DISTRO_VERSION}"
        printf 'builddate=%s\n' "$(package_build_date)"
        printf 'size=%s\n' "$(pkg_manifest_size "${manifest}")"
        printf 'depends=%s\n' "$(package_depends "${name}")"
        # The licence travels with the package rather than only with the
        # repository index, so an installed system can still answer "what am I
        # allowed to do with this" after it has been taken off the network.
        printf 'license=%s\n' "$(package_license "${name}")"
        printf 'copyright=%s\n' "$(package_copyright "${name}")"
        printf 'description=%s\n' "$(package_description "${name}")"
    } > "${output}"
}

# Splits an assembled root filesystem between the packages that produced it and
# writes one manifest per package below PKG_META_DIR. Every path is claimed
# exactly once, in a fixed priority order:
#
#   1. the root filesystem overlay, which is copied last and therefore wins
#      wherever a component stage installed the same path (etc/ssh/sshd_config
#      is the standing example)
#   2. the component staging trees, in config/packages.conf order
#   3. sowa-base, which is by definition everything left over
#
# Deriving ownership from the assembled image rather than from a hand-written
# file list is what keeps the published packages and the shipped image the same
# thing: their union is the image, by construction.
#
# The optional packages take no part in that split - they are not in the image -
# so their manifests are cut from their staging trees at the end instead.
pkg_assign_ownership() {
    local root="$1"
    local manifest="${PKG_META_DIR}/rootfs.manifest"
    local -A owner=() known=()
    local name relative type mode value size path claimant

    pkg_tree_manifest "${root}" "${manifest}"

    while IFS= read -r relative; do
        owner["${relative}"]=sowa-release
    done < <(cd "${PROJECT_ROOT}/rootfs-overlay" && find . -mindepth 1 -printf '%P\n')

    # A package owns its own licence directory, whatever put it there. For most
    # of them this changes nothing - pkg_merge installs the texts into the
    # staging tree and rule 2 below would claim them anyway - but two packages
    # in the image have no staging tree to be claimed from: sowa-base is by
    # definition the leftovers, and sowa-release is the overlay, so the rootfs
    # stage installs their licences into the tree directly and this is what
    # stops them falling to sowa-base together.
    while IFS= read -r name; do
        known["${name}"]=1
    done < <(package_names)
    while IFS='|' read -r type mode value size path; do
        [[ "${path}" == usr/share/licenses/*/* ]] || continue
        [[ -z "${owner[${path}]:-}" ]] || continue
        claimant="${path#usr/share/licenses/}"
        claimant="${claimant%%/*}"
        [[ -n "${known[${claimant}]:-}" ]] \
            || die "/${path} is under the licence directory of no package"
        owner["${path}"]="${claimant}"
    done < "${manifest}"

    while IFS= read -r name; do
        pkg_staged "${name}" || continue
        while IFS= read -r relative; do
            [[ -n "${owner[${relative}]:-}" ]] && continue
            owner["${relative}"]="${name}"
        done < <(cd "${PKG_STAGE_DIR}/${name}" && find . -mindepth 1 -printf '%P\n')
    done < <(image_package_names)

    while IFS='|' read -r type mode value size path; do
        [[ -n "${owner[${path}]:-}" ]] && continue
        owner["${path}"]=sowa-base
    done < "${manifest}"

    while IFS= read -r name; do
        : > "${PKG_META_DIR}/${name}.files"
    done < <(image_package_names)

    while IFS='|' read -r type mode value size path; do
        name="${owner[${path}]}"
        printf '%s|%s|%s|%s|%s\n' \
            "${type}" "${mode}" "${value}" "${size}" "${path}" \
            >> "${PKG_META_DIR}/${name}.files"
    done < "${manifest}"

    while IFS= read -r name; do
        pkg_optional_manifest "${name}" "${manifest}"
    done < <(optional_package_names)
}

# An optional package is not in the image, so its manifest is cut from its own
# staging tree. The directories the image already provides are left out of it:
# /usr/sbin belongs to the packages that built the image, and a manifest
# claiming it a second time would collide with them on an installed system. A
# file the image already carries is a genuine conflict and stops the build.
pkg_optional_manifest() {
    local name="$1"
    local image_manifest="$2"
    local staged="${PKG_STAGE_DIR}/${name}"
    local output="${PKG_META_DIR}/${name}.files"
    local complete="${PKG_META_DIR}/.${name}.staged"

    pkg_staged "${name}" \
        || die "optional package ${name} has no staged tree; build it first"
    pkg_tree_manifest "${staged}" "${complete}"
    awk -F'|' -v name="${name}" '
        NR == FNR { in_image[$5] = $1; next }
        ($5 in in_image) {
            if ($1 == "d") { next }
            printf "%s ships %s, which the image already has\n", name, $5 \
                > "/dev/stderr"
            bad = 1
            next
        }
        { print }
        END { exit bad }
    ' "${image_manifest}" "${complete}" > "${output}" \
        || die "the optional package ${name} conflicts with the image"
    rm -f "${complete}"
    [[ -s "${output}" ]] || die "optional package ${name} owns no files"
}

# Installs a database entry into a root filesystem, so a freshly built image
# knows what it is made of before it has ever contacted the repository.
pkg_db_write() {
    local root="$1"
    local name="$2"
    local manifest="$3"
    local entry="${root}/var/lib/sowa/db/${name}"
    local hooks

    install -d -m 0755 "${entry}"
    pkg_write_info "${name}" "${manifest}" "${entry}/desc"
    printf 'installdate=%s\n' "$(package_build_date)" >> "${entry}/desc"
    printf 'origin=image\n' >> "${entry}/desc"
    install -m 0644 "${manifest}" "${entry}/files"

    # The hooks go in with the entry rather than only into the archive, because
    # a package that arrived with the image never had an archive on the machine
    # and pre-remove has to work all the same: removing the openssh the image
    # shipped has to stop the sshd the image started.
    hooks="$(package_hooks_file "${name}")"
    if [[ -f "${hooks}" ]]; then
        pkg_check_hooks "${name}" "${manifest}"
        install -m 0644 "${hooks}" "${entry}/hooks"
    else
        rm -f "${entry}/hooks"
    fi
}
