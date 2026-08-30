#!/usr/bin/env bash
#
# Exercises the parts of the build system whose failure mode is silence.
#
# The three things checked here were all audit findings, and all three share a
# shape: nothing fails, the build succeeds, and what comes out is wrong.
#
#   * A stage stamp that does not answer for its inputs skips a stage whose
#     output belongs to the previous release, and the package writer then
#     labels those bytes with the current version.
#   * A sysroot that is never reconciled keeps files a package has stopped
#     installing, so an incremental build ships what a clean build would not.
#   * A package whose identity is only its version makes a rebuild invisible to
#     every machine that already has that version.
#
# None of that can be seen by reading a successful build log, so it is asserted
# instead - against a scratch work directory rather than the real one, in a few
# seconds rather than in a few hours.

set -Eeuo pipefail

SELFTEST_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
readonly SELFTEST_ROOT

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sowa-selftest.XXXXXX")"
readonly SCRATCH
# shellcheck disable=SC2329 # run by the trap below.
cleanup() { rm -rf "${SCRATCH}"; }
trap cleanup EXIT

# A scratch work directory and scratch copies of the three tables. Several
# checks here are of the form "change an input, watch a key move", and none of
# them may be able to change the repository's own files to do it.
mkdir -p "${SCRATCH}/work" "${SCRATCH}/config"
cp "${SELFTEST_ROOT}/config/sources.lock" \
    "${SELFTEST_ROOT}/config/packages.conf" \
    "${SELFTEST_ROOT}/config/licenses.conf" "${SCRATCH}/config/"
# And a scratch copy of the driver, for the same reason: what adding a package
# to it does and does not invalidate is asserted below, and the real one may not
# be edited to find out.
cp "${SELFTEST_ROOT}/scripts/build.sh" "${SCRATCH}/config/driver.sh"
export WORK_DIR="${SCRATCH}/work"
export LOCK_FILE="${SCRATCH}/config/sources.lock"
export PACKAGES_CONF="${SCRATCH}/config/packages.conf"
export LICENSES_CONF="${SCRATCH}/config/licenses.conf"
export DRIVER_FILE="${SCRATCH}/config/driver.sh"
export SELFTEST_ROOT

# shellcheck source=lib/common.sh
source "${SELFTEST_ROOT}/scripts/lib/common.sh"
# shellcheck source=lib/archive.sh
source "${SELFTEST_ROOT}/scripts/lib/archive.sh"

failures=0
checking=""

checking() {
    checking="$1"
}

ok() {
    printf '  ok   %s\n' "$1"
}

bad() {
    printf '  FAIL %s: %s\n' "${checking}" "$1" >&2
    failures=$((failures + 1))
}

same() {
    if [[ "$2" == "$3" ]]; then
        ok "$1"
    else
        bad "$1 (expected '$3', got '$2')"
    fi
}

differs() {
    if [[ "$2" != "$3" ]]; then
        ok "$1"
    else
        bad "$1 (both were '$2')"
    fi
}

# Runs a test command and reports it, so that a check reads as one line and a
# failure names what was expected rather than which line of shell it was.
assert() {
    local description="$1"
    shift
    if "$@"; then
        ok "${description}"
    else
        bad "${description}"
    fi
}

refute() {
    local description="$1"
    shift
    if "$@"; then
        bad "${description}"
    else
        ok "${description}"
    fi
}

# Both are called through assert/refute's "$@", which shellcheck cannot see.
# shellcheck disable=SC2329
exists() { [[ -e "$1" ]]; }
# shellcheck disable=SC2329
is_directory() { [[ -d "$1" ]]; }
# shellcheck disable=SC2329
has_content() { [[ "$(cat "$1")" == "$2" ]]; }
# shellcheck disable=SC2329
contains_text() { [[ "$1" == *"$2"* ]]; }
# shellcheck disable=SC2329
has_key() { stage_key "$@" > /dev/null; }
# shellcheck disable=SC2329
trees_equal() { diff -qr -- "$1" "$2" > /dev/null; }

# ------------------------------------------------------------- stage identity

checking "stage keys"
printf '==> stage identity\n'

stage_script="${SCRATCH}/probe.sh"
cat > "${stage_script}" <<'PROBE'
#!/usr/bin/env bash
# A stand-in for a component stage: it names a pinned source and a file in the
# repository, which is what a real one does.
set -Eeuo pipefail
source "${SELFTEST_ROOT}/scripts/lib/common.sh"
source_version bash > /dev/null
PROBE
chmod 0755 "${stage_script}"

base="$(stage_key probe "${stage_script}" -)"
same "the same inputs give the same key" \
    "$(stage_key probe "${stage_script}" -)" "${base}"

printf '# an edit\n' >> "${stage_script}"
differs "an edited recipe changes the key" \
    "$(stage_key probe "${stage_script}" -)" "${base}"

mode_key="$(stage_key probe "${stage_script}" -)"
chmod 0644 "${stage_script}"
differs "a recipe mode change changes the key" \
    "$(stage_key probe "${stage_script}" -)" "${mode_key}"
chmod 0755 "${stage_script}"

environment_key="$(stage_key image/disk-image "${stage_script}" -)"
export SOWA_IMAGE_SIZE_MB=4096
differs "an allowlisted build option changes the key" \
    "$(stage_key image/disk-image "${stage_script}" -)" "${environment_key}"
unset SOWA_IMAGE_SIZE_MB

# A stage is only as current as the sources it was seen to use, which is what
# the recorded dependency list is for. This is the OpenSSH case from the audit:
# the lock says one release, the tree holds another, and the stamp used to
# claim the stage was complete either way.
printf 'openssh\n' > "${STAMP_DIR}/probe.sources"
with_openssh="$(stage_key probe "${stage_script}" -)"
lock_backup="${SCRATCH}/sources.lock.orig"
cp "${LOCK_FILE}" "${lock_backup}"
sed -i 's/^openssh|[^|]*|/openssh|99.9p9|/' "${LOCK_FILE}"
bumped="$(stage_key probe "${stage_script}" -)"
cp "${lock_backup}" "${LOCK_FILE}"
differs "a bumped source version changes the key" "${bumped}" "${with_openssh}"
same "restoring the lock restores the key" \
    "$(stage_key probe "${stage_script}" -)" "${with_openssh}"

# Package metadata belongs only to stages that consume it. In particular, a
# release bump must change that package and the rootfs catalogue without
# changing the cross toolchain or an unrelated package. Otherwise the combined
# toolchain digest fans a metadata-only edit out into a full distribution
# rebuild.
packages_backup="${SCRATCH}/packages.conf.orig"
cp "${PACKAGES_CONF}" "${packages_backup}"
# Drop the cache on both sides so this test exercises the inputs rather than
# merely reading the first digest twice.
# shellcheck disable=SC2034 # consumed by stage_toolchain_digest in common.sh.
STAGE_TOOLCHAIN_DIGEST=""
metadata_toolchain_before="$(stage_toolchain_digest)"
metadata_bash_before="$(stage_key packages/bash \
    "${SELFTEST_ROOT}/scripts/stages/packages/bash.sh" bash)"
metadata_docker_before="$(stage_key packages/docker \
    "${SELFTEST_ROOT}/scripts/stages/packages/docker.sh" docker)"
metadata_rootfs_before="$(stage_key image/10-rootfs \
    "${SELFTEST_ROOT}/scripts/stages/image/10-rootfs.sh" -)"
sed -i 's/^docker|docker|[0-9]*|/docker|docker|99|/' "${PACKAGES_CONF}"
# shellcheck disable=SC2034 # consumed by stage_toolchain_digest in common.sh.
STAGE_TOOLCHAIN_DIGEST=""
same "a package release bump leaves the toolchain identity alone" \
    "$(stage_toolchain_digest)" "${metadata_toolchain_before}"
same "a package release bump leaves unrelated package stages alone" \
    "$(stage_key packages/bash "${SELFTEST_ROOT}/scripts/stages/packages/bash.sh" bash)" \
    "${metadata_bash_before}"
differs "a package release bump changes its own stage key" \
    "$(stage_key packages/docker "${SELFTEST_ROOT}/scripts/stages/packages/docker.sh" docker)" \
    "${metadata_docker_before}"
differs "a package release bump changes the catalogue consumer's key" \
    "$(stage_key image/10-rootfs "${SELFTEST_ROOT}/scripts/stages/image/10-rootfs.sh" -)" \
    "${metadata_rootfs_before}"
cp "${packages_backup}" "${PACKAGES_CONF}"
# Recompute subsequent identities from the restored catalogue.
# shellcheck disable=SC2034 # consumed by stage_toolchain_digest in common.sh.
STAGE_TOOLCHAIN_DIGEST=""

# A stage that names no repository path at all must still produce a key rather
# than end the build on grep's report that it found nothing.
cat > "${stage_script}" <<'PROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
PROBE
chmod 0755 "${stage_script}"
rm -f "${STAMP_DIR}/probe.sources"
assert "a stage that names no repository path still has a key" \
    has_key probe "${stage_script}" -

# The observed dependency list, which is what makes the loops work: Bash names
# none of its fifteen patches and GnuPG none of its six libraries.
cat > "${stage_script}" <<'PROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
source "${SELFTEST_ROOT}/scripts/lib/common.sh"
for patch_name in bash53-001 bash53-002; do
    source_version "${patch_name}" > /dev/null
