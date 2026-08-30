#!/usr/bin/env bash
#
# What a stage is, and whether it has to run again.
#
# This file is the machinery that answers "should this stage be rebuilt", and
# it is deliberately separate from the code that does the building. The
# separation is not tidiness: scripts/lib/common.sh is hashed into every stage
# key, because a change to the compiler flags or the source preparation in it
# really can change every binary in the distribution. This file is not hashed,
# and must not be, because everything it does is already visible in the answer
# it produces - a stage key is a digest of the text stage_inputs prints, so a
# change to what goes into that text moves the key by itself, and a change that
# does not move it correctly rebuilds nothing. Hashing this file as well would
# mean that touching the machinery which decides what to rebuild rebuilt the
# whole distribution, every time.
#
# It is sourced by scripts/lib/common.sh, and nothing sources it directly.

# ------------------------------------------------------------ stage identity
#
# A stamp used to record only that a stage had run once, which says nothing
# about *what* it built. A bumped source version, an edited recipe, a new patch
# or a rebuilt toolchain all left the stamp where it was, so "make openssh"
# would skip a stage whose output was the previous release - and the package
# writer, which takes its version from the current lock rather than from the
# tree, would then label those old bytes with the new version.
#
# A stamp now holds a key over everything the stage's result depends on, and a
# stage is skipped only when the key it would build under is the key recorded
# beside its result. Two kinds of input go into it, gathered two different ways:
#
#   * The repository files a stage names - its own script, the shared build
#     libraries, the build configuration, patches it applies, local sources it
#     compiles, configuration and overlays it reads - are found by scanning the
#     script for literal "${PROJECT_ROOT}/..." paths. A path that is used
#     cannot be forgotten the way a hand-written declaration can, which is what
#     retired the eight bespoke invalidate_stale_* timestamp checks that used
#     to stand in for this.
#
#   * The pinned tarballs are *observed* rather than guessed: lock_record()
#     above appends every name it is asked for to the running stage's
#     dependency file, which is kept beside the stamp. Bash names none of its
#     fifteen patches literally and GnuPG names none of its six libraries, so a
#     scanner would miss every one of them.
#
# Package dependencies are inputs too. Their recorded stage keys are folded
# into a consumer's key, so rebuilding OpenSSL changes curl even when curl's
# source and recipe have not moved. The trailing stamp lists on
# run_rootfs_package_stage are the graph's non-package edges as well as a
# second, explicit record that scripts/lint.sh can audit against staged ELF
# NEEDED entries. The dependency every target stage shares is the cross
# toolchain: stages 01 to 07 are hashed into every later stage, so a GCC or
# glibc bump rebuilds the distribution instead of leaving eighty stamps that
# claim to be current.

# Stages are grouped by what they are rather than laid out in one numbered
# sequence, and a stage's name is its path below this directory without the
# suffix: toolchain/06-glibc, packages/openssh, image/11-initramfs. The name is
# therefore the whole of what identifies a stage - the file that produces it,
# the stamp that records it, and the argument "make stage-key" takes.
#
# Only two of the groups number their stages, because only two of them have an
# order at all. The cross toolchain is a bootstrap: binutils, then a compiler
# that cannot yet link, then the headers, and so on to the compiler that builds
# the distribution, and 01 to 07 are that sequence. In image/, 10-rootfs
# assembles the tree that 11-initramfs wraps. Everything under packages/ and
# host/ is ordered by what it needs rather than by where it sits in a list, and
# that order is written once, in the dependency functions of scripts/build.sh.
readonly STAGES_DIR="${PROJECT_ROOT}/scripts/stages"

stage_script() {
    printf '%s/%s.sh\n' "${STAGES_DIR}" "$1"
}

# The stages that produce the cross toolchain. Their own keys must not contain
# the toolchain digest, which is made out of them.
readonly TOOLCHAIN_STAGES=(toolchain/01-binutils toolchain/02-gcc-bootstrap
    toolchain/03-linux-headers toolchain/04-glibc-bootstrap toolchain/05-libgcc
    toolchain/06-glibc toolchain/07-gcc-final)

