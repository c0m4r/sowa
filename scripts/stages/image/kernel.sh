#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

linux_source="$(prepare_source linux)"
build_tree="${BUILD_DIR}/linux"
fragment="${PROJECT_ROOT}/config/kernel-x86_64.fragment"
reset_build_dir "${build_tree}"

export KBUILD_BUILD_USER=sowa
export KBUILD_BUILD_HOST=builder
export KBUILD_BUILD_VERSION=1
KBUILD_BUILD_TIMESTAMP="$(date --utc --date="@${SOURCE_DATE_EPOCH}" '+%Y-%m-%d %H:%M:%S UTC')"
export KBUILD_BUILD_TIMESTAMP

make -C "${linux_source}" O="${build_tree}" ARCH="${KARCH}" \
    CROSS_COMPILE="${TARGET}-" defconfig
"${linux_source}/scripts/kconfig/merge_config.sh" -m -O "${build_tree}" \
    "${build_tree}/.config" "${fragment}"
make -C "${linux_source}" O="${build_tree}" ARCH="${KARCH}" \
    CROSS_COMPILE="${TARGET}-" olddefconfig

# What the fragment asks for is not necessarily what it gets. merge_config.sh
# warns about a value it had to override and carries on, olddefconfig drops a
# symbol whose dependencies are unmet, and a symbol that has been renamed or
# removed upstream disappears without a word. Every one of those is silent at
# build time and only shows up as a booted system that cannot do something -
# no /dev/net/tun for openvpn, an iptables that answers "Table does not exist",
# a WireGuard interface that cannot be created. The fragment is a statement
# about the image, so it is checked rather than hoped for.
config="${build_tree}/.config"
unmet=()
while IFS= read -r line; do
    # The two ways the fragment says "off". olddefconfig writes the first form
    # and expresses the same thing by leaving the symbol out altogether, so
    # what is checked is that it is not switched on.
    if [[ "${line}" =~ ^#[[:space:]](CONFIG_[A-Z0-9_]+)[[:space:]]is[[:space:]]not[[:space:]]set$ \
        || "${line}" =~ ^(CONFIG_[A-Z0-9_]+)=n$ ]]; then
        if grep -q "^${BASH_REMATCH[1]}=" "${config}"; then
            unmet+=("${BASH_REMATCH[1]} is set, but the fragment turns it off")
        fi
        continue
    fi
    # Comments and blank lines. Anything else is a symbol with a value, and it
    # has to appear in the built configuration exactly as written.
    [[ "${line}" =~ ^CONFIG_[A-Z0-9_]+= ]] || continue
    if ! grep -qxF -- "${line}" "${config}"; then
        unmet+=("${line}")
    fi
done < "${fragment}"
if ((${#unmet[@]})); then
    printf 'error: the kernel configuration fragment did not take effect:\n' >&2
    printf '  %s\n' "${unmet[@]}" >&2
    die "the built kernel would not match ${fragment#"${PROJECT_ROOT}"/}"
fi

make -C "${linux_source}" O="${build_tree}" ARCH="${KARCH}" \
    CROSS_COMPILE="${TARGET}-" -j"${JOBS}" bzImage

kernel_version="$(source_version linux)"
install -m 0644 "${build_tree}/${KERNEL_IMAGE}" \
    "${ARTIFACT_DIR}/vmlinuz-${kernel_version}-${ARTIFACT_ARCH}"
install -m 0644 "${build_tree}/.config" \
    "${ARTIFACT_DIR}/kernel-${kernel_version}-${ARTIFACT_ARCH}.config"