done
PROBE
chmod 0755 "${stage_script}"
stage_execute probe "${stage_script}" - "${stage_script}"
recorded="$(tr '\n' ' ' < "${STAMP_DIR}/probe.sources")"
same "a loop's sources are recorded, not guessed" \
    "${recorded}" "bash53-001 bash53-002 "
assert "a stage that just ran is up to date" \
    stage_up_to_date probe "${stage_script}" -
sed -i 's/^bash53-001|[^|]*|/bash53-001|9.9.9|/' "${LOCK_FILE}"
refute "bumping a source the stage used makes it stale" \
    stage_up_to_date probe "${stage_script}" -
cp "${lock_backup}" "${LOCK_FILE}"

# The toolchain is every other stage's dependency, and the one that is in the
# key rather than in a hand-written invalidation list.
toolchain_before="$(stage_toolchain_digest)"
sed -i 's/^gcc|[^|]*|/gcc|99.1.0|/' "${LOCK_FILE}"
printf 'gcc\n' > "${STAMP_DIR}/toolchain/07-gcc-final.sources"
# The digest is cached for the length of a run, so the cache is dropped before
# it is asked again. shellcheck cannot see that lib/common.sh reads these.
# shellcheck disable=SC2034
STAGE_TOOLCHAIN_DIGEST=""
differs "a toolchain bump changes the toolchain digest" \
    "$(stage_toolchain_digest)" "${toolchain_before}"
cp "${lock_backup}" "${LOCK_FILE}"
rm -f "${STAMP_DIR}/toolchain/07-gcc-final.sources"
# Recompute subsequent identities from the restored inputs rather than keeping
# the deliberately changed digest in this shell's cache.
# shellcheck disable=SC2034
STAGE_TOOLCHAIN_DIGEST=""

# Toolchain stages cannot include the combined toolchain digest in their own
# keys (that would recurse), but they still consume one another's output. The
# direct edges in stage_dependency_names carry those identities instead.
printf '%064d\n' 1 > "${STAMP_DIR}/toolchain/01-binutils.done"
bootstrap_before="$(stage_key toolchain/02-gcc-bootstrap \
    "${SELFTEST_ROOT}/scripts/stages/toolchain/02-gcc-bootstrap.sh" -)"
printf '%064d\n' 2 > "${STAMP_DIR}/toolchain/01-binutils.done"
differs "a rebuilt toolchain provider changes its direct consumer's key" \
    "$(stage_key toolchain/02-gcc-bootstrap \
        "${SELFTEST_ROOT}/scripts/stages/toolchain/02-gcc-bootstrap.sh" -)" \
    "${bootstrap_before}"
rm -f "${STAMP_DIR}/toolchain/01-binutils.done"

# Dependency keys are part of a consumer's key. nano is a small representative:
# its package metadata says it depends on ncurses, whose builder is stage 11.
printf '%064d\n' 1 > "${STAMP_DIR}/packages/ncurses.done"
consumer_before="$(stage_key probe "${stage_script}" nano)"
printf '%064d\n' 2 > "${STAMP_DIR}/packages/ncurses.done"
differs "a provider's new stage key changes its consumer's key" \
    "$(stage_key probe "${stage_script}" nano)" "${consumer_before}"
rm -f "${STAMP_DIR}/packages/ncurses.done"

# A failed rerun may have changed its output, so the old stamp must disappear
# before the command starts and must not be restored on failure.
printf '%064d\n' 3 > "${STAMP_DIR}/failed.done"
cat > "${stage_script}" <<'PROBE'
#!/usr/bin/env bash
exit 7
PROBE
chmod 0755 "${stage_script}"
if stage_execute failed "${stage_script}" - "${stage_script}"; then
    bad "a failing stage unexpectedly succeeded"
fi
refute "a failed rerun leaves no authoritative stamp" \
    exists "${STAMP_DIR}/failed.done"

# shellcheck disable=SC2329
interrupted_merge_is_rejected() (
    printf 'probe\n' > "${PKG_MERGED_DIR}/.dirty"
    require_keyed_stage_state > /dev/null 2>&1
)
refute "an interrupted sysroot merge blocks further incremental builds" \
    interrupted_merge_is_rejected
rm -f "${PKG_MERGED_DIR}/.dirty"

# ---------------------------------------------------------- invalidation scope
#
# A keyed stamp is only worth having if it reruns what changed and nothing else,
# and two files used to defeat that completely.
#
# scripts/build.sh was hashed whole into every stage key. It holds one function
# and one dispatch line per package, so adding a package - the most ordinary
# thing anybody does to this repository - rebuilt all eighty-eight of the
# others, and so did a comment.
#
# The stage machinery was the other, because it lived in the file that is hashed
# into every key. Touching the code that decides what to rebuild rebuilt the
# distribution, which is why it is now scripts/lib/stage.sh and deliberately not
# hashed: a stage key is a digest of the text stage_inputs prints, so what that
# machinery does is already visible in the answer it gives.

checking "invalidation scope"
printf '==> invalidation scope\n'

# Every key here is taken in a subshell with the memoized tables dropped, so
# these assertions exercise the inputs rather than reading one cached digest
# twice.
# The reset variables are all consumed by the sourced build library.
# shellcheck disable=SC2329,SC2034
key_of() (
    STAGE_DISPATCH_LOADED=0
    STAGE_DISPATCH_PACKAGE=()
    STAGE_DISPATCH_STAGE=()
    STAGE_TOOLCHAIN_DIGEST=""
    stage_key "$@"
)

# The widest input there is, so what it covers is worth stating rather than
# assuming. These four are build code: a change in any of them really can change
# every binary in the distribution. Nothing else belongs here, and this fails if
# the driver or the stage machinery is ever put back.
# shellcheck disable=SC2329,SC2034
shared_digest_covers_the_build_code_only() (
    local expected
    expected="$({
        hash_file "${SELFTEST_ROOT}/scripts/lib/common.sh"
        hash_file "${SELFTEST_ROOT}/scripts/lib/package.sh"
        hash_file "${SELFTEST_ROOT}/scripts/lib/license.sh"
        hash_file "${SELFTEST_ROOT}/config/build.conf"
    } | sha256sum | cut -c1-64)"
    STAGE_SHARED_DIGEST=""
    [[ "$(stage_shared_digest)" == "${expected}" ]]
)
assert "the shared digest covers the build code and nothing else" \
    shared_digest_covers_the_build_code_only

# shellcheck disable=SC2329,SC2034
dispatch_table_answers_both_ways() (
    local stage package paired=0
    STAGE_DISPATCH_LOADED=0
    while IFS= read -r stage; do
        package="$(stage_package_name "${stage}")"
        # A handful of component stages produce no package of their own - the
        # two toolchain runtimes are built the same way and carried by others.
        [[ "${package}" != - ]] || continue
        [[ "$(package_stage_name "${package}")" == "${stage}" ]] || return 1
        paired=$((paired + 1))
    done < <(all_component_stage_names)
    ((paired > 1))
)
assert "every component stage and its package name each other" \
    dispatch_table_answers_both_ways

nano_script="${SELFTEST_ROOT}/scripts/stages/packages/nano.sh"
rootfs_script="${SELFTEST_ROOT}/scripts/stages/image/10-rootfs.sh"
driver_backup="${SCRATCH}/driver.orig"
cp "${DRIVER_FILE}" "${driver_backup}"

nano_key="$(key_of packages/nano "${nano_script}" nano)"
rootfs_key="$(key_of image/10-rootfs "${rootfs_script}" -)"

# What adding a package to the driver looks like: one more function, one more
# dispatch line.
{
    printf '\nprobe_package() {\n'
    printf '    toolchain\n'
    printf '    run_rootfs_package_stage packages/probe probe\n'
    printf '}\n'
} >> "${DRIVER_FILE}"
same "a package added to the driver leaves every other stage alone" \
    "$(key_of packages/nano "${nano_script}" nano)" "${nano_key}"
# The one stage it must reach: the rootfs carries every component stage as a
# dependency, because it is what assembles them into an image.
differs "a package added to the driver reaches the stage that assembles the image" \
    "$(key_of image/10-rootfs "${rootfs_script}" -)" "${rootfs_key}"
cp "${driver_backup}" "${DRIVER_FILE}"
same "removing it again restores the key" \
    "$(key_of packages/nano "${nano_script}" nano)" "${nano_key}"

printf '\n# a comment\n' >> "${DRIVER_FILE}"
same "a comment in the driver rebuilds nothing" \
    "$(key_of packages/nano "${nano_script}" nano)" "${nano_key}"
same "a comment in the driver does not reach the image either" \
    "$(key_of image/10-rootfs "${rootfs_script}" -)" "${rootfs_key}"
cp "${driver_backup}" "${DRIVER_FILE}"

# The part of the driver that is about this stage still is an input: which
# package a stage produces decides which metadata its key carries.
sed -i 's|run_rootfs_package_stage packages/nano nano|run_rootfs_package_stage packages/nano nano-two|' \
    "${DRIVER_FILE}"
differs "changing which package a stage builds changes that stage's key" \
    "$(key_of packages/nano "${nano_script}" nano)" "${nano_key}"
cp "${driver_backup}" "${DRIVER_FILE}"
same "and putting it back puts the key back" \
    "$(key_of packages/nano "${nano_script}" nano)" "${nano_key}"

# ----------------------------------------------------------- build traversal

checking "build traversal"
printf '==> build traversal\n'