# Where lock_record() writes while a stage is running, and nowhere else: it is
# exported by stage_execute() for the stage's own process and cleared before
# any key is computed, so building a key never counts as using a source.
STAGE_DEPS_FILE="${STAGE_DEPS_FILE:-}"
# Which stage that file belongs to, exported beside it. A stage that describes
# what it is producing has to be able to ask for its own key before it has one;
# this is what lets stage_recorded_sources tell "the stage running now" from
# every other stage, whose record is complete and beside its stamp.
STAGE_RUNNING_NAME="${STAGE_RUNNING_NAME:-}"
# Both are the same for every stage in a run and are hashed once rather than
# ninety times.
STAGE_SHARED_DIGEST=""
STAGE_TOOLCHAIN_DIGEST=""

hash_file() {
    if [[ -f "$1" ]]; then
        sha256sum -- "$1" | cut -c1-64
    else
        printf 'absent\n'
    fi
}

# The content of a path, whether it names one file or a whole tree. Modes and
# symbolic link targets count: a build script that lost its execute bit is a
# different input from the same bytes that still have it.
#
# What must not count is where the file itself is. sha256sum prints the name
# beside the digest, so hashing its whole line made a file's identity depend on
# the pathname it was reached by - two checkouts of one commit at different
# paths disagreed about every stage, and a file that moved rebuilt on the
# strength of the move alone. Only the digest is taken, as hash_file() already
# does. The directory branch below keeps its names because they are relative to
# the tree being hashed: there, a renamed file really is a changed tree.
hash_path() {
    local path="$1"
    if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        printf 'absent\n'
    elif [[ -L "${path}" ]]; then
        printf 'link %s %s\n' "$(stat -c '%a' -- "${path}")" "$(readlink -- "${path}")" \
            | sha256sum | cut -c1-64
    elif [[ ! -d "${path}" ]]; then
        {
            printf 'file %s\n' "$(stat -c '%a' -- "${path}")"
            sha256sum -- "${path}" | cut -c1-64
        } | sha256sum | cut -c1-64
    else
        {
            (cd "${path}" && find . -mindepth 1 -printf '%y %m %P %l\n' \
                | LC_ALL=C sort)
            (cd "${path}" && find . -mindepth 1 -type f -printf '%P\0' \
                | LC_ALL=C sort -z | xargs -0 -r sha256sum --)
        } | sha256sum | cut -c1-64
    fi
}

# The code every stage is built by, and nothing else.
#
# This is the widest input there is: a change here rebuilds the distribution.
# That is right for what it names - the compiler flags in target_configure_env,
# the source preparation every recipe calls, the manifest and merge rules that
# decide what a stage leaves in the sysroot, the licence copier, and the
# build-wide settings - because each of those really can change every binary.
#
# It is not right for anything else, and two things used to be in here that do
# not belong.
#
# scripts/build.sh was one. The driver is a dispatcher: it says which stage
# builds which package and in what order, and one line per package. Adding a
# package means editing it, so a new package rebuilt all eighty-eight of the
# old ones - and none of that is an input to how anything is compiled. What the
# driver actually decides is already in a stage's key by name: the package it
# produces is an argument, its dependencies appear as "dependency <stage>
# <key>" lines, and the rootfs carries every component stage as a dependency,
# so a stage appearing or disappearing moves the key of the stage that
# assembles the image. What is deliberately not covered is reordering two
# stages that do not declare a dependency on each other; this build trusts
# declared dependencies, and an undeclared one was never covered by hashing the
# driver either.
#
# scripts/lib/stage.sh is the other, and it is not hashed for a stronger
# reason: everything it does is already visible. A stage key is a digest of the
# text stage_inputs prints, so a change to what goes into that text changes the
# key by itself, and a change that does not - a comment, a refactor, a faster
# way to reach the same answer - correctly changes nothing. Hashing the file as
# well would rebuild the distribution every time the machinery that decides
# what to rebuild was touched.
stage_shared_digest() {
    if [[ -z "${STAGE_SHARED_DIGEST}" ]]; then
        STAGE_SHARED_DIGEST="$({
            hash_file "${PROJECT_ROOT}/scripts/lib/common.sh"
            hash_file "${PROJECT_ROOT}/scripts/lib/package.sh"
            hash_file "${PROJECT_ROOT}/scripts/lib/license.sh"
            hash_file "${PROJECT_ROOT}/config/build.conf"
        } | sha256sum | cut -c1-64)"
    fi
    printf '%s\n' "${STAGE_SHARED_DIGEST}"
}

