#!/usr/bin/env bash
#
# What a stage's key is made of, and what it is.
#
# A keyed stamp answers "should this stage run again" precisely, which is what
# makes an incremental build trustworthy - and completely opaque when the answer
# is yes and nobody expected it. This prints the inputs as text, so the line
# that moved can be found by comparing two runs:
#
#   ./scripts/stage-key.sh packages/openssh > before
#   ...edit something...
#   ./scripts/stage-key.sh packages/openssh | diff before -

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

name="${1:-}"
[[ -n "${name}" ]] || die "usage: $0 <stage> (for example packages/openssh)"

script="${PROJECT_ROOT}/scripts/stages/${name}.sh"
[[ -f "${script}" ]] || die "no such stage: ${name}"

# Which package a stage builds is written in the driver, and the key differs
# between the two cases: a stage with a package carries that package's rows,
# one without carries the whole tables. Read through the shared table, so this
# and the build cannot disagree about which case a stage is in.
package="$(stage_package_name "${name}")"

stage_inputs "${name}" "${script}" "${package}"
printf -- '---\n'
printf 'key %s\n' "$(stage_key "${name}" "${script}" "${package}")"
recorded="${STAMP_DIR}/${name}.done"
if [[ -f "${recorded}" ]]; then
    printf 'recorded %s\n' "$(cat "${recorded}")"
    if stage_up_to_date "${name}" "${script}" "${package}"; then
        printf 'status current\n'
    else
        printf 'status stale; the next build reruns it\n'
    fi
else
    printf 'status never built\n'
fi