# Load the driver's function definitions without its command dispatcher. This
# exercises the real memoization and dependency functions without consulting or
# changing the repository's build stamps.
build_functions="${SCRATCH}/build-functions.sh"
sed -n '/^declare -A VISITED_STAGE_KEYS=/,/^readonly GOAL=/p' \
    "${SELFTEST_ROOT}/scripts/build.sh" | sed '$d' > "${build_functions}"

# shellcheck disable=SC2329 # invoked through assert below.
driver_memoizes_stage_visits() (
    # shellcheck source=/dev/null
    source "${build_functions}"

    local calls=0
    local stamp="${STAMP_DIR}/memo-probe.done"
    # shellcheck disable=SC2329 # called by run_stage_once from the sourced driver.
    run_stage() {
        calls=$((calls + 1))
        printf '%064d\n' "${calls}" > "${stamp}"
    }

    rm -f "${stamp}"
    run_stage_once memo-probe
    run_stage_once memo-probe
    [[ "${calls}" == 1 ]] || return 1

    # Removing a consumer's stamp is how a rebuilt provider invalidates it.
    # A bare "seen" boolean would incorrectly suppress this second visit.
    rm -f "${stamp}"
    run_stage_once memo-probe
    [[ "${calls}" == 2 ]]
)
assert "a completed stage is visited once unless its stamp is invalidated" \
    driver_memoizes_stage_visits

# shellcheck disable=SC2329 # invoked through assert below.
driver_order_is_topological() (
    # shellcheck source=/dev/null
    source "${build_functions}"

    local -A visited=() position=()
    local -a order=()
    local dependency index name package

    # shellcheck disable=SC2329 # called by the sourced package graph.
    trace_stage() {
        local stage="$1"
        [[ -z "${visited[${stage}]+x}" ]] || return 0
        visited["${stage}"]=1
        order+=("${stage}")
    }
    # shellcheck disable=SC2329 # override the driver's stage executors below.
    run_stage_once() { trace_stage "$1"; }
    # shellcheck disable=SC2329 # override the driver's stage executors below.
    run_rootfs_package_stage() { trace_stage "$1"; }
    # python_package checks its host tool's stamp before visiting its stages.
    # shellcheck disable=SC2329
    stage_up_to_date() { return 0; }

    kernel
    rootfs
    trace_stage image/11-initramfs

    for index in "${!order[@]}"; do
        position["${order[${index}]}"]="${index}"
    done
    for name in "${order[@]}"; do
        package="$(awk -v wanted="${name}" '
            $1 == "run_rootfs_package_stage" && $2 == wanted {
                print $3
                exit
            }
        ' "${SELFTEST_ROOT}/scripts/build.sh")"
        package="${package:--}"
        while IFS= read -r dependency; do
            [[ -n "${dependency}" ]] || continue
            [[ -n "${position[${dependency}]+x}" ]] || return 1
            ((position[${dependency}] < position[${name}])) || return 1
        done < <(stage_dependency_names "${name}" "${package}")
    done
)
assert "the full traversal visits every dependency before its consumer" \
    driver_order_is_topological

# --------------------------------------------------------- sysroot ownership

checking "sysroot reconciliation"
printf '==> sysroot reconciliation\n'

# One package that renames a library between builds, and a second that shares
# a directory with it. What the first drops has to go; what the second still
# owns has to stay.
package_a="$(image_package_names | sed -n '2p')"
package_b="$(image_package_names | sed -n '3p')"
stage_one="${PKG_STAGE_DIR}/${package_a}"
stage_two="${PKG_STAGE_DIR}/${package_b}"
mkdir -p "${stage_one}/usr/lib64" "${stage_one}/usr/bin" "${stage_one}/usr/share" \
    "${stage_two}/usr/lib64" "${stage_two}/usr/share/probe-b"
printf 'v1\n' > "${stage_one}/usr/lib64/libprobe.so.1"
printf 'tool\n' > "${stage_one}/usr/bin/probe"
printf 'other\n' > "${stage_two}/usr/lib64/libother.so.1"
printf 'data\n' > "${stage_two}/usr/share/probe-b/data"
# A non-directory path shared by two packages exercises precedence restoration,
# not only the much easier case of keeping /usr/lib64 itself.
printf 'from-a\n' > "${stage_one}/usr/share/shared"
printf 'from-b\n' > "${stage_two}/usr/share/shared"

merge_probe() {
    local name="$1"
    local directory="${PKG_STAGE_DIR}/${name}"
    local record non_directories
    record="$(pkg_merged_manifest "${name}")"
    non_directories="${PKG_MERGED_DIR}/.${name}.probe-nondirs"
    pkg_tree_paths "${directory}" > "${record}.tmp"
    (cd "${directory}" && find . -mindepth 1 ! -type d -printf '%P\n') \
        | LC_ALL=C sort -u > "${non_directories}"
    pkg_sysroot_reconcile "${name}" "${directory}"
    cp -a --remove-destination "${directory}/." "${SYSROOT}/"
    pkg_reassert_merge_precedence "${name}" "${directory}" \
        "${non_directories}"
    rm -f "${non_directories}"
    mv "${record}.tmp" "${record}"
}

merge_probe "${package_a}"
merge_probe "${package_b}"

assert "a shared path keeps deterministic package-order precedence" \
    has_content "${SYSROOT}/usr/share/shared" from-a
# When the preferred package drops it, the next claimant's bytes must be put
# back; merely deleting the path would still differ from a clean replay of the
# current package set.
rm -f "${stage_one}/usr/share/shared"
merge_probe "${package_a}"
assert "dropping a shared path restores the remaining claimant" \
    has_content "${SYSROOT}/usr/share/shared" from-b

# The rename: the same package now installs .so.2 and no longer installs .so.1.
rm -f "${stage_one}/usr/lib64/libprobe.so.1"
printf 'v2\n' > "${stage_one}/usr/lib64/libprobe.so.2"
merge_probe "${package_a}"

refute "a path a package stopped installing is taken back" \
    exists "${SYSROOT}/usr/lib64/libprobe.so.1"
assert "the renamed library is in the sysroot under its new name" \
    exists "${SYSROOT}/usr/lib64/libprobe.so.2"
assert "another package's file in the same directory is untouched" \
    exists "${SYSROOT}/usr/lib64/libother.so.1"
assert "a directory two packages share is kept" \
    is_directory "${SYSROOT}/usr/lib64"
assert "a path the package still installs is kept" \
    exists "${SYSROOT}/usr/bin/probe"

# A package that leaves the image altogether takes everything it merged with it.
pkg_sysroot_reconcile "${package_b}" ""
rm -f "$(pkg_merged_manifest "${package_b}")"
refute "a package that leaves the image takes its files" \
    exists "${SYSROOT}/usr/share/probe-b/data"
refute "its now-empty directory goes too" \
    is_directory "${SYSROOT}/usr/share/probe-b"
assert "the shared directory survives a departing package" \
    is_directory "${SYSROOT}/usr/lib64"

# A deleted/renamed package has no stage left to call reconciliation. The
# rootfs boundary must retire records that no current image package owns.
mkdir -p "${SYSROOT}/usr/share/orphan"
printf 'old\n' > "${SYSROOT}/usr/share/orphan/data"
printf 'usr/share/orphan\nusr/share/orphan/data\n' \
    > "$(pkg_merged_manifest removed-package)"
pkg_reconcile_orphaned_merges
refute "a removed package cannot leave a file in the release sysroot" \
    exists "${SYSROOT}/usr/share/orphan/data"
refute "a removed package's merge record is retired" \
    exists "$(pkg_merged_manifest removed-package)"

# Replay the current package set into an empty tree. This is the acceptance
# criterion from GEN-001: an incremental A -> B merge must be byte-for-byte the
# same tree as a clean B merge, including directory modes and symlink targets.
clean_sysroot="${SCRATCH}/clean-sysroot"
mkdir -p "${clean_sysroot}"
cp -a "${stage_one}/." "${clean_sysroot}/"
assert "the incrementally reconciled sysroot equals a clean replay" \
    trees_equal "${SYSROOT}" "${clean_sysroot}"

# ---------------------------------------------------------- build identity

checking "build identity"
printf '==> build identity\n'

# A manifest is what a package hands an installed system, so a package's
# identity has to move when the manifest does and stay still when it does not.
manifest="${SCRATCH}/probe.files"
name="$(image_package_names | sed -n '2p')"
printf 'f|0755|%s|4|usr/bin/probe\n' "$(printf a | sha256sum | cut -c1-64)" \
    > "${manifest}"
first="$(pkg_build_id "${name}" "${manifest}")"
same "the same contents give the same build id" \
    "$(pkg_build_id "${name}" "${manifest}")" "${first}"

printf 'f|0755|%s|4|usr/bin/probe\n' "$(printf b | sha256sum | cut -c1-64)" \
    > "${manifest}"
differs "changed file contents change the build id" \
    "$(pkg_build_id "${name}" "${manifest}")" "${first}"

printf 'f|0755|%s|4|usr/bin/probe\nf|0644|%s|4|usr/share/probe\n' \
    "$(printf a | sha256sum | cut -c1-64)" \
    "$(printf c | sha256sum | cut -c1-64)" > "${manifest}"
differs "an added file changes the build id" \
    "$(pkg_build_id "${name}" "${manifest}")" "${first}"

# The version is in the identity as well, so a release bump is still visible to
# a client that only looks at the build id.
printf 'f|0755|%s|4|usr/bin/probe\n' "$(printf a | sha256sum | cut -c1-64)" \
    > "${manifest}"
