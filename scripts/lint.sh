#!/usr/bin/env bash

set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
readonly ROOT

shell_sources() {
    find "${ROOT}/scripts" -type f -name '*.sh' -print
    # Programs installed into the image carry no .sh suffix, so match the
    # shebang instead; sowa-setup, the init scripts and the rc framework all
    # run on the target and need linting too.
    grep -rlE '^#!/(usr/)?bin/(env )?(ba)?sh' \
        "${ROOT}/rootfs-overlay" "${ROOT}/src" || true
    # The Bash completions, which have no shebang because nothing executes
    # them - they are sourced by an interactive shell, which is exactly why
    # they are worth linting. A syntax error here is not a failed build but a
    # complaint printed at every Tab on a running machine, and the "shell=bash"
    # directive at the top of each file is what lets shellcheck read one.
    find "${ROOT}/rootfs-overlay" "${ROOT}/src" \
        -path '*/completions/*' -type f -print
    # The profile.d snippets, for the same reason and with more of a reach:
    # /etc/profile sources every one of them into every login shell on the
    # system, so a syntax error in one is a login that opens with an error
    # message - or, for the one that exports the locale, a system that quietly
    # stops having a locale. They have no shebang either, being sourced rather
    # than executed.
    find "${ROOT}/rootfs-overlay" "${ROOT}/src" \
        -path '*profile.d/*.sh' -type f -print
}

status=0
mapfile -t shell_scripts < <(shell_sources | sort)
for script in "${shell_scripts[@]}"; do
    bash -n "${script}" || status=1
done

# -x follows the files a script sources, which is what makes the "shellcheck
# source=" directives spread through this repository mean anything: without it
# they are inert, every sourced file is an unknown, and a variable that the
# library defines reads here as a typo. SC1091 stays suppressed for the sources
# that cannot be followed - the ones named by their runtime path on the target.
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -e SC1091 -x "${shell_scripts[@]}" || status=1
fi