# Both digests, computed once in the shell that is about to ask for many keys.
#
# They are memoized in a variable, and every caller asks for a key through a
# command substitution - which is a subshell, which gets a copy of the memo and
# takes it away again when it exits. Warmed here, in the process that will fork
# those subshells, the copies arrive warm. Left cold, every single key
# recomputes all seven toolchain stage keys: "make packages" spent forty-five of
# its fifty seconds doing exactly that, three times per package, for an answer
# that never changed.
#
# The toolchain digest is only stable once the toolchain stamps are settled, so
# a driver that builds the toolchain warms it after doing so, not before. See
# toolchain() in scripts/build.sh, and stage_execute, which drops it again when
# a toolchain stage has just rewritten one of those stamps.
preheat_stage_digests() {
    stage_shared_digest > /dev/null
    stage_toolchain_digest > /dev/null
    load_stage_dispatch
}

stage_is_toolchain() {
    local candidate
    for candidate in "${TOOLCHAIN_STAGES[@]}"; do
        [[ "${candidate}" == "$1" ]] && return 0
    done
    return 1
}

stage_toolchain_digest() {
    local stage
    if [[ -z "${STAGE_TOOLCHAIN_DIGEST}" ]]; then
        STAGE_TOOLCHAIN_DIGEST="$(
            for stage in "${TOOLCHAIN_STAGES[@]}"; do
                stage_inputs "${stage}" "$(stage_script "${stage}")" -
                # The expected inputs alone cannot distinguish a complete
                # toolchain from one whose same-input rebuild failed after
                # changing its output and removing its stamp.
                printf 'recorded %s %s\n' "${stage}" \
                    "$(recorded_stage_key "${stage}")"
            done | sha256sum | cut -c1-64
        )"
    fi
    printf '%s\n' "${STAGE_TOOLCHAIN_DIGEST}"
}

# The pinned tarballs a stage was seen to use on its last successful run - or,
# for the stage running now, the ones it has asked for so far.
#
# The distinction is not cosmetic. stage_execute replaces the record beside the
# stamp only after the stage returns, so while a stage runs that file still
# describes the *previous* run, and on a build from scratch there is no file at
# all. Every key computed for a stage from outside it is therefore right, and
# the one case where a stage asks for its own key - image/10-rootfs, stamping an
# identity into the sowa-base and sowa-release it assembles - read a record that
# was not its own. On a clean build it predicted a stage that had used nothing,
# the repository computed the same identity afterwards over 102 pinned sources,
# and every fresh installation opened with two packages to upgrade that were
# byte for byte what it already had.
#
# What the running stage has asked for so far is exactly what the driver is
# about to record, provided the stage does not reach for a new tarball
# afterwards. pkg_build_id resolves a package's metadata before it asks, so a
# package's own lock rows are in; scripts/package.sh checks the answer against
# the image before publishing anything, so a stage that grows a later source
# fails the build rather than the installation.
stage_recorded_sources() {
    local name="$1"
    if [[ -n "${STAGE_DEPS_FILE}" && "${name}" == "${STAGE_RUNNING_NAME}" ]]; then
        [[ -f "${STAGE_DEPS_FILE}" ]] && LC_ALL=C sort -u "${STAGE_DEPS_FILE}"
        return 0
    fi
    local file="${STAMP_DIR}/${name}.sources"
    [[ -f "${file}" ]] && cat "${file}"
    return 0
}

# The repository paths a stage names for itself. A trailing "/." - the way a
# tree is copied - names the same tree as the directory does.
# shellcheck disable=SC2016 # the literal "${PROJECT_ROOT}" is what is searched for.
stage_repository_inputs() {
    # A stage that names nothing is the common case, and grep reports that as
    # a failure; under errexit and pipefail an unguarded no-match would end the
    # build rather than the pipeline.
    { grep -o '\${PROJECT_ROOT}/[A-Za-z0-9._/+-]*' "$1" 2> /dev/null || true; } \
        | sed -e 's|^\${PROJECT_ROOT}/||' -e 's|/\.$||' -e 's|/$||' \
        | LC_ALL=C sort -u
}