cp "${PACKAGES_CONF}" "${packages_backup}"
sed -i "s/^\\(${name}|[^|]*|\\)[0-9]*|/\\19|/" "${PACKAGES_CONF}"
bumped_id="$(pkg_build_id "${name}" "${manifest}")"
cp "${packages_backup}" "${PACKAGES_CONF}"
differs "a bumped release changes the build id" "${bumped_id}" "${first}"

# Contents alone are insufficient provenance: a recipe, compiler or library
# change can matter even when a particular build happens to emit identical
# bytes. The producer and dependency stage identities preserve those causes.
printf '%064d\n' 5 > "${STAMP_DIR}/packages/bash.done"
producer_id="$(pkg_build_id "${name}" "${manifest}")"
differs "a new producer stage identity changes the build id" \
    "${producer_id}" "${first}"
printf '%064d\n' 6 > "${STAMP_DIR}/packages/bash.done"
differs "a rebuilt recipe changes the build id with identical files" \
    "$(pkg_build_id "${name}" "${manifest}")" "${producer_id}"
rm -f "${STAMP_DIR}/packages/bash.done"

printf '%064d\n' 7 > "${STAMP_DIR}/packages/openssl.done"
provider_id="$(pkg_build_id curl "${manifest}")"
printf '%064d\n' 8 > "${STAMP_DIR}/packages/openssl.done"
differs "a rebuilt library changes its consumer's build id" \
    "$(pkg_build_id curl "${manifest}")" "${provider_id}"
rm -f "${STAMP_DIR}/packages/openssl.done"

toolchain_id="$(pkg_build_id "${name}" "${manifest}")"
printf '%064d\n' 9 > "${STAMP_DIR}/toolchain/07-gcc-final.done"
# shellcheck disable=SC2034
STAGE_TOOLCHAIN_DIGEST=""
differs "a rebuilt compiler changes the package build id" \
    "$(pkg_build_id "${name}" "${manifest}")" "${toolchain_id}"
rm -f "${STAMP_DIR}/toolchain/07-gcc-final.done"
# shellcheck disable=SC2034
STAGE_TOOLCHAIN_DIGEST=""

# sowa-base and sowa-release are described while image/10-rootfs itself is still
# running. Their identity must already equal the one packaging computes after
# the stage writes its stamp, or a fresh image immediately looks out of date.
release_before_stamp="$(pkg_build_id sowa-release "${manifest}")"
stage_key image/10-rootfs "$(stage_script image/10-rootfs)" - \
    > "${STAMP_DIR}/image/10-rootfs.done"
same "rootfs-produced package identity is stable across its own stamp write" \
    "$(pkg_build_id sowa-release "${manifest}")" "${release_before_stamp}"
rm -f "${STAMP_DIR}/image/10-rootfs.done"

# The same identity, over the whole of what a stage actually does. A stage key
# carries the pinned tarballs the stage was *observed* to use, and that record
# is written when the stage exits - so a prediction made in the middle of the
# run, from the file beside the stamp, describes the previous run rather than
# this one. On a build from scratch there is no previous run and the prediction
# was of a stage that had used nothing at all: the image shipped one identity
# for sowa-base and sowa-release and the repository published another, and
# every fresh installation opened with two packages to upgrade.
rootfs_deps="${SCRATCH}/rootfs.deps"
: > "${rootfs_deps}"
rm -f "${STAMP_DIR}/image/10-rootfs.sources" "${STAMP_DIR}/image/10-rootfs.done"
export STAGE_DEPS_FILE="${rootfs_deps}" STAGE_RUNNING_NAME=image/10-rootfs
# What the stage asks for as it assembles the tree: every package's version
# comes out of the lock, and so does every licence text it copies.
source_version glibc > /dev/null
source_version linux > /dev/null
release_mid_run="$(pkg_build_id sowa-release "${manifest}")"
# ... and what the driver records for it once it returns.
LC_ALL=C sort -u "${rootfs_deps}" > "${STAMP_DIR}/image/10-rootfs.sources"
STAGE_DEPS_FILE=""
STAGE_RUNNING_NAME=""
export STAGE_DEPS_FILE STAGE_RUNNING_NAME
stage_key image/10-rootfs "$(stage_script image/10-rootfs)" - \
    > "${STAMP_DIR}/image/10-rootfs.done"
same "rootfs-produced identity covers the sources the stage was using" \
    "$(pkg_build_id sowa-release "${manifest}")" "${release_mid_run}"
rm -f "${STAMP_DIR}/image/10-rootfs.done" "${STAMP_DIR}/image/10-rootfs.sources"

archive="$(release_package_archive_name "${name}" "${first}")"
assert "the immutable archive name contains the full build id" \
    grep -q -- "-${first}\\.tar\\.xz$" <<< "${archive}"

# ----------------------------------------------------------- index migration

checking "index migration"
printf '==> index migration\n'

new_index="${SCRATCH}/index.new"
old_index="${SCRATCH}/index.old"
printf 'probe|1-1|x86_64|probe.tar.xz|%064d|10|dep-a,dep-b|MIT|Example|%s|Probe package\n' \
    4 "${first}" > "${new_index}"
# The legacy layout deliberately names a gzip archive too: the current parser
# and extractor retain read compatibility even though new repositories publish
# XZ only.
printf 'probe|1-1|x86_64|probe.tar.gz|%064d|10|dep-a,dep-b|MIT|Example|Probe package\n' \
    4 > "${old_index}"

# Called through assert's "$@", which shellcheck cannot see.
# shellcheck disable=SC2329
old_client_reads_new_index() {
    local package rest _version _arch _archive_name _checksum _size depends license
    local copyright description
    IFS='|' read -r package rest < "${new_index}"
    IFS='|' read -r _version _arch _archive_name _checksum _size depends license \
        copyright description <<< "${rest}"
    [[ "${package}" == probe && "${depends}" == dep-a,dep-b \
        && "${license}" == MIT && "${copyright}" == Example ]]
}
assert "the previous client still parses dependencies in the new index" \
    old_client_reads_new_index

# shellcheck disable=SC2329
new_client_migrates_indexes() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    DB_DIR="${SCRATCH}/client-db"
    mkdir -p "${DB_DIR}/probe"
    printf 'pkgname=probe\npkgver=1-1\n' > "${DB_DIR}/probe/desc"

    # Functions in the sourced client consume this dynamically.
    # shellcheck disable=SC2034
    INDEX="${old_index}"
    read_index_entry probe
    [[ "${IDX_DEPENDS}" == dep-a,dep-b && -z "${IDX_BUILD}" \
        && "${IDX_DESCRIPTION}" == "Probe package" ]] || return 1
    build_differs probe "${IDX_BUILD}" && return 1

    # shellcheck disable=SC2034
    INDEX="${new_index}"
    read_index_entry probe
    [[ "${IDX_DEPENDS}" == dep-a,dep-b && "${IDX_BUILD}" == "${first}" \
        && "${IDX_DESCRIPTION}" == "Probe package" ]] || return 1
    # An installed entry from before pkgbuild existed needs one convergence
    # rebuild when the repository first offers an identity.
    build_differs probe "${IDX_BUILD}" || return 1
    printf 'pkgname=probe\npkgver=1-1\npkgbuild=%064d\n' 0 \
        > "${DB_DIR}/probe/desc"
    build_differs probe "${IDX_BUILD}" || return 1
    printf 'pkgname=probe\npkgver=1-1\npkgbuild=%s\n' "${first}" \
        > "${DB_DIR}/probe/desc"
    build_differs probe "${IDX_BUILD}" && return 1
    build_differs probe "${producer_id}"
)
assert "the new client reads both layouts and detects missing or changed builds" \
    new_client_migrates_indexes

archive_info="${SCRATCH}/archive.PKGINFO"
printf 'pkgname=probe\npkgver=1-1\npkgbuild=%s\narch=x86_64\n' "${first}" \
    > "${archive_info}"

# shellcheck disable=SC2329
client_accepts_matching_archive_identity() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    verify_archive_metadata "${archive_info}" probe 1-1 x86_64 "${first}" \
        probe.tar.xz
)
assert "the client accepts an archive whose signed and embedded identities match" \
    client_accepts_matching_archive_identity

# shellcheck disable=SC2329
client_rejects_mismatched_archive_identity() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    verify_archive_metadata "${archive_info}" probe 1-1 x86_64 "${producer_id}" \
        probe.tar.xz 2> /dev/null
)
refute "the client rejects an archive whose embedded build id differs from the index" \
    client_rejects_mismatched_archive_identity

# ------------------------------------------------------------- publication

checking "repository publication"
printf '==> repository publication\n'

publication_work="${SCRATCH}/publish-work"
publication_dist="${SCRATCH}/published"
publication_packages="${publication_work}/packages"
mkdir -p "${publication_packages}"
archive_one="sowa-probe-1-1-x86_64-${first}.tar.xz"
printf 'first build\n' > "${publication_packages}/${archive_one}"
publication_serial="$(date -u +%s)"

# The index a publication is made from: one package, and the freshness header
# that says which publication this is. See index_freshness_header.
write_publication_index() {
    local archive="$1"
    local build="$2"
    local serial="$3"
    {
        printf '# sowa-repo serial=%s expires=%s published=x valid-until=y\n' \
            "${serial}" "$((serial + 86400))"
        printf 'probe|1-1|x86_64|%s|%s|%s|-|MIT|Example|%s|Probe package\n' \
            "${archive}" \
            "$(sha256sum "${publication_packages}/${archive}" | cut -c1-64)" \
            "$(stat -c %s "${publication_packages}/${archive}")" "${build}"
    } > "${publication_packages}/index"
}
write_publication_index "${archive_one}" "${first}" "${publication_serial}"

