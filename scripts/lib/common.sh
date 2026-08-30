#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly PROJECT_ROOT
# Overridable for the same reason the package and licence tables are:
# scripts/selftest.sh points all three at scratch copies so that asserting what
# a bumped version does to a stage key cannot edit the real ones.
readonly LOCK_FILE="${LOCK_FILE:-${PROJECT_ROOT}/config/sources.lock}"
# Download locations are deliberately kept out of sources.lock: changing a
# mirror does not change the bytes a stage consumes and must not invalidate a
# build. fetch.sh reads this table while the lock remains the source of the
# archive name and digest.
readonly MIRRORS_FILE="${MIRRORS_FILE:-${PROJECT_ROOT}/config/mirrors.conf}"
# shellcheck disable=SC2034 # read by lib/package.sh, sourced at the end.
readonly PACKAGES_CONF="${PACKAGES_CONF:-${PROJECT_ROOT}/config/packages.conf}"
# shellcheck disable=SC2034 # read by lib/license.sh, sourced at the end.
readonly LICENSES_CONF="${LICENSES_CONF:-${PROJECT_ROOT}/config/licenses.conf}"
# The driver, for the one thing that reads it as data rather than runs it:
# which stage builds which package. Overridable for the same reason the three
# tables above are - scripts/selftest.sh asserts what a change to it does and
# does not invalidate, and must not edit the real one to do it.
readonly DRIVER_FILE="${DRIVER_FILE:-${PROJECT_ROOT}/scripts/build.sh}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/build.conf"

readonly WORK_DIR="${WORK_DIR:-${PROJECT_ROOT}/work}"
readonly DOWNLOAD_DIR="${DOWNLOAD_DIR:-${PROJECT_ROOT}/downloads}"
readonly SOURCE_DIR="${SOURCE_DIR:-${WORK_DIR}/sources}"
readonly BUILD_DIR="${BUILD_DIR:-${WORK_DIR}/build}"
readonly SYSROOT="${SYSROOT:-${WORK_DIR}/sysroot}"
readonly TOOLS_DIR="${TOOLS_DIR:-${WORK_DIR}/tools}"
readonly ROOTFS_DIR="${ROOTFS_DIR:-${WORK_DIR}/rootfs}"
readonly STAMP_DIR="${STAMP_DIR:-${WORK_DIR}/stamps}"
readonly ARTIFACT_DIR="${ARTIFACT_DIR:-${PROJECT_ROOT}/artifacts}"
# Each component stage installs into its own tree below PKG_STAGE_DIR, which is
# what makes per-package file ownership knowable; PKG_META_DIR holds the
# resulting manifests and PACKAGE_DIR the publishable repository.
readonly PKG_STAGE_DIR="${PKG_STAGE_DIR:-${WORK_DIR}/pkgstage}"
readonly PKG_META_DIR="${PKG_META_DIR:-${WORK_DIR}/pkgmeta}"
readonly PACKAGE_DIR="${PACKAGE_DIR:-${WORK_DIR}/packages}"
# What each package put into the sysroot when it was last merged, which is how
# the next merge knows which of its old paths to take away again. See
# pkg_sysroot_reconcile in lib/package.sh.
readonly PKG_MERGED_DIR="${PKG_MERGED_DIR:-${WORK_DIR}/pkgmerged}"

# The Python that CPython's cross build needs on the machine doing the build.
# Stage host/python installs the pinned release here for this machine and stage
# packages/python is configured with it. Two files have to agree on the path, so
# it is written once. It is deliberately not on PATH: nothing else in the build
# should reach for it by name.
# shellcheck disable=SC2034 # read by stages/host/python.sh.
readonly HOST_PYTHON_DIR="${TOOLS_DIR}/host-python"
# shellcheck disable=SC2034 # read by stages/packages/python.sh.
readonly HOST_PYTHON="${HOST_PYTHON_DIR}/bin/python3"

if [[ "${JOBS}" == auto ]]; then
    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
fi
readonly JOBS

export LC_ALL=C
export LANG=C
export TZ=UTC
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}"
export PATH="${TOOLS_DIR}/bin:/usr/bin:/bin"
export CONFIG_SITE=/dev/null
umask 022