# The identity of a host tool used to create the cross toolchain. A lock row
# says which GCC Sowa is building, but the compiler that bootstraps it is an
# input too. Hashing both its program and version catches a host compiler
# replacement even when its pathname stays /usr/bin/gcc.
host_tool_identity() {
    local command="$1"
    local path
    path="$(command -v "${command}" 2> /dev/null || true)"
    if [[ -z "${path}" ]]; then
        printf '%s absent\n' "${command}"
        return 0
    fi
    printf '%s %s %s %s\n' "${command}" "${path}" "$(hash_path "${path}")" \
        "$("${command}" --version 2> /dev/null | sed -n '1p')"
}

# Values intentionally accepted from the environment and capable of changing
# build output. Shell escaping keeps unset, empty and whitespace-bearing values
# distinct in the key.
stage_environment_inputs() {
    local stage="$1"
    local variable
    for variable in CC CXX CPPFLAGS CFLAGS CXXFLAGS LDFLAGS AR AS LD NM \
        RANLIB STRIP PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR \
        GOFLAGS CGO_CFLAGS CGO_CXXFLAGS CGO_LDFLAGS RUSTFLAGS; do
        if [[ -v "${variable}" ]]; then
            printf 'environment %s set %q\n' "${variable}" "${!variable}"
        else
            printf 'environment %s unset\n' "${variable}"
        fi
    done

    [[ "${stage}" == image/disk-image ]] || return 0
    for variable in SOWA_IMAGE_SEED SOWA_IMAGE_ESP_SIZE_MB SOWA_IMAGE_SIZE_MB \
        SOWA_IMAGE_HOSTNAME SOWA_IMAGE_SSH_KEY; do
        if [[ -v "${variable}" ]]; then
            printf 'environment %s set %q\n' "${variable}" "${!variable}"
        else
            printf 'environment %s unset\n' "${variable}"
        fi
    done

    # The disk-image stage accepts a password, but `make stage-key` must not
    # print it. The digest still makes a changed password a changed input.
    if [[ -v SOWA_IMAGE_ROOT_PASSWORD ]]; then
        printf 'environment SOWA_IMAGE_ROOT_PASSWORD set sha256:%s\n' \
            "$(printf '%s' "${SOWA_IMAGE_ROOT_PASSWORD}" | sha256sum | cut -c1-64)"
    else
        printf 'environment SOWA_IMAGE_ROOT_PASSWORD unset\n'
    fi

    # The file's bytes, not only its pathname, become authorized_keys.
    if [[ -v SOWA_IMAGE_SSH_KEY_FILE ]]; then
        printf 'environment SOWA_IMAGE_SSH_KEY_FILE set %q %s\n' \
            "${SOWA_IMAGE_SSH_KEY_FILE}" \
            "$(hash_path "${SOWA_IMAGE_SSH_KEY_FILE}")"
    else
        printf 'environment SOWA_IMAGE_SSH_KEY_FILE unset\n'
    fi
}

# Which stage builds which package, read out of the driver once.
#
# scripts/build.sh names every component stage and the package it produces, and
# four different questions are asked of that mapping - a stage's key, a
# package's build identity, the release check, and "make stage-key". Each used
# to run its own awk over the whole driver, and one of them used a pattern that
# could not match a stage name at all, because a stage name has a "/" in it and
# the character class did not. That parser is now written once and read into a
# table, which is both the same answer everywhere and one process instead of
# one per question.
#
# A stage name is its path under scripts/stages without the suffix, so the
# group is what identifies one here: every call names <group>/<stage>, and
# nothing else in that column does.
declare -A STAGE_DISPATCH_PACKAGE=()
declare -A STAGE_DISPATCH_STAGE=()
STAGE_DISPATCH_LOADED=0