# shellcheck disable=SC2329
publish_probe() {
    env WORK_DIR="${publication_work}" DIST_DIR="${publication_dist}" TERM_TITLE=0 \
        "${SELFTEST_ROOT}/scripts/publish-repo.sh" \
        --allow-unsigned --keep-old > "${SCRATCH}/publish.log" 2>&1
}

assert "a build-identified archive publishes" publish_probe
printf 'different bytes under the same identity\n' \
    > "${publication_packages}/${archive_one}"
refute "publication refuses different bytes under one immutable name" \
    publish_probe

archive_two="sowa-probe-1-1-x86_64-${producer_id}.tar.xz"
printf 'second build\n' > "${publication_packages}/${archive_two}"
write_publication_index "${archive_two}" "${producer_id}" \
    "$((publication_serial + 1))"
assert "a changed build id publishes under a new immutable name" publish_probe
assert "the prior immutable archive remains available" \
    exists "${publication_dist}/x86_64/${archive_one}"

# Serving an index older than the one already being served is what a rollback
# looks like from a client, which refuses it. Finding that out here is better
# than finding it out from machines that have stopped updating.
write_publication_index "${archive_two}" "${producer_id}" \
    "$((publication_serial - 1))"
refute "publication refuses an index older than the one already served" \
    publish_probe
write_publication_index "${archive_two}" "${producer_id}" \
    "$((publication_serial + 1))"

legacy_archive="${publication_dist}/x86_64/sowa-probe-legacy.tar.gz"
printf 'legacy gzip transport\n' > "${legacy_archive}"
# shellcheck disable=SC2329
publish_probe_pruned() {
    env WORK_DIR="${publication_work}" DIST_DIR="${publication_dist}" TERM_TITLE=0 \
        "${SELFTEST_ROOT}/scripts/publish-repo.sh" \
        --allow-unsigned > "${SCRATCH}/publish-pruned.log" 2>&1
}
assert "publication can retire the legacy gzip transport" publish_probe_pruned
refute "a default XZ publication leaves a legacy gzip archive" \
    exists "${legacy_archive}"

# ------------------------------------------------------- release authenticity
#
# An adjacent checksum is useful after a bad USB write and useless after a
# hostile download: whoever replaces the artifact replaces that checksum too.
# Release manifests are signed by a separate offline key and cover every
# artifact as a set. Exercise the complete producer/consumer path here with a
# scratch key, including the malformed-but-validly-signed case the verifier
# still has to reject.

checking "release authenticity"
printf '==> release authenticity\n'

release_work="${SCRATCH}/release-work"
release_artifacts="${SCRATCH}/release-artifacts"
release_private="${SCRATCH}/release-private.key"
release_public="${SCRATCH}/release-public.pem"
release_prefix="${DISTRO_NAME}-${DISTRO_VERSION}-${ARTIFACT_ARCH}"
release_manifest="${release_artifacts}/${release_prefix}-release.manifest"
mkdir -p "${release_work}" "${release_artifacts}"

# shellcheck disable=SC2329
release_key_probe() {
    env WORK_DIR="${release_work}" DOWNLOAD_DIR="${SCRATCH}/release-downloads" \
        ARTIFACT_DIR="${release_artifacts}" RELEASE_KEY="${release_private}" \
        RELEASE_PUBLIC_KEY="${release_public}" TERM_TITLE=0 \
        "${SELFTEST_ROOT}/scripts/release-key.sh" \
        > "${SCRATCH}/release-key.log" 2>&1
}

# shellcheck disable=SC2329
release_sign_probe() {
    env WORK_DIR="${release_work}" DOWNLOAD_DIR="${SCRATCH}/release-downloads" \
        ARTIFACT_DIR="${release_artifacts}" RELEASE_KEY="${release_private}" \
        RELEASE_PUBLIC_KEY="${release_public}" RELEASE_ALLOW_DIRTY=1 TERM_TITLE=0 \
        "${SELFTEST_ROOT}/scripts/release-manifest.sh" \
        > "${SCRATCH}/release-sign.log" 2>&1
}

# shellcheck disable=SC2329
release_verify_probe() {
    "${SELFTEST_ROOT}/scripts/verify-release.sh" --key "${release_public}" \
        "${release_manifest}" "$@" > "${SCRATCH}/release-verify.log" 2>&1
}

# shellcheck disable=SC2329
sign_test_manifest() {
    local manifest="$1"
    openssl pkeyutl -sign -rawin -inkey "${release_private}" \
        -in "${manifest}" -out "${manifest}.sig"
}

# shellcheck disable=SC2329
verify_test_manifest_with_key() {
    local key="$1" manifest="$2"
    "${SELFTEST_ROOT}/scripts/verify-release.sh" --key "${key}" \
        "${manifest}" > /dev/null 2>&1
}

# shellcheck disable=SC2329
release_key_in_checkout_probe() {
    env WORK_DIR="${release_work}" DOWNLOAD_DIR="${SCRATCH}/release-downloads" \
        ARTIFACT_DIR="${release_artifacts}" RELEASE_KEY="${forbidden_private}" \
        RELEASE_PUBLIC_KEY="${release_public}" TERM_TITLE=0 \
        "${SELFTEST_ROOT}/scripts/release-key.sh" > /dev/null 2>&1
}

assert "a separate offline release key can be created" release_key_probe
same "the private release key is mode 0600" \
    "$(stat -c %a "${release_private}")" 600
assert "the public release key is emitted for distribution" exists "${release_public}"

printf 'bootable image\n' > "${release_artifacts}/${release_prefix}.iso"
printf 'portable installer\n' > "${release_artifacts}/sowa-install"
assert "current artifacts can be signed as one release" release_sign_probe
assert "the manifest is written" exists "${release_manifest}"
assert "the detached manifest signature is written" exists "${release_manifest}.sig"
assert "the signed manifest verifies every artifact" release_verify_probe

# A recipient usually downloads one image rather than every form of the same
# release. Subset verification must not require absent artifacts, while a full
# verification must still notice one.
mv "${release_artifacts}/sowa-install" "${SCRATCH}/sowa-install"
assert "one downloaded artifact can be verified as a signed subset" \
    release_verify_probe "${release_artifacts}/${release_prefix}.iso"
refute "full-set verification notices a missing artifact" release_verify_probe
mv "${SCRATCH}/sowa-install" "${release_artifacts}/sowa-install"

printf 'tampered image\n' > "${release_artifacts}/${release_prefix}.iso"
refute "a changed artifact is rejected" release_verify_probe \
    "${release_artifacts}/${release_prefix}.iso"
printf 'bootable image\n' > "${release_artifacts}/${release_prefix}.iso"
assert "restoring the signed bytes restores verification" release_verify_probe

other_private="${SCRATCH}/other-release.key"
other_public="${SCRATCH}/other-release.pub"
openssl genpkey -algorithm ed25519 -out "${other_private}"
openssl pkey -in "${other_private}" -pubout -out "${other_public}"
refute "a manifest signed by another release key is rejected" \
    verify_test_manifest_with_key "${other_public}" "${release_manifest}"

unsafe_manifest="${SCRATCH}/unsafe-release.manifest"
cp "${release_manifest}" "${unsafe_manifest}"
printf '%064d|1|../escape\n' 0 >> "${unsafe_manifest}"
sign_test_manifest "${unsafe_manifest}"
refute "a validly signed manifest still cannot name a path" \
    verify_test_manifest_with_key "${release_public}" "${unsafe_manifest}"

duplicate_manifest="${SCRATCH}/duplicate-release.manifest"
cp "${release_manifest}" "${duplicate_manifest}"
sed -n '$p' "${release_manifest}" >> "${duplicate_manifest}"
sign_test_manifest "${duplicate_manifest}"
refute "a validly signed manifest cannot name one artifact twice" \
    verify_test_manifest_with_key "${release_public}" "${duplicate_manifest}"

repeated_metadata_manifest="${SCRATCH}/repeated-metadata-release.manifest"
{
    sed -n '1,2p' "${release_manifest}"
    printf '# distro|\n'
    sed -n '3,$p' "${release_manifest}"
} > "${repeated_metadata_manifest}"
sign_test_manifest "${repeated_metadata_manifest}"
refute "an empty metadata field cannot hide a repeated field" \
    verify_test_manifest_with_key "${release_public}" \
    "${repeated_metadata_manifest}"

unordered_manifest="${SCRATCH}/unordered-release.manifest"
{
    sed -n '1,8p' "${release_manifest}"
    sed -n '9,$p' "${release_manifest}" | LC_ALL=C sort -r
} > "${unordered_manifest}"
sign_test_manifest "${unordered_manifest}"
refute "artifact entries must retain their canonical order" \
    verify_test_manifest_with_key "${release_public}" "${unordered_manifest}"

ln -s /etc/passwd "${release_artifacts}/${release_prefix}.img"
refute "a release signer refuses a symbolic-link artifact" release_sign_probe
rm -f "${release_artifacts}/${release_prefix}.img"

printf 'unfinished\n' > "${release_artifacts}/${release_prefix}.iso.tmp.123"
refute "a release signer refuses to race an unfinished artifact" release_sign_probe
rm -f "${release_artifacts}/${release_prefix}.iso.tmp.123"

printf 'unfinished installer\n' > "${release_artifacts}/sowa-install.tmp.123"
refute "the portable installer has the same unfinished-artifact guard" \
    release_sign_probe
