#!/usr/bin/env bash

# Release-archive policy lives outside common.sh and package.sh deliberately.
# Those two files are inputs to every compiled stage, while changing a
# repository or artifact transport format changes none of the binaries in the
# sysroot. Stages that actually emit XZ include this file in their own keys.

release_package_archive_name() {
    local name="$1"
    local build="$2"
    [[ "${build}" =~ ^[0-9a-f]{64}$ ]] \
        || die "package ${name} has an invalid build id: ${build:-empty}"
    printf '%s-%s-%s-%s-%s.tar.xz\n' \
        "${DISTRO_NAME}" "${name}" "$(package_version "${name}")" \
        "${PKG_ARCH}" "${build}"
}

# Do not select a numbered preset. Current XZ chooses its normal balance of
# speed, memory and size, including its default threading. Clear the two
# option-bearing environment variables so a builder's shell cannot silently
# turn the release into a -9 or --extreme build.
xz_compress_default() {
    XZ_DEFAULTS='' XZ_OPT='' xz --stdout "$@"
}

xz_test_stream() {
    XZ_DEFAULTS='' XZ_OPT='' xz --test
}

xz_stream_uses_check() {
    local expected="$1"
    local archive="$2"
    XZ_DEFAULTS='' XZ_OPT='' xz --robot --list "${archive}" \
        | awk -F '\t' -v expected="${expected}" '
            $1 == "file" { found=1; check=$7 }
            END { exit !(found && check == expected) }
        '
}