load_stage_dispatch() {
    local stage package
    ((STAGE_DISPATCH_LOADED == 0)) || return 0
    while read -r stage package; do
        STAGE_DISPATCH_PACKAGE["${stage}"]="${package}"
        [[ "${package}" == - ]] || STAGE_DISPATCH_STAGE["${package}"]="${stage}"
    done < <(awk '
        $1 == "run_rootfs_package_stage" && $2 ~ /^[a-z]+\// { print $2, $3 }
    ' "${DRIVER_FILE}")
    STAGE_DISPATCH_LOADED=1
}

# The stage that produces a package, if it has one.
package_stage_name() {
    local stage
    load_stage_dispatch
    stage="${STAGE_DISPATCH_STAGE[$1]:-}"
    [[ -n "${stage}" ]] || return 0
    printf '%s\n' "${stage}"
}

# The package a stage produces, or "-" for one that produces none. The inverse
# of package_stage_name, from the same table, so the two cannot disagree.
stage_package_name() {
    load_stage_dispatch
    printf '%s\n' "${STAGE_DISPATCH_PACKAGE[$1]:--}"
}

all_component_stage_names() {
    load_stage_dispatch
    local stage
    for stage in "${!STAGE_DISPATCH_PACKAGE[@]}"; do
        printf '%s\n' "${stage}"
    done | LC_ALL=C sort -u
}

# Build/link dependencies are stage inputs, not only reasons to delete a stamp
# after the fact. Runtime package dependencies cover the shared libraries and
# build tools in this tree. The few non-package joins are named explicitly.
stage_dependency_names() {
    local name="$1"
    local package="$2"
    local dependency stage

    if [[ "${package}" != - ]]; then
        while IFS= read -r dependency; do
            [[ -n "${dependency}" && "${dependency}" != - ]] || continue
            stage="$(package_stage_name "${dependency}")"
            [[ -n "${stage}" ]] && printf '%s\n' "${stage}"
        done < <(package_depends "${package}" | tr ',' '\n')
    fi

    case "${name}" in
        # The cross toolchain is a build graph of its own. Its stages are
        # excluded from the combined toolchain digest to avoid recursion, so
        # their direct predecessors have to be named here explicitly. Without
        # these edges, a rebuilt cross-binutils could leave GCC bootstrap and
        # every later toolchain stage falsely current.
        toolchain/02-gcc-bootstrap) printf 'toolchain/01-binutils\n' ;;
        toolchain/04-glibc-bootstrap)
            printf 'toolchain/01-binutils\ntoolchain/02-gcc-bootstrap\n'
            printf 'toolchain/03-linux-headers\n'
            ;;
        toolchain/05-libgcc)
            printf 'toolchain/02-gcc-bootstrap\ntoolchain/04-glibc-bootstrap\n'
            ;;
        toolchain/06-glibc)
            printf 'toolchain/04-glibc-bootstrap\ntoolchain/05-libgcc\n'
            ;;
        toolchain/07-gcc-final)
            printf 'toolchain/01-binutils\ntoolchain/06-glibc\n'
            ;;
        packages/python) printf 'host/python\n' ;;
        image/10-rootfs)
            all_component_stage_names
            printf 'host/python\n'
            ;;
        image/11-initramfs) printf 'image/kernel\nimage/10-rootfs\n' ;;
        image/disk-image | image/rootfs-tarball) printf 'image/11-initramfs\n' ;;
    esac
}

recorded_stage_key() {
    local stamp="${STAMP_DIR}/$1.done"
    if [[ -s "${stamp}" ]]; then
        cat "${stamp}"
    else
        printf 'absent\n'
    fi
}

# Package metadata has three different scopes, and "does this stage produce a
# package?" cannot distinguish them. Component stages consume one package's
# row and installed metadata. The rootfs consumes the whole catalogue when it
# assigns ownership and writes the image database. Toolchain, kernel, host-tool
# and payload-only artifact stages consume none of it. Treating that last group
# as catalogue consumers made an unrelated package release bump rebuild the
# cross toolchain and, through its digest, every package in the distribution.
stage_metadata_packages() {
    local name="$1"
    local package="$2"

    if [[ "${package}" != - ]]; then
        printf '%s\n' "${package}"
        return 0
    fi

    case "${name}" in
        # This stage adds the kernel after rootfs ownership was assigned and
        # writes Linux's package entry into the image.
        image/11-initramfs) printf 'linux\n' ;;
    esac
}