rm -f "${release_artifacts}/sowa-install.tmp.123"

chmod 0644 "${release_private}"
refute "a release signer refuses a group-readable private key" release_sign_probe
chmod 0600 "${release_private}"

forbidden_private="${SELFTEST_ROOT}/release-private-key-must-not-exist"
refute "release-key refuses to put a private key in the checkout" \
    release_key_in_checkout_probe
refute "the refused checkout key was not created" exists "${forbidden_private}"

# ------------------------------------------------------------------- logging

checking "package-manager logging"
printf '==> package-manager logging\n'

# shellcheck disable=SC2329
client_logging_uses_selected_root() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    ROOT="${SCRATCH}/logged-root"
    set_paths
    open_log
    audit $'plan: probe install 1-1\ninjected'
    # LOG_FILE is declared by the sourced client.
    # shellcheck disable=SC2153
    [[ "${LOG_FILE}" == "${ROOT}/var/log/sowa-pkg.log" \
        && -f "${LOG_FILE}" \
        && "$(stat -c %a "${LOG_FILE}")" == 640 \
        && "$(wc -l < "${LOG_FILE}")" == 1 \
        && "$(cat "${LOG_FILE}")" == *'plan: probe install 1-1\ninjected' ]]
)
assert "audit records stay in --root and cannot inject extra lines" \
    client_logging_uses_selected_root

# shellcheck disable=SC2329
client_logging_preserves_mode() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    ROOT="${SCRATCH}/mode-root"
    set_paths
    mkdir -p "${ROOT}/var/log"
    : > "${ROOT}/var/log/sowa-pkg.log"
    chmod 0600 "${ROOT}/var/log/sowa-pkg.log"
    open_log
    [[ "$(stat -c %a "${ROOT}/var/log/sowa-pkg.log")" == 600 ]]
)
assert "logging preserves an administrator's stricter file mode" \
    client_logging_preserves_mode

# shellcheck disable=SC2329
client_read_only_does_not_open_log() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    ROOT="${SCRATCH}/read-only-root"
    set_paths
    audit "read only"
    [[ ! -e "${ROOT}/var/log/sowa-pkg.log" ]]
)
assert "read-only use does not create a package-manager log" \
    client_read_only_does_not_open_log

# ---------------------------------------------------- client: configuration
#
# pkg.conf used to be sourced, which made it a program: "sowa-pkg --root DIR"
# ran DIR's copy of it, on the host, as whoever was repairing that root. It is
# read as data now, and this is where that is asserted rather than assumed.

checking "package-manager configuration"
printf '==> package-manager configuration\n'

config_probe="${SCRATCH}/pkg.conf"
probe_hash="$(printf 'probe' | sha256sum | cut -c1-64)"
other_hash="$(printf 'other' | sha256sum | cut -c1-64)"

# shellcheck disable=SC2329
config_reads() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    printf '%s\n' "$@" > "${config_probe}"
    parse_config "${config_probe}" 2> /dev/null
)

