#!/usr/bin/env bash
#
# Licence handling: what every package is under, and where the text of it comes
# from.
#
# A distribution that ships someone else's work has to ship the licence that
# work was given to it under. Almost every licence here says so outright - the
# GPL and the LGPL require the text with every distribution, the BSD and MIT
# families require the notice to be reproduced - so a package without its
# licence is not merely undocumented, it is distributed on terms it does not
# meet. Sowa therefore treats the licence as part of the package rather than as
# documentation about it: every package installs its texts into
#
#   /usr/share/licenses/<package>/
#
# which is a real directory the package owns, listed in its .FILES, verified by
# "sowa-pkg verify", and removed when the package is.
#
# The table is config/licenses.conf. The texts themselves are not copied into
# this repository: they are taken out of the same pinned tarballs the code is
# built from, so the licence that ships is the licence that came with the
# version that was built, and it cannot drift from it. Only where an upstream
# distribution carries no text at all - the Mozilla CA bundle is a file of
# certificates and nothing else - does config/licenses/ hold one.
#
# This file is sourced from lib/common.sh and assumes its variables.

license_record() {
    local wanted="$1"
    local name copyright license files

    while IFS='|' read -r name copyright license files; do
        [[ -z "${name}" || "${name}" == \#* ]] && continue
        if [[ "${name}" == "${wanted}" ]]; then
            printf '%s|%s|%s|%s\n' "${name}" "${copyright}" "${license}" "${files}"
            return 0
        fi
    done < "${LICENSES_CONF}"

    die "package '${wanted}' has no entry in ${LICENSES_CONF}"
}

# Who holds the copyright: "sowa" for something this repository is the author
# of, "upstream" for someone else's work.
package_copyright() {
    local _name copyright _license _files
    IFS='|' read -r _name copyright _license _files < <(license_record "$1")
    printf '%s\n' "${copyright}"
}

package_license() {
    local _name _copyright license _files
    IFS='|' read -r _name _copyright license _files < <(license_record "$1")
    printf '%s\n' "${license}"
}

# The licence files a package installs, one "origin:path[=name]" per line.
package_license_files() {
    local _name _copyright _license files
    IFS='|' read -r _name _copyright _license files < <(license_record "$1")
    [[ -n "${files}" && "${files}" != - ]] \
        || die "package '$1' names no licence file in ${LICENSES_CONF}"
    tr ',' '\n' <<< "${files}"
}

# Copies one licence text out of the source it belongs to.
#
# The unpacked tree is preferred because it is already there and reading a file
# out of it costs nothing. Not every source has one - 7-Zip, tzdata, and the
# patch archives unpack no top-level directory and their stages take them apart
# by hand - so the pinned archive is the fallback, and going through
# locked_download_path is what checks its SHA-256 before anything is read out.
license_copy_file() {
    local origin="$1"
    local path="$2"
    local destination="$3"
    local directory archive candidate
    local -a candidates=()

    if [[ "${origin}" == sowa ]]; then
        [[ -f "${PROJECT_ROOT}/${path}" ]] \
            || die "no licence text at ${path} in this repository"
        install -m 0644 "${PROJECT_ROOT}/${path}" "${destination}"
        return 0
    fi

    IFS='|' read -r _ _ _ _ _ directory < <(lock_record "${origin}")
    if [[ "${directory}" != - && -f "${SOURCE_DIR}/${directory}/${path}" ]]; then
        install -m 0644 "${SOURCE_DIR}/${directory}/${path}" "${destination}"
        return 0
    fi

    archive="$(locked_download_path "${origin}")"
    candidates=("${path}" "./${path}")
    if [[ "${directory}" != - ]]; then
        candidates+=("${directory}/${path}" "./${directory}/${path}")
    fi
    for candidate in "${candidates[@]}"; do
        # --occurrence=1 stops the read at the first match rather than scanning
        # the rest of the archive for more of them.
        if tar -xOf "${archive}" --occurrence=1 "${candidate}" \
            > "${destination}.tmp" 2>/dev/null && [[ -s "${destination}.tmp" ]]; then
            chmod 0644 "${destination}.tmp"
            mv "${destination}.tmp" "${destination}"
            return 0
        fi
    done
    rm -f "${destination}.tmp"
    die "the ${origin} sources carry no licence text at ${path}"
}

# Where a package keeps its licences, relative to the root of a filesystem.
license_directory() {
    printf 'usr/share/licenses/%s\n' "$1"
}

# Installs a package's licence texts below a root - a staging tree for a package
# that has one, the assembled image for the two that do not.
#
# The directory is rebuilt from the table on every run rather than added to, so
# a text that has been renamed or dropped from config/licenses.conf leaves with
# it instead of lingering in the package as a file nothing claims any more.
pkg_install_licenses() {
    local name="$1"
    local root="$2"
    local relative directory entry origin path installed
    local -A seen=()
    local -a entries=()
    local count=0

    [[ -n "${name}" ]] || die "pkg_install_licenses was given no package name"
    [[ -d "${root}" ]] || die "cannot install licences into a missing tree: ${root}"
    # The table is read before anything is removed, so a name that is not a
    # package - or a package with no licence row - fails without having deleted
    # a directory first. The record is looked up here rather than only inside
    # the mapfile below, because a die inside a process substitution ends the
    # subshell and not this function: the caller would see the second, vaguer
    # message instead of the one that says what is actually wrong.
    license_record "${name}" > /dev/null
    mapfile -t entries < <(package_license_files "${name}")
    ((${#entries[@]} > 0)) || die "${name} names no licence text"

    relative="$(license_directory "${name}")"
    directory="${root}/${relative}"
    rm -rf "${directory}"
    install -d -m 0755 "${directory}"

    for entry in "${entries[@]}"; do
        [[ -n "${entry}" ]] || continue
        installed=""
        if [[ "${entry}" == *=* ]]; then
            installed="${entry##*=}"
            entry="${entry%=*}"
        fi
        origin="${entry%%:*}"
        path="${entry#*:}"
        [[ "${origin}" != "${entry}" && -n "${origin}" && -n "${path}" ]] \
            || die "${name}: '${entry}' is not an origin:path licence reference"
        [[ -n "${installed}" ]] || installed="${path##*/}"
        [[ -z "${seen[${installed}]:-}" ]] \
            || die "${name} would install two licence texts as ${installed}; rename one with '=' in ${LICENSES_CONF}"
        seen["${installed}"]=1
        license_copy_file "${origin}" "${path}" "${directory}/${installed}"
        count=$((count + 1))
    done

    ((count > 0)) || die "${name} installed no licence text"
}

# Asserts that a tree carries a package's licences. The build says this at every
# point a package is finished, because an empty or missing licence directory is
# the one packaging fault that cannot be seen by using the system afterwards.
pkg_check_licenses() {
    local name="$1"
    local root="$2"
    local relative directory

    relative="$(license_directory "${name}")"
    directory="${root}/${relative}"
    [[ -d "${directory}" ]] || die "${name} carries no /${relative}"
    [[ -n "$(ls -A "${directory}")" ]] \
        || die "${name}'s licence directory /${relative} is empty"
}