stage_catalog_metadata() {
    local name="$1"

    case "${name}" in
        image/10-rootfs)
            printf 'packages %s\n' "$(hash_file "${PACKAGES_CONF}")"
            printf 'licenses %s\n' "$(hash_file "${LICENSES_CONF}")"
            ;;
        image/iso)
            # The ISO is regenerated every time, but stage-key should still
            # describe the package-version list written into its volume.
            printf 'packages %s\n' "$(hash_file "${PACKAGES_CONF}")"
            ;;
    esac
}

# Everything a stage's identity is made of, as text rather than as a hash, so
# that "make stage-key NAME=..." can show which line changed when a stage
# rebuilds and nobody expected it to. A row the tables no longer have is
# printed as absent instead of stopping the build: a removed package or source
# is a reason to rerun the stage, not a reason to refuse to look at it.
stage_inputs() {
    local name="$1"
    local script="$2"
    local package="${3:--}"
    local wanted relative metadata_package dependency

    printf 'stage %s\n' "${name}"
    printf 'target %s %s %s %s %s\n' \
        "${TARGET}" "${KARCH}" "${KERNEL_IMAGE}" "${PKG_ARCH}" "${GOARCH}"
    printf 'distro %s %s\n' "${DISTRO_NAME}" "${DISTRO_VERSION}"
    printf 'epoch %s\n' "${SOURCE_DATE_EPOCH}"
    printf 'jobs %s\n' "${JOBS}"
    printf 'kernel-abi %s\n' "${GLIBC_MIN_KERNEL}"
    printf 'artifact %s %s %s %s\n' \
        "${ARTIFACT_ARCH}" "${ISO_GFXMODE}" "${SFS_COMPRESSOR}" "${SFS_BLOCK_SIZE}"
    stage_environment_inputs "${name}"
    printf 'shared %s\n' "$(stage_shared_digest)"
    printf 'script %s\n' "$(hash_path "${script}")"
    # The stage's own line in the driver, which is the part of scripts/build.sh
    # that is about this stage: which package it produces, or that it produces
    # none. See stage_shared_digest for why the rest of that file is not here.
    printf 'driver %s %s\n' "${name}" "$(stage_package_name "${name}")"

    if stage_is_toolchain "${name}"; then
        host_tool_identity gcc
        host_tool_identity g++
        host_tool_identity as
        host_tool_identity ld
    fi

    # One lock row carries the version, the archive, its URL and its SHA-256,
    # so a single line answers both "which release" and "which bytes".
    while IFS= read -r wanted; do
        [[ -n "${wanted}" ]] || continue
        printf 'source %s\n' \
            "$(lock_record "${wanted}" 2> /dev/null || printf '%s|absent' "${wanted}")"
    done < <(stage_recorded_sources "${name}")

    while IFS= read -r relative; do
        [[ -n "${relative}" ]] || continue
        printf 'path %s %s\n' "${relative}" \
            "$(hash_path "${PROJECT_ROOT}/${relative}")"
    done < <(stage_repository_inputs "${script}")

    # Only catalogue consumers hash whole tables. A component stage carries
    # the metadata of the one package it produces; most stages that produce no
    # package consume no package metadata at all.
    stage_catalog_metadata "${name}"
    while IFS= read -r metadata_package; do
        [[ -n "${metadata_package}" ]] || continue
        printf 'package %s\n' \
            "$(package_record "${metadata_package}" 2> /dev/null \
                || printf '%s|absent' "${metadata_package}")"
        printf 'license %s\n' \
            "$(license_record "${metadata_package}" 2> /dev/null \
                || printf '%s|absent' "${metadata_package}")"
        printf 'hooks %s\n' \
            "$(hash_file "${PROJECT_ROOT}/config/hooks/${metadata_package}.hooks")"
        printf 'message %s\n' \
            "$(hash_file "${PROJECT_ROOT}/config/messages/${metadata_package}.txt")"
    done < <(stage_metadata_packages "${name}" "${package}")

    while IFS= read -r dependency; do
        [[ -n "${dependency}" ]] || continue
        printf 'dependency %s %s\n' "${dependency}" \
            "$(recorded_stage_key "${dependency}")"
    done < <(stage_dependency_names "${name}" "${package}" | LC_ALL=C sort -u)

    stage_is_toolchain "${name}" \
        || printf 'toolchain %s\n' "$(stage_toolchain_digest)"
}