# shellcheck disable=SC2329
shipped_configuration_is_data() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    parse_config "${SELFTEST_ROOT}/rootfs-overlay/etc/sowa/pkg.conf"
    [[ "${SOWA_REPO_URL}" == https://* \
        && "${SOWA_REPO_ARCH}" == x86_64 \
        && "${SOWA_REPO_KEY}" == /etc/sowa/keys/* \
        && "${SOWA_REQUIRE_SIGNATURE}" == 1 ]]
)
assert "the configuration file the image ships parses as data" \
    shipped_configuration_is_data

rm -f "${SCRATCH}/executed"
refute "a value containing a command substitution is refused" \
    config_reads "SOWA_REPO_URL=\"\$(touch ${SCRATCH}/executed)\""
refute "nothing in a configuration file is executed while it is read" \
    exists "${SCRATCH}/executed"
# The backquotes are the point of this one, so they stay literal.
# shellcheck disable=SC2016
refute "a value containing a backquote is refused" \
    config_reads 'SOWA_REPO_ARCH=`uname -m`'
refute "a setting this program does not have is refused rather than ignored" \
    config_reads 'SOWA_REPO_URL="https://packages.example.net/x86_64"' 'SOWA_EVIL=1'
refute "a setting given twice is refused" \
    config_reads 'SOWA_REPO_URL="https://a.example.net/x"' \
    'SOWA_REPO_URL="https://b.example.net/x"'
refute "a repository URL that is not http or https is refused" \
    config_reads 'SOWA_REPO_URL="file:///etc"'
refute "a key path that climbs out of its directory is refused" \
    config_reads 'SOWA_REPO_KEY="/etc/sowa/../../root/id"'
refute "a value carrying a second command after a semicolon is refused" \
    config_reads 'SOWA_REPO_ARCH="x86_64; id"'
refute "a signature setting that is not 0 or 1 is refused" \
    config_reads 'SOWA_REQUIRE_SIGNATURE=2'
assert "an ordinary repository URL is read" \
    config_reads 'SOWA_REPO_URL="https://packages.example.net/x86_64"'

# ----------------------------------------------------- client: index shape

checking "repository index validation"
printf '==> repository index validation\n'

index_probe="${SCRATCH}/index.probe"

# shellcheck disable=SC2329
index_accepts() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    printf '%s\n' "$@" > "${index_probe}"
    validate_index "${index_probe}" 2> /dev/null
)

assert "a well-formed index is accepted" index_accepts \
    "probe|1-1|x86_64|sowa-probe-1-1.tar.xz|${probe_hash}|10|-|MIT|Nobody|${probe_hash}|A probe"
assert "a dependency chain that closes is accepted" index_accepts \
    "one|1-1|x86_64|one.tar.xz|${probe_hash}|10|two|MIT|Nobody|${probe_hash}|d" \
    "two|1-1|x86_64|two.tar.xz|${probe_hash}|10|three|MIT|Nobody|${probe_hash}|d" \
    "three|1-1|x86_64|three.tar.xz|${probe_hash}|10|-|MIT|Nobody|${probe_hash}|d"
refute "a package name that is a path is refused" index_accepts \
    "../../etc|1-1|x86_64|a.tar.xz|${probe_hash}|10|-|MIT|Nobody|${probe_hash}|d"
refute "an archive name that is a path is refused" index_accepts \
    "probe|1-1|x86_64|../../evil.tar.xz|${probe_hash}|10|-|MIT|Nobody|${probe_hash}|d"
refute "a checksum that is not a SHA-256 is refused" index_accepts \
    "probe|1-1|x86_64|a.tar.xz|notahash|10|-|MIT|Nobody|${probe_hash}|d"
refute "a size that is not a positive number is refused" index_accepts \
    "probe|1-1|x86_64|a.tar.xz|${probe_hash}|-1|-|MIT|Nobody|${probe_hash}|d"
refute "one package offered twice is refused" index_accepts \
    "probe|1-1|x86_64|a.tar.xz|${probe_hash}|10|-|MIT|Nobody|${probe_hash}|d" \
    "probe|1-2|x86_64|b.tar.xz|${probe_hash}|10|-|MIT|Nobody|${probe_hash}|d"
refute "two packages naming one archive are refused" index_accepts \
    "one|1-1|x86_64|a.tar.xz|${probe_hash}|10|-|MIT|Nobody|${probe_hash}|d" \
    "two|1-1|x86_64|a.tar.xz|${probe_hash}|10|-|MIT|Nobody|${probe_hash}|d"
refute "a dependency the index does not offer is refused" index_accepts \
    "probe|1-1|x86_64|a.tar.xz|${probe_hash}|10|missing|MIT|Nobody|${probe_hash}|d"
refute "a dependency cycle is refused rather than recursed into" index_accepts \
    "one|1-1|x86_64|a.tar.xz|${probe_hash}|10|two|MIT|Nobody|${probe_hash}|d" \
    "two|1-1|x86_64|b.tar.xz|${probe_hash}|10|one|MIT|Nobody|${probe_hash}|d"
refute "a package built for another architecture is refused" index_accepts \
    "probe|1-1|aarch64|a.tar.xz|${probe_hash}|10|-|MIT|Nobody|${probe_hash}|d"
refute "an index carrying a terminal escape is refused" index_accepts \
    "$(printf 'probe|1-1|x86_64|a.tar.xz|%s|10|-|MIT|Nobody|%s|\033[2Jd' \
        "${probe_hash}" "${probe_hash}")"

# ------------------------------------------------------ client: freshness
#
# A signature says who wrote an index, not that it is the newest one they wrote.
# These are the four things that answer the difference: a serial that only moves
# forward, an expiry, the refusal of an index that has lost its header after one
# with a header has been seen, and an override that has to be asked for.

checking "repository freshness"
printf '==> repository freshness\n'

freshness_now="$(date -u +%s)"

# An index carrying the given serial and expiry ("none" for an index written
# before the header existed), offered to a client whose highest accepted serial
# is the third argument.
# ALLOW_STALE is consumed by the sourced client.
# shellcheck disable=SC2329,SC2034
freshness_accepts() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    local serial="$1"
    local expires="$2"
    local accepted="$3"
    REPO_DIR="${SCRATCH}/freshness"
    ALLOW_STALE="${4:-0}"
    rm -rf "${REPO_DIR}"
    mkdir -p "${REPO_DIR}"
    [[ "${accepted}" == none ]] \
        || printf '%s\n' "${accepted}" > "${REPO_DIR}/serial"
    {
        printf '# a repository\n'
        [[ "${serial}" == none ]] \
            || printf '# sowa-repo serial=%s expires=%s published=x valid-until=y\n' \
                "${serial}" "${expires}"
        printf 'probe|1-1|x86_64|a.tar.xz|%s|10|-|MIT|Nobody|%s|d\n' \
            "${probe_hash}" "${probe_hash}"
    } > "${REPO_DIR}/index"
    check_index_freshness "${REPO_DIR}/index" 2> /dev/null
)

assert "a current index is accepted" \
    freshness_accepts "${freshness_now}" "$((freshness_now + 86400))" 0
assert "the index this machine already has is accepted again" \
    freshness_accepts "${freshness_now}" "$((freshness_now + 86400))" "${freshness_now}"
refute "an index older than the one already accepted is refused" \
    freshness_accepts "$((freshness_now - 86400))" "$((freshness_now + 86400))" \
    "${freshness_now}"
refute "an expired index is refused" \
    freshness_accepts "${freshness_now}" "$((freshness_now - 86400))" 0
assert "--allow-stale takes an expired index" \
    freshness_accepts "${freshness_now}" "$((freshness_now - 86400))" 0 1
refute "an index that has lost its serial is refused" \
    freshness_accepts none 0 "${freshness_now}"
assert "a repository that has never published a serial is still readable" \
    freshness_accepts none 0 none

# IDX_SERIAL is consumed by the sourced client.
# shellcheck disable=SC2329,SC2034
serial_only_moves_forward() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    REPO_DIR="${SCRATCH}/recorded"
    rm -rf "${REPO_DIR}"
    mkdir -p "${REPO_DIR}"
    printf '100\n' > "${REPO_DIR}/serial"
    IDX_SERIAL=50
    record_index_serial
    [[ "$(cat "${REPO_DIR}/serial")" == 100 ]] || return 1
    IDX_SERIAL=200
    record_index_serial
    [[ "$(cat "${REPO_DIR}/serial")" == 200 ]]
)
assert "the recorded serial only ever moves forward" serial_only_moves_forward

# ------------------------------------------------------ client: containment
#
# Every path the client creates, moves, chmods or removes is a string from a
# manifest joined onto the root. String concatenation is not a filesystem
# boundary, and --root exists to be pointed at trees somebody else assembled.

checking "package containment"
printf '==> package containment\n'

manifest_root="${SCRATCH}/manifest-root"
mkdir -p "${manifest_root}/usr/bin"

# shellcheck disable=SC2329
manifest_is_safe() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    ROOT="$1"
    shift
    printf '%s\n' "$@" > "${SCRATCH}/manifest.probe"
    assert_manifest_safe probe "${SCRATCH}/manifest.probe" 2> /dev/null
)

assert "an ordinary manifest is accepted" \
    manifest_is_safe "${manifest_root}" \
    "d|755|-|0|usr" "d|755|-|0|usr/bin" "f|755|${probe_hash}|10|usr/bin/probe"
refute "a manifest path that climbs out of the root is refused" \
    manifest_is_safe "${manifest_root}" "f|755|${probe_hash}|10|../../etc/probe"
refute "an absolute manifest path is refused" \
    manifest_is_safe "${manifest_root}" "f|755|${probe_hash}|10|/etc/probe"
refute "a manifest path carrying a terminal escape is refused" \
    manifest_is_safe "${manifest_root}" \
    "$(printf 'f|755|%s|10|usr/bin/\033[2Jprobe' "${probe_hash}")"
refute "a manifest writing through a link it ships is refused" \
    manifest_is_safe "${manifest_root}" \
    "l|0777|/|0|usr/lib" "f|644|${probe_hash}|10|usr/lib/passwd"

escape_root="${SCRATCH}/escape-root"
rm -rf "${escape_root}"
mkdir -p "${escape_root}/usr"
ln -sfn /tmp "${escape_root}/usr/bin"
refute "a directory in the root that is a link out of it is refused" \
    manifest_is_safe "${escape_root}" \
    "d|755|-|0|usr" "d|755|-|0|usr/bin" "f|755|${probe_hash}|10|usr/bin/probe"

# ------------------------------------------- client: archive against manifest
#
# The manifest is a separate document from the archive it travels in, and it is
# what mv, chmod, rm and "sowa-pkg verify" are all driven from. Nothing used to
# check that the two described the same package.

checking "package archive integrity"
printf '==> package archive integrity\n'

staged_root="${SCRATCH}/staged-root"
staged="${staged_root}/var/cache/sowa/staging/probe"
rm -rf "${staged_root}"
mkdir -p "${staged}/usr/bin"
printf '#!/bin/sh\nexit 0\n' > "${staged}/usr/bin/probe"
chmod 0755 "${staged}/usr/bin/probe"
ln -sfn probe "${staged}/usr/bin/probe2"
staged_hash="$(sha256sum "${staged}/usr/bin/probe" | cut -c1-64)"
staged_size="$(stat -c %s "${staged}/usr/bin/probe")"
staged_link="l|0777|probe|0|usr/bin/probe2"

# STAGING_DIR is consumed by the sourced client.
# shellcheck disable=SC2329,SC2034
staged_tree_matches() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    ROOT="${staged_root}"
    STAGING_DIR="${staged_root}/var/cache/sowa/staging"
    printf '%s\n' "$@" > "${staged}/.FILES"
    verify_staged_tree probe "${staged}" "${staged}/.FILES" probe.tar.xz 2> /dev/null
)

assert "a tree that is exactly its manifest is accepted" staged_tree_matches \
    "f|755|${staged_hash}|${staged_size}|usr/bin/probe" "${staged_link}"
refute "a member the manifest does not list is refused" staged_tree_matches \
    "f|755|${staged_hash}|${staged_size}|usr/bin/probe"
refute "a manifest entry the tree does not carry is refused" staged_tree_matches \
    "f|755|${staged_hash}|${staged_size}|usr/bin/probe" "${staged_link}" \
    "f|644|${probe_hash}|3|usr/bin/gone"
refute "a mode the tree does not have is refused" staged_tree_matches \
    "f|4755|${staged_hash}|${staged_size}|usr/bin/probe" "${staged_link}"
refute "a link target the tree does not have is refused" staged_tree_matches \
    "f|755|${staged_hash}|${staged_size}|usr/bin/probe" \
    "l|0777|/etc/shadow|0|usr/bin/probe2"
refute "contents that are not what the manifest records are refused" \
    staged_tree_matches "f|755|${probe_hash}|${staged_size}|usr/bin/probe" \
    "${staged_link}"

ordinary_archive="${SCRATCH}/ordinary.tar"
repeated_archive="${SCRATCH}/repeated.tar"
absolute_archive="${SCRATCH}/absolute.tar"
tar --create --file="${ordinary_archive}" --directory="${staged}" \
    --no-recursion usr/bin/probe usr/bin/probe2
tar --create --file="${repeated_archive}" --directory="${staged}" \
    --no-recursion usr/bin/probe usr/bin/probe
tar --create --absolute-names --file="${absolute_archive}" \
    --no-recursion "${staged}/usr/bin/probe"

# shellcheck disable=SC2329
archive_members_are_safe() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    verify_archive_members "$1" 2> /dev/null
)
assert "an ordinary archive is accepted" \
    archive_members_are_safe "${ordinary_archive}"
refute "an archive carrying one name twice is refused" \
    archive_members_are_safe "${repeated_archive}"
refute "an archive with an absolute member name is refused" \
    archive_members_are_safe "${absolute_archive}"

# -------------------------------------------------- client: what a plan does
#
# The one decision in a transaction that refuses to follow the repository: a
# version going backwards is either an operator rolling something back or a
# repository that has been rolled back for them, and only the first of those
# types the package name.

checking "transaction policy"
printf '==> transaction policy\n'

# IDX_VERSION, IDX_BUILD, NAMED and ALLOW_DOWNGRADE are all consumed by the
# sourced client.
# shellcheck disable=SC2329,SC2034
plan_for() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    local installed="$1"
    DB_DIR="${SCRATCH}/plan-db"
    IDX_VERSION="$2"
    NAMED=()
    [[ "$3" != named ]] || NAMED=(probe)
    ALLOW_DOWNGRADE="$4"
    IDX_BUILD="${5:-${probe_hash}}"
    rm -rf "${DB_DIR}"
    mkdir -p "${DB_DIR}/probe"
    printf 'pkgname=probe\npkgver=%s\npkgbuild=%s\n' "${installed}" \
        "${probe_hash}" > "${DB_DIR}/probe/desc"
    plan_package probe "${installed}" 2> /dev/null
    printf '%s|%s\n' "${PLAN_ACTION}" "${PLAN_HELD}"
)

# shellcheck disable=SC2329
plan_says() {
    local expected="$1"
    shift
    [[ "$(plan_for "$@")" == "${expected}" ]]
}

assert "a newer version in the repository is an upgrade" \
    plan_says "upgrade 1-1 -> 2-1|" 1-1 2-1 named 0
assert "the same version and build is nothing to do" \
    plan_says "|" 1-1 1-1 named 0
assert "the same version rebuilt is a rebuild" \
    plan_says "rebuild 1-1 (build ${other_hash:0:12})|" 1-1 1-1 resolved 0 \
    "${other_hash}"
assert "a repository behind the machine is held rather than followed" \
    plan_says "|probe 2-1 (repository has 1-1)" 2-1 1-1 resolved 0
refute "a downgrade of a package named on the command line is refused" \
    plan_for 2-1 1-1 named 0
assert "a named downgrade is planned once --allow-downgrade is given" \
    plan_says "downgrade 2-1 -> 1-1|" 2-1 1-1 named 1

# ------------------------------------------------------ client: obsolete files
#
# An upgrade removes the files the old version owned and the new one does not.
# What it must not remove is a file whose contents are no longer the ones the
# package installed: an empty /root/.ssh/authorized_keys shipped in the overlay
# was once sowa-release's, and dropping it from the package would otherwise
# have taken the administrator's keys with it - the same keys the packaged
# empty file had already been overwriting on every upgrade.

checking "obsolete files"
printf '==> obsolete files\n'

# shellcheck disable=SC2329
prune_probe() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    local root="${SCRATCH}/prune-root"
    local empty_hash untouched_hash
    rm -rf "${root}"
    ROOT="${root}"
    DB_DIR="${root}/var/lib/sowa/db"
    mkdir -p "${DB_DIR}/probe" "${root}/root/.ssh" "${root}/usr/share/probe"
    : > "${root}/empty"
    empty_hash="$(sha256sum "${root}/empty" | cut -c1-64)"
    printf 'shipped\n' > "${root}/usr/share/probe/dropped"
    untouched_hash="$(sha256sum "${root}/usr/share/probe/dropped" | cut -c1-64)"
    printf 'ssh-ed25519 AAAA... you@example\n' \
        > "${root}/root/.ssh/authorized_keys"
    {
        printf 'f|600|%s|0|root/.ssh/authorized_keys\n' "${empty_hash}"
        printf 'f|644|%s|8|usr/share/probe/dropped\n' "${untouched_hash}"
    } > "${DB_DIR}/probe/files"
    : > "${SCRATCH}/prune-new-manifest"
    prune_removed_files probe "${SCRATCH}/prune-new-manifest" > /dev/null 2>&1
    [[ -s "${root}/root/.ssh/authorized_keys" \
        && ! -e "${root}/usr/share/probe/dropped" ]]
)
assert "an upgrade drops a file the package owned and leaves an edited one" \
    prune_probe

# shellcheck disable=SC2329
prune_directory_probe() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    local root="${SCRATCH}/prune-directory-root"
    rm -rf "${root}"
    ROOT="${root}"
    DB_DIR="${root}/var/lib/sowa/db"
    mkdir -p "${DB_DIR}/probe" "${DB_DIR}/other" \
        "${root}/root/.ssh" "${root}/usr/share/probe"
    printf 'pkgname=probe\npkgver=1-1\ndepends=-\n' > "${DB_DIR}/probe/desc"
    printf 'pkgname=other\npkgver=1-1\ndepends=-\n' > "${DB_DIR}/other/desc"
    printf 'd|700|-|0|root/.ssh\nd|755|-|0|usr/share/probe\n' \
        > "${DB_DIR}/probe/files"
    printf 'd|700|-|0|root/.ssh\n' > "${DB_DIR}/other/files"
    : > "${SCRATCH}/prune-directory-manifest"
    prune_removed_files probe "${SCRATCH}/prune-directory-manifest" \
        > /dev/null 2>&1
    [[ -d "${root}/root/.ssh" && ! -d "${root}/usr/share/probe" ]]
)
assert "an empty directory another package owns outlives the one that dropped it" \
    prune_directory_probe

# shellcheck disable=SC2329
overlay_ships_no_authorized_keys() {
    [[ ! -e "${SELFTEST_ROOT}/rootfs-overlay/root/.ssh/authorized_keys" ]]
}
assert "no package ships root's authorised keys" \
    overlay_ships_no_authorized_keys

# ------------------------------------------------------ client: removal order
#
# "remove consumer library" is a complete instruction. Answering it by asking
# whether consumer is installed - which it is, at the moment the question is
# asked - refuses a removal that is perfectly well defined.

checking "package removal"
printf '==> package removal\n'

# shellcheck disable=SC2329
removal_order_of() (
    # shellcheck source=/dev/null
    source "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg"
    DB_DIR="${SCRATCH}/removal-db"
    rm -rf "${DB_DIR}"
    mkdir -p "${DB_DIR}/library" "${DB_DIR}/middle" "${DB_DIR}/consumer"
    printf 'pkgname=library\npkgver=1-1\ndepends=-\n' > "${DB_DIR}/library/desc"
    printf 'pkgname=middle\npkgver=1-1\ndepends=library\n' > "${DB_DIR}/middle/desc"
    printf 'pkgname=consumer\npkgver=1-1\ndepends=middle\n' \
        > "${DB_DIR}/consumer/desc"
    removal_order "$@" | paste -sd' ' -
)

# shellcheck disable=SC2329
removal_order_is() {
    local expected="$1"
    shift
    [[ "$(removal_order_of "$@")" == "${expected}" ]]
}
assert "a removal takes dependants off before what they depend on" \
    removal_order_is "consumer middle library" library consumer middle

# A root with two packages, one depending on the other, and the real client run
# against it.
# shellcheck disable=SC2329
remove_probe() (
    local root="${SCRATCH}/removal-root"
    local db="${root}/var/lib/sowa/db"
    local name hash
    rm -rf "${root}"
    mkdir -p "${db}/library" "${db}/consumer" "${root}/etc/sowa" "${root}/usr/bin"
    printf 'SOWA_REPO_URL="https://packages.example.net/x86_64"\n' \
        > "${root}/etc/sowa/pkg.conf"
    printf 'x\n' > "${root}/usr/bin/library"
    printf 'x\n' > "${root}/usr/bin/consumer"
    hash="$(sha256sum "${root}/usr/bin/library" | cut -c1-64)"
    printf 'pkgname=library\npkgver=1-1\ndepends=-\n' > "${db}/library/desc"
    printf 'pkgname=consumer\npkgver=1-1\ndepends=library\n' \
        > "${db}/consumer/desc"
    printf 'f|644|%s|2|usr/bin/library\n' "${hash}" > "${db}/library/files"
    printf 'f|644|%s|2|usr/bin/consumer\n' "${hash}" > "${db}/consumer/files"
    "${SELFTEST_ROOT}/rootfs-overlay/usr/bin/sowa-pkg" --root "${root}" -y \
        --no-hooks remove "$@" > /dev/null 2>&1 || return 1
    for name in "$@"; do
        [[ ! -d "${db}/${name}" && ! -e "${root}/usr/bin/${name}" ]] || return 1
    done
)
assert "a dependency can be removed together with what depends on it" \
    remove_probe library consumer
refute "a dependency something else still needs cannot be removed on its own" \
    remove_probe library

# ----------------------------------------------------- source mirror fallback

checking "source mirror fallback"
printf '==> source mirror fallback\n'

fetch_root="${SCRATCH}/fetch"
fetch_work="${fetch_root}/work"
fetch_downloads="${fetch_root}/downloads"
fetch_payload="${fetch_root}/payload"
fetch_lock="${fetch_root}/sources.lock"
fetch_mirrors="${fetch_root}/mirrors.conf"
mkdir -p "${fetch_work}/tools/bin" "${fetch_downloads}"
printf 'the bytes both upstreams are meant to serve\n' > "${fetch_payload}"
fetch_sha="$(sha256sum "${fetch_payload}" | cut -c1-64)"
printf 'probe|1.2.3|probe.tar|https://primary.invalid/files/probe.tar|%s|-\n' \
    "${fetch_sha}" > "${fetch_lock}"
printf 'prefix|https://primary.invalid/files/|https://mirror.invalid/files/\n' \
    > "${fetch_mirrors}"

# curl is replaced only inside the scratch tool directory common.sh puts first
# on PATH. The primary fails, while the mirror returns the locked bytes and the
# same transfer metadata the real curl --write-out would return.
cat > "${fetch_work}/tools/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
output=
url="${!#}"
while (($#)); do
    if [[ "$1" == --output ]]; then
        output="$2"
        shift 2
    else
        shift
    fi
done
[[ "${url}" != https://primary.invalid/* ]] || exit 22
/usr/bin/cp "${FAKE_FETCH_PAYLOAD}" "${output}"
bytes="$(/usr/bin/stat -c %s "${output}")"
printf '200|%s|%s|4096|0.01|application/octet-stream' "${url}" "${bytes}"
FAKE_CURL
chmod 0755 "${fetch_work}/tools/bin/curl"

fetch_output="$(
    /usr/bin/env \
        WORK_DIR="${fetch_work}" \
        DOWNLOAD_DIR="${fetch_downloads}" \
        ARTIFACT_DIR="${fetch_root}/artifacts" \
        LOCK_FILE="${fetch_lock}" \
        MIRRORS_FILE="${fetch_mirrors}" \
        FAKE_FETCH_PAYLOAD="${fetch_payload}" \
        TERM_TITLE=0 \
    "${SELFTEST_ROOT}/scripts/fetch.sh" 2>&1
)" || bad "fetch did not recover from the failed primary"
assert "a failed primary falls back to a mirror" \
    has_content "${fetch_downloads}/probe.tar" \
    "the bytes both upstreams are meant to serve"
assert "fetch output identifies the failed source" \
    contains_text "${fetch_output}" "source failed with curl status 22"
assert "fetch output reports transfer details" \
    contains_text "${fetch_output}" \
    "response HTTP 200, 0.01s at 4.0 KiB/s, application/octet-stream"

printf '\n'
if ((failures == 0)); then
    printf 'selftest: all checks passed\n'
else
    printf 'selftest: %d check(s) failed\n' "${failures}" >&2
fi
exit $((failures > 0))