awk -F'|' '
    /^[[:space:]]*(#|$)/ { next }
    NF != 6 { printf "%s:%d: expected 6 lock fields, got %d\n", FILENAME, NR, NF > "/dev/stderr"; bad=1 }
    $5 !~ /^[0-9a-f]{64}$/ { printf "%s:%d: invalid SHA-256\n", FILENAME, NR > "/dev/stderr"; bad=1 }
    seen[$1]++ { printf "%s:%d: duplicate source %s\n", FILENAME, NR, $1 > "/dev/stderr"; bad=1 }
    END { exit bad }
' "${ROOT}/config/sources.lock" || status=1

# Release discovery data changes independently of pinned, hashed build inputs,
# but it is still complete by construction: every source has a review link and
# most have a machine-readable check. The checker validates field counts,
# methods, aliases, regular expressions, HTTPS locations and coverage without
# touching the network.
python3 "${ROOT}/scripts/check-updates.py" --validate || status=1

# Mirrors are transport alternatives, never alternative identities. Prefix
# rules rewrite URL beginnings; source rules name exactly one lock row.
awk -F'|' '
    FILENAME ~ /sources[.]lock$/ {
        if ($0 !~ /^[[:space:]]*(#|$)/) { locked[$1] = 1 }
        next
    }
    /^[[:space:]]*(#|$)/ { next }
    {
        if (NF != 3) {
            printf "%s:%d: expected 3 mirror fields, got %d\n", FILENAME, FNR, NF > "/dev/stderr"
            bad = 1
            next
        }
        if ($1 != "prefix" && $1 != "source") {
            printf "%s:%d: unknown mirror rule %s\n", FILENAME, FNR, $1 > "/dev/stderr"
            bad = 1
        }
        if ($1 == "source" && !($2 in locked)) {
            printf "%s:%d: mirror for unknown source %s\n", FILENAME, FNR, $2 > "/dev/stderr"
            bad = 1
        }
        if ($1 == "prefix" && ($2 !~ /^https:\/\// || $3 !~ /^https:\/\//)) {
            printf "%s:%d: mirror prefixes must use HTTPS\n", FILENAME, FNR > "/dev/stderr"
            bad = 1
        }
        if ($1 == "source" && $3 !~ /^https:\/\//) {
            printf "%s:%d: source mirror must use HTTPS\n", FILENAME, FNR > "/dev/stderr"
            bad = 1
        }
        key = $1 SUBSEP $2 SUBSEP $3
        if (seen[key]++) {
            printf "%s:%d: duplicate mirror rule\n", FILENAME, FNR > "/dev/stderr"
            bad = 1
        }
    }
    END { exit bad }
' "${ROOT}/config/sources.lock" "${ROOT}/config/mirrors.conf" || status=1

# The package table has to stay consistent with the lock it draws versions from
# and with itself: an unknown source or dependency only shows up as a failed
# build or an unsatisfiable upgrade otherwise.
awk -F'|' '
    FILENAME ~ /sources\.lock$/ {
        if ($0 !~ /^[[:space:]]*(#|$)/) { locked[$1] = 1 }
        next
    }
    /^[[:space:]]*(#|$)/ { next }
    {
        if (NF != 6) {
            printf "%s:%d: expected 6 package fields, got %d\n", FILENAME, NR, NF > "/dev/stderr"
            bad = 1
        }
        if (seen[$1]++) {
            printf "%s:%d: duplicate package %s\n", FILENAME, NR, $1 > "/dev/stderr"
            bad = 1
        }
        if ($2 != "-" && !($2 in locked)) {
            printf "%s:%d: %s takes its version from unknown source %s\n", FILENAME, NR, $1, $2 > "/dev/stderr"
            bad = 1
        }
        if ($3 !~ /^[0-9]+$/) {
            printf "%s:%d: %s has a non-numeric release\n", FILENAME, NR, $1 > "/dev/stderr"
            bad = 1
        }
        if ($5 != "image" && $5 != "optional") {
            printf "%s:%d: %s has an unknown profile %s\n", FILENAME, NR, $1, $5 > "/dev/stderr"
            bad = 1
        }
        package[$1] = 1
        profile[$1] = $5
        depends[$1] = $4
    }
    END {
        # An image package that depended on an optional one would describe an
        # image that is not installable from the repository it ships with.
        for (name in depends) {
            if (depends[name] == "-") { continue }
            count = split(depends[name], list, ",")
            for (i = 1; i <= count; i++) {
                if (!(list[i] in package)) {
                    printf "config/packages.conf: %s depends on unknown package %s\n", name, list[i] > "/dev/stderr"
                    bad = 1
                }
                if (list[i] == name) {
                    printf "config/packages.conf: %s depends on itself\n", name > "/dev/stderr"
                    bad = 1
                }
                if (profile[name] == "image" && profile[list[i]] == "optional") {
                    printf "config/packages.conf: %s is in the image but depends on the optional package %s\n", name, list[i] > "/dev/stderr"
                    bad = 1
                }
            }
        }
        # A cycle is not a self-dependency with more steps: it is a set of
        # packages none of which can be installed first, and no amount of
        # reading the table one row at a time finds one. Take away every package
        # whose dependencies have already been taken away; whatever is left when
        # a pass takes nothing away is the cycle.
        for (name in package) { pending[name] = 1; total++ }
        while (removed < total) {
            progress = 0
            for (name in pending) {
                if (!pending[name]) { continue }
                blocked = 0
                if (depends[name] != "-" && depends[name] != "") {
                    count = split(depends[name], list, ",")
                    for (i = 1; i <= count; i++) {
                        # "in" rather than a plain lookup: reading a missing key
                        # would add it to the array being walked.
                        if ((list[i] in pending) && pending[list[i]]) {
                            blocked = 1
                            break
                        }
                    }
                }
                if (blocked) { continue }
                pending[name] = 0
                removed++
                progress = 1
            }
            if (!progress) {
                stuck = ""
                for (name in pending) {
                    if (pending[name]) { stuck = stuck (stuck == "" ? "" : " ") name }
                }
                printf "config/packages.conf: dependency cycle among: %s\n", stuck > "/dev/stderr"
                bad = 1
                break
            }
        }
        exit bad
    }
' "${ROOT}/config/sources.lock" "${ROOT}/config/packages.conf" || status=1

# The licence table. A package that reaches the repository without the terms it
# may be redistributed under is the one packaging fault nobody can see by using
# the system afterwards, so the table is held to the package list on both sides:
# every package has exactly one row, and every row names a package. What cannot
# be checked here is whether the file a row names is really in the tarball -
# that needs the sources, and lib/license.sh fails the build over it - but the
# origin has to at least be a source this repository pins, and two texts may not
# be installed under one name.
awk -F'|' '
    FILENAME ~ /sources\.lock$/ {
        if ($0 !~ /^[[:space:]]*(#|$)/) { locked[$1] = 1 }
        next
    }
    FILENAME ~ /packages\.conf$/ {
        if ($0 !~ /^[[:space:]]*(#|$)/) { package[$1] = 1 }
        next
    }
    /^[[:space:]]*(#|$)/ { next }
    {
        if (NF != 4) {
            printf "%s:%d: expected 4 licence fields, got %d\n", FILENAME, FNR, NF > "/dev/stderr"
            bad = 1
            next
        }
        if (!($1 in package)) {
            printf "%s:%d: no package called %s\n", FILENAME, FNR, $1 > "/dev/stderr"
            bad = 1
        }
        if (seen[$1]++) {
            printf "%s:%d: duplicate licence entry for %s\n", FILENAME, FNR, $1 > "/dev/stderr"
            bad = 1
        }
        if ($2 != "sowa" && $2 != "upstream") {
            printf "%s:%d: %s has an unknown copyright holder %s\n", FILENAME, FNR, $1, $2 > "/dev/stderr"
            bad = 1
        }
        if ($3 == "" || $3 == "-") {
            printf "%s:%d: %s names no licence\n", FILENAME, FNR, $1 > "/dev/stderr"
            bad = 1
        }
        if ($4 == "" || $4 == "-") {
            printf "%s:%d: %s names no licence text\n", FILENAME, FNR, $1 > "/dev/stderr"
            bad = 1
            next
        }
        count = split($4, list, ",")
        delete installed
        for (i = 1; i <= count; i++) {
            entry = list[i]
            name = ""
            if (index(entry, "=") > 0) {
                name = substr(entry, index(entry, "=") + 1)
                entry = substr(entry, 1, index(entry, "=") - 1)
            }
            colon = index(entry, ":")
            if (colon == 0) {
                printf "%s:%d: %s: %s is not an origin:path reference\n", \
                    FILENAME, FNR, $1, entry > "/dev/stderr"
                bad = 1
                continue
            }
            origin = substr(entry, 1, colon - 1)
            path = substr(entry, colon + 1)
            if (path == "") {
                printf "%s:%d: %s: %s names no path\n", FILENAME, FNR, $1, entry > "/dev/stderr"
                bad = 1
                continue
            }
            if (origin != "sowa" && !(origin in locked)) {
                printf "%s:%d: %s takes a licence from unknown source %s\n", \
                    FILENAME, FNR, $1, origin > "/dev/stderr"
                bad = 1
            }
            if (name == "") {
                name = path
                sub(/.*\//, "", name)
            }
            if (installed[name]++) {
                printf "%s:%d: %s would install two licence texts as %s; rename one with \"=\"\n", \
                    FILENAME, FNR, $1, name > "/dev/stderr"
                bad = 1
            }
        }
    }
    END {
        for (name in package) {
            if (!(name in seen)) {
                printf "config/licenses.conf: %s has no licence entry\n", name > "/dev/stderr"
                bad = 1
            }
        }
        exit bad
    }
' "${ROOT}/config/sources.lock" "${ROOT}/config/packages.conf" \
    "${ROOT}/config/licenses.conf" || status=1

# The install and removal steps packages declare. What can be checked without a
# build is the shape of them and the vocabulary: that every file names a package
# that exists, and that every line names an event and an action sowa-pkg
# implements. Whether a "setup" names a path the package actually owns needs the
# manifest, so pkg_check_hooks does that one at packaging time.
if compgen -G "${ROOT}/config/hooks/*.hooks" > /dev/null; then
    awk -F'|' '
        BEGIN {
            split("post-install post-upgrade pre-remove", list, " ")
            for (i in list) { event[list[i]] = 1 }
            split("service-start service-stop service-restart service-enable \
service-disable setup", list, " ")
            for (i in list) { action[list[i]] = 1 }
        }
        FILENAME ~ /packages\.conf$/ {
            if ($0 !~ /^[[:space:]]*(#|$)/) { package[$1] = 1 }
            next
        }
        FNR == 1 {
            name = FILENAME
            sub(/.*\//, "", name)
            sub(/\.hooks$/, "", name)
            if (!(name in package)) {
                printf "%s: no package named %s\n", FILENAME, name > "/dev/stderr"
                bad = 1
            }
        }
        /^[[:space:]]*(#|$)/ { next }
        {
            if (NF != 3) {
                printf "%s:%d: expected 3 hook fields, got %d\n", FILENAME, FNR, NF > "/dev/stderr"
                bad = 1
                next
            }
            if (!($1 in event)) {
                printf "%s:%d: %s is not a hook event\n", FILENAME, FNR, $1 > "/dev/stderr"
                bad = 1
            }
            if (!($2 in action)) {
                printf "%s:%d: %s is not a hook action\n", FILENAME, FNR, $2 > "/dev/stderr"
                bad = 1
            }
            if ($3 == "") {
                printf "%s:%d: %s needs an argument\n", FILENAME, FNR, $2 > "/dev/stderr"
                bad = 1
            }
        }
        END { exit bad }
    ' "${ROOT}/config/packages.conf" "${ROOT}"/config/hooks/*.hooks || status=1
fi

# An optional package is published to the repository and never installed into
# the image, which makes it easy to believe that "make <name>" is the only way
# it is ever built. It is not: the rootfs stage cuts every optional package's
# manifest and licence set from its staging tree, and checks the
# command_not_found hints against the commands it carries, so a package that
# rootfs() does not build fails a full build at image/10-rootfs - after everything
# else has been compiled. That is what happened when docker was added to the
# table with a stage and a "make docker" target but no call in rootfs().
#
# The builder is found by which function contains the package's
# run_rootfs_package_stage rather than by adding "_package" to its name, since
# 7zip's is sevenzip_package; reachability is transitive, so grouping several
# into a helper is still correct.
awk -F'|' '
    function visit(name,   i, parts, count) {
        if (name in reached) { return }
        reached[name] = 1
        count = split(calls[name], parts, " ")
        for (i = 1; i <= count; i++) { visit(parts[i]) }
    }
    FILENAME ~ /packages\.conf$/ {
        if ($0 !~ /^[[:space:]]*(#|$)/ && $5 == "optional") { optional[$1] = 1 }
        next
    }
    /^[a-z0-9_]+\(\)[[:space:]]*\{/ {
        current = $0
        sub(/\(\).*/, "", current)
        next
    }
    current == "" { next }
    /^\}/ { current = ""; next }
    {
        if (index($0, "run_rootfs_package_stage") > 0) {
            count = split($0, parts, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                if (parts[i] == "run_rootfs_package_stage") {
                    builder[parts[i + 2]] = current
                    break
                }
            }
        }
        called = $0
        sub(/^[[:space:]]+/, "", called)
        sub(/[[:space:]]+$/, "", called)
        if (called ~ /^[a-z0-9_]+$/) { calls[current] = calls[current] " " called }
    }
    END {
        visit("rootfs")
        for (name in optional) {
            if (!(name in builder)) {
                printf "scripts/build.sh: no stage builds the optional package %s\n", \
                    name > "/dev/stderr"
                bad = 1
            } else if (!(builder[name] in reached)) {
                printf "scripts/build.sh: rootfs() never calls %s(), so a full build would fail in image/10-rootfs with no staged %s\n", \
                    builder[name], name > "/dev/stderr"
                bad = 1
            }
        }
        exit bad
    }
' "${ROOT}/config/packages.conf" "${ROOT}/scripts/build.sh" || status=1

# A package that links another package's shared library has to be rebuilt when
# that library is, and the only thing in the build system that says so is the
# trailing stamp list on the provider's run_rootfs_package_stage call. Leaving
# one out is the quietest mistake this repository can make: nothing fails, the
# build succeeds, and the image ships a binary linked against a library version
# it no longer carries. So the lists are checked against what the staged trees
# actually link, rather than against what anyone remembered to write down.
#
# It needs staging trees, so it is skipped on a checkout that has not been
# built - which is also why "make check" alone cannot be trusted to have run it.
#
# guix takes no part in this. It is unpacked rather than built, and the store in
# its tarball carries its own glibc, OpenSSL and ncurses, so treating it as a
# provider would make it the owner of every library in the image.
check_stage_invalidation() {
    local work="${WORK_DIR:-${ROOT}/work}"
    local stage_dir="${work}/pkgstage"
    local build="${ROOT}/scripts/build.sh"
    local readelf="${work}/tools/bin/${TARGET:-x86_64-sowa-linux-gnu}-readelf"

    [[ -d "${stage_dir}" ]] || return 0
    command -v "${readelf}" > /dev/null 2>&1 || readelf=readelf
    command -v "${readelf}" > /dev/null 2>&1 || return 0

    local -A stage_of=() provider_of=()
    local stage package directory consumer object soname provider function_body
    local gaps=0

    while read -r stage package; do
        [[ "${package}" == - ]] || stage_of["${package}"]="${stage}"
    done < <(grep -oE 'run_rootfs_package_stage [0-9a-zA-Z./-]+ [0-9a-zA-Z.+-]+' "${build}" \
        | awk '{print $2, $3}')

    for directory in "${stage_dir}"/*/; do
        package="$(basename "${directory}")"
        [[ "${package}" == guix ]] && continue
        while IFS= read -r object; do
            provider_of["$(basename "${object}")"]="${package}"
        done < <(find "${directory}" -name '*.so.*' \( -type f -o -type l \) 2>/dev/null)
    done

    for directory in "${stage_dir}"/*/; do
        consumer="$(basename "${directory}")"
        [[ "${consumer}" == guix ]] && continue
        [[ -n "${stage_of[${consumer}]:-}" ]] || continue
        local -A reported=()
        while IFS= read -r object; do
            while IFS= read -r soname; do
                provider="${provider_of[${soname}]:-}"
                [[ -n "${provider}" && "${provider}" != "${consumer}" ]] || continue
                [[ -n "${reported[${provider}]:-}" ]] && continue
                reported["${provider}"]=1
                function_body="$(awk -v want="${provider//-/_}_package() {" '
                    index($0, want) == 1 { inside = 1 }
                    inside { print }
                    inside && /^\}/ { exit }' "${build}")"
                [[ -n "${function_body}" ]] || continue
                grep -q "STAMP_DIR}/${stage_of[${consumer}]}.done" <<< "${function_body}" && continue
                printf '%s: links %s from %s, but %s_package() does not invalidate %s\n' \
                    "scripts/build.sh" "${soname}" "${provider}" \
                    "${provider//-/_}" "${stage_of[${consumer}]}" >&2
                gaps=$((gaps + 1))
            done < <("${readelf}" -d "${object}" 2>/dev/null \
                | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p')
        done < <(find "${directory}" \
            \( -path '*/bin/*' -o -path '*/sbin/*' -o -name '*.so.*' \) -type f 2>/dev/null)
        unset reported
    done

    ((gaps == 0))
}
check_stage_invalidation || status=1

exit "${status}"