stage_key() {
    stage_inputs "$@" | sha256sum | cut -c1-64
}

# True when the result beside the stamp was built under the key that would be
# built under now.
stage_up_to_date() {
    local name="$1"
    local stamp="${STAMP_DIR}/${name}.done"
    [[ -f "${stamp}" ]] || return 1
    [[ "$(cat "${stamp}")" == "$(stage_key "$@")" ]]
}

# Runs a stage, records the sources it turned out to use, and only then writes
# the key. A stage that fails leaves no stamp, so nothing downstream can mistake
# a half-finished tree for a complete one.
stage_execute() {
    local name="$1"
    local script="$2"
    local package="$3"
    shift 3
    # A stage name carries its group, so its stamp lives in a directory of the
    # same name and the temporary files have to be hidden beside the stamp
    # rather than in front of the group: ".${name}" would name a directory that
    # does not exist.
    local directory="${STAMP_DIR}/${name%/*}"
    local base="${name##*/}"
    local deps="${directory}/.${base}.deps.$$"
    local sources_tmp="${directory}/.${base}.sources.$$"
    local stamp="${STAMP_DIR}/${name}.done"
    local stamp_tmp="${directory}/.${base}.done.$$"
    local status

    mkdir -p "${directory}"
    begin_stage "${name}"
    # A failed rerun may already have replaced or removed part of the old
    # result. Its old key must stop being authoritative before work begins.
    rm -f "${stamp}" "${stamp_tmp}" "${sources_tmp}"
    : > "${deps}"
    export STAGE_DEPS_FILE="${deps}"
    export STAGE_RUNNING_NAME="${name}"
    if "$@"; then
        status=0
    else
        status=$?
    fi
    STAGE_DEPS_FILE=""
    STAGE_RUNNING_NAME=""
    export STAGE_DEPS_FILE STAGE_RUNNING_NAME
    if ((status != 0)); then
        rm -f "${deps}" "${sources_tmp}" "${stamp_tmp}"
        return "${status}"
    fi
    LC_ALL=C sort -u "${deps}" > "${sources_tmp}"
    rm -f "${deps}"
    mv "${sources_tmp}" "${STAMP_DIR}/${name}.sources"
    stage_key "${name}" "${script}" "${package}" > "${stamp_tmp}"
    mv "${stamp_tmp}" "${stamp}"
    # This stage's stamp is an input to the combined toolchain digest, so a
    # driver holding a warm copy of that digest is now holding the one from
    # before this stage ran. Dropping it here is what makes preheating safe in a
    # process that also builds.
    if stage_is_toolchain "${name}"; then
        STAGE_TOOLCHAIN_DIGEST=""
    fi
}

# Zero-byte stamps are the presence-only records used before stage keys existed.
# They contain no evidence about the sysroot beside them, including no package
# merge manifests from which obsolete paths could be reconciled. Rebuilding on
# top would preserve exactly the historical residue GEN-001 is meant to remove,
# so this one migration must begin with an empty work tree.
require_keyed_stage_state() {
    local legacy
    [[ ! -f "${PKG_MERGED_DIR}/.dirty" ]] \
        || die "an earlier sysroot merge was interrupted; run 'make clean' before rebuilding"
    legacy="$(find "${STAMP_DIR}" -type f -name '*.done' -size 0c \
        -print -quit)"
    [[ -z "${legacy}" ]] \
        || die "legacy unkeyed stage stamps are present; run 'make clean' once before rebuilding"
}

# Runs a stage that builds no package of its own. The script is found from the
# stage's name, and is also what the key is computed from.
run_stage() {
    local name="$1"
    local script
    script="$(stage_script "${name}")"
    if stage_up_to_date "${name}" "${script}" -; then
        log "skip ${name} (already complete)"
        return 0
    fi
    # Said out loud, because a stage rebuilding when nobody asked for it is
    # exactly the moment somebody wants to know why. "make stage-key STAGE=..."
    # is the rest of the answer.
    if [[ -f "${STAMP_DIR}/${name}.done" ]]; then
        log "rerun ${name} (its inputs changed since it last ran)"
    fi
    stage_execute "${name}" "${script}" - "${script}"
}