log() {
    printf '==> %s\n' "$*"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# A single stage can compile for tens of minutes behind a wall of compiler
# output, so the driver mirrors the running stage in the terminal title. Only
# the top-level driver claims the title; stage scripts source this file too and
# leave it alone. Nothing is emitted unless stderr is an interactive terminal,
# so piped and logged builds are unaffected.
BUILD_LABEL="${DISTRO_NAME}"
CURRENT_STAGE=""

term_title() {
    [[ "${TERM_TITLE}" != 0 && -t 2 ]] || return 0
    case "${TERM:-}" in
        '' | dumb) ;;
        # screen and tmux take the window name through their own escape; the
        # trailing OSC also reaches the outer terminal when titles are forwarded.
        screen* | tmux*) printf '\033k%s\033\\\033]0;%s\007' "$*" "$*" >&2 ;;
        *) printf '\033]0;%s\007' "$*" >&2 ;;
    esac
}

report_title_exit() {
    local status=$?
    if ((status == 0)); then
        term_title "${BUILD_LABEL}: done"
    else
        term_title "${BUILD_LABEL}: FAILED${CURRENT_STAGE:+ ${CURRENT_STAGE}}"
    fi
}

claim_terminal_title() {
    BUILD_LABEL="${DISTRO_NAME} $1"
    trap report_title_exit EXIT
    term_title "${BUILD_LABEL}: starting"
}

# Records what is running for the exit title and shows it. The argument may
# carry a position, as the fetch work list knows its own length.
show_progress() {
    CURRENT_STAGE="$1"
    term_title "${BUILD_LABEL}: $1"
}

begin_stage() {
    log "stage $*"
    show_progress "$1"
}

validate_dedicated_directory() {
    local label="$1"
    local directory="$2"
    [[ -n "${directory}" && "${directory}" != / && "${directory}" != "${HOME}" \
        && "${directory}" != "${PROJECT_ROOT}" ]] \
        || die "${label} must be a dedicated directory, not ${directory}"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required host command not found: $1"
}

# Store release checksums beside their artifacts using only the filename.  A
# manifest with an absolute build path cannot be checked after it is copied to
# another machine.
write_sha256_manifest() {
    local artifact="$1"
    local directory filename

    directory="$(dirname -- "${artifact}")"
    filename="$(basename -- "${artifact}")"
    (
        cd -- "${directory}"
        sha256sum -- "${filename}" > "${filename}.sha256"
    )
}

# The stamp directory mirrors the groups under scripts/stages, since a stage's
# name is its path there. The groups are made up front so that anything which
# writes a stamp by name - a stage, or a test standing in for one - finds the
# directory already there.
readonly STAGE_GROUPS=(toolchain host packages image)

init_directories() {
    local group
    mkdir -p "${WORK_DIR}" "${DOWNLOAD_DIR}" "${SOURCE_DIR}" "${BUILD_DIR}" \
        "${SYSROOT}" "${TOOLS_DIR}" "${ROOTFS_DIR}" "${STAMP_DIR}" "${ARTIFACT_DIR}" \
        "${PKG_STAGE_DIR}" "${PKG_META_DIR}" "${PKG_MERGED_DIR}" "${PACKAGE_DIR}"
    for group in "${STAGE_GROUPS[@]}"; do
        mkdir -p "${STAMP_DIR}/${group}"
    done
}

lock_record() {
    local wanted="$1"
    local name version archive url sha directory

    # What a stage turned out to depend on, recorded as it asks for it. Every
    # route to a pinned tarball - prepare_source, source_version, source_path,
    # locked_download_path, the licence copier - comes through here, including
    # the loops that build a name instead of writing one down, so this is the
    # one place that sees them all. stage_execute() keeps the file and the next
    # run's key is computed from it; see "stage identity" below.
    [[ -z "${STAGE_DEPS_FILE}" ]] \
        || printf '%s\n' "${wanted}" >> "${STAGE_DEPS_FILE}"

    while IFS='|' read -r name version archive url sha directory; do
        [[ -z "${name}" || "${name}" == \#* ]] && continue
        if [[ "${name}" == "${wanted}" ]]; then
            printf '%s|%s|%s|%s|%s|%s\n' \
                "${name}" "${version}" "${archive}" "${url}" "${sha}" "${directory}"
            return 0
        fi
    done < "${LOCK_FILE}"

    die "source '${wanted}' is not present in ${LOCK_FILE}"
}

source_version() {
    local _name version _archive _url _sha _directory
    IFS='|' read -r _name version _archive _url _sha _directory < <(lock_record "$1")
    printf '%s\n' "${version}"
}

source_path() {
    local _name _version _archive _url _sha directory
    IFS='|' read -r _name _version _archive _url _sha directory < <(lock_record "$1")
    printf '%s/%s\n' "${SOURCE_DIR}" "${directory}"
}

locked_download_path() {
    local wanted="$1"
    local _name _version archive _url sha _directory
    local archive_path actual
    IFS='|' read -r _name _version archive _url sha _directory < <(lock_record "${wanted}")
    archive_path="${DOWNLOAD_DIR}/${archive}"
    [[ -f "${archive_path}" ]] || die "missing ${archive}; run 'make fetch' first"
    actual="$(sha256sum "${archive_path}" | awk '{print $1}')"
    [[ "${actual}" == "${sha}" ]] || die "checksum mismatch for ${archive}"
    printf '%s\n' "${archive_path}"
}

validate_archive_members() {
    local archive_path="$1"
    tar -tf "${archive_path}" | awk '
        /^\// || /(^|\/)\.\.(\/|$)/ { bad=1 }
        END { exit bad }
    ' || die "archive contains an unsafe path: $(basename "${archive_path}")"
}

prepare_source() {
    local wanted="$1"
    local _name _version archive _url _sha directory
    local archive_path destination temporary
    IFS='|' read -r _name _version archive _url _sha directory < <(lock_record "${wanted}")
    archive_path="$(locked_download_path "${wanted}")"
    destination="${SOURCE_DIR}/${directory}"

    if [[ ! -d "${destination}" ]]; then
        validate_archive_members "${archive_path}"
        temporary="${SOURCE_DIR}/.${directory}.extract.$$"
        rm -rf "${temporary}"
        mkdir -p "${temporary}"
        tar -xf "${archive_path}" -C "${temporary}"
        [[ -d "${temporary}/${directory}" ]] || die "archive ${archive} has an unexpected top-level directory"
        mv "${temporary}/${directory}" "${destination}"
        rmdir "${temporary}"
    fi
    printf '%s\n' "${destination}"
}

# GCC needs GMP, MPFR and MPC - it does exact arithmetic on constants with them
# - and builds them itself when it finds them unpacked inside its own source
# tree. That is how both GCC stages get them: a copy built in tree is linked
# statically into cc1 and is never installed, so no version of these libraries
# has to exist on the build machine or in the image.
link_gcc_prerequisites() {
    local gcc_source="$1"
    local dependency dependency_source
    for dependency in gmp mpfr mpc; do
        dependency_source="$(prepare_source "${dependency}")"
        # Test the link itself, not its target: a link left by an earlier build
        # of a tree that has since moved is dangling, so -e reports it absent
        # while ln still refuses to create it. Replace any link, but never a
        # real directory.
        if [[ -L "${gcc_source}/${dependency}" || ! -e "${gcc_source}/${dependency}" ]]; then
            ln -sfn "${dependency_source}" "${gcc_source}/${dependency}"
        fi
    done
}

reset_build_dir() {
    local directory="$1"
    case "${directory}" in
        "${BUILD_DIR}"/*) ;;
        *) die "refusing to reset path outside ${BUILD_DIR}: ${directory}" ;;
    esac
    rm -rf "${directory}"
    mkdir -p "${directory}"
}

# Removes a tree that may contain read-only directories. A Guix store is made of
# them - every store item is dr-xr-xr-x, which is how it stays what its name
# says it is - and a directory without write permission is one nothing can be
# unlinked from, not even by the user that owns it: plain "rm -rf" stops at the
# first one. Nothing else Sowa builds needs this, and it costs one chmod.
remove_tree() {
    local directory="$1"
    [[ -e "${directory}" ]] || return 0
    # -R does not follow the symbolic links it walks past, so a link into a
    # store path that happens to exist on the build host is not touched.
    chmod -R u+rwX "${directory}"
    rm -rf "${directory}"
}

# The stage identity machinery - stage keys, stamps and the driver's view of
# which stage builds what - lives in lib/stage.sh, which is sourced at the end
# of this file. It is kept out of this one because this one is hashed into
# every stage key and that one deliberately is not; see stage_shared_digest.

# The two memory figures the live medium has, in MiB, and the reason there are
# two of them.
#
# The live system mounts its root filesystem from the medium: a squashfs on a
# loop device with a tmpfs overlaid on it. Nothing is unpacked, so what a boot
# costs is the writable layer plus whatever of the tree is currently being
# read - and the read pages are page cache, which the kernel can evict. That is
# the difference from the image this replaced, where the whole tree went into a
# ramfs whose pages cannot be reclaimed and a machine with less than three
# times the tree booted into a root filesystem missing an arbitrary tail of
# itself.
#
# The floor is therefore no longer a function of the tree's size. It is the
# kernel, the initramfs, the decompression buffers squashfs needs for a 1 MiB
# block, and enough tmpfs for a boot's worth of writes. This figure is a
# deliberate over-estimate of that rather than a measurement of it: it has not
# been checked against a machine that fails just below it, the way the old
# 3 GiB was.
live_ram_stream_mib() {
    printf '512\n'
}

# Above this, liveinit's copytoram=auto copies the image into RAM instead of
# reading it from the medium: the whole squashfs plus 2 GiB of headroom, which
# is the rule decide_copy_to_ram() applies at boot. Below it the machine still
# boots - it just keeps reading the medium, and cannot be handed the stick
# back. Optical media are excluded from the copy regardless.
live_ram_copytoram_mib() {
    local image="$1"
    local image_mib
    image_mib="$(($(stat -c %s "${image}") / 1048576))"
    printf '%s\n' "$((image_mib + 2048))"
}

# The identity of a medium carrying this image: the first 16 hex digits of the
# root filesystem's SHA-256. The ISO stage writes an empty file named after it
# and puts it on the kernel command line, and liveinit boots the medium that
# has it. Deriving it from the payload rather than from the build time is what
# makes two media the same medium exactly when they carry the same root
# filesystem, and keeps it stable across a rebuild that changes nothing.
live_medium_id() {
    sha256sum "$1" | cut -c1-16
}

# Where the host's GRUB keeps its platform modules. Two stages need it - the ISO
# hands it to grub-mkrescue, the disk image builds its own core images out of it -
# and the three places it can be is a property of the build host rather than of
# either of them. The i386-pc directory is what makes a candidate the right one:
# a host with the GRUB tools but no platform files installed has the directory
# and nothing in it.
host_grub_libdir() {
    local candidate
    for candidate in /usr/lib/grub /usr/lib64/grub /usr/share/grub; do
        if [[ -d "${candidate}/i386-pc" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    die "GRUB i386-pc platform files not found; install GRUB"
}

# A locale name in the spelling the compiled archive uses. glibc normalises the
# codeset when it stores a locale - UTF-8 becomes utf8, ISO-8859-1 becomes
# iso88591 - and leaves the language, the territory and the @modifier alone, so
# "localedef --list-archive" answers in names that do not match the ones
# config/locales.conf and /etc/locale.conf are written in. Both the locales
# stage and the rootfs stage compare the two, and this is the one place that
# says how.
normalise_locale_name() {
    local name="$1" codeset modifier=""
    [[ "${name}" == *.* ]] || { printf '%s\n' "${name}"; return; }
    codeset="${name#*.}"
    if [[ "${codeset}" == *@* ]]; then
        modifier="@${codeset#*@}"
        codeset="${codeset%@*}"
    fi
    codeset="$(printf '%s' "${codeset}" | tr -d -c '[:alnum:]' \
        | tr '[:upper:]' '[:lower:]')"
    printf '%s.%s%s\n' "${name%%.*}" "${codeset}" "${modifier}"
}

# The LANG a locale.conf sets, taken from the file rather than assumed. Read by
# the locales stage, by the rootfs stage's check that the image's default locale
# was actually compiled, and by the container image, which has to name it in the
# environment because a container command never reads a login shell's profile.
locale_conf_lang() {
    awk -F= '$1 == "LANG" { gsub(/"/, "", $2); print $2 }' "$1" | sed -n '$p'
}

target_configure_env() {
    export CC="${TARGET}-gcc"
    export CXX="${TARGET}-g++"
    export AR="${TARGET}-ar"
    export AS="${TARGET}-as"
    export LD="${TARGET}-ld"
    export NM="${TARGET}-nm"
    export RANLIB="${TARGET}-ranlib"
    export READELF="${TARGET}-readelf"
    export STRIP="${TARGET}-strip"
}

validate_dedicated_directory WORK_DIR "${WORK_DIR}"
validate_dedicated_directory DOWNLOAD_DIR "${DOWNLOAD_DIR}"
validate_dedicated_directory ARTIFACT_DIR "${ARTIFACT_DIR}"
# Not created here: only 'make publish-repo' writes to it, and it prunes what it
# finds there, so it must be a directory nothing else owns.
validate_dedicated_directory DIST_DIR "${DIST_DIR}"
init_directories

# shellcheck source=stage.sh
source "${PROJECT_ROOT}/scripts/lib/stage.sh"
# shellcheck source=package.sh
source "${PROJECT_ROOT}/scripts/lib/package.sh"
# shellcheck source=license.sh
source "${PROJECT_ROOT}/scripts/lib/license.sh"
