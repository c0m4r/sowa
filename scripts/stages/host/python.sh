#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# The interpreter that builds the interpreter. It runs here rather than on the
# target, so this stage cross-compiles nothing and deliberately does not call
# target_configure_env.
#
# CPython cannot be cross-compiled without a working Python of the same version
# already running on the build machine: configure takes it as
# --with-build-python and make uses it as FREEZE_MODULE, the program that
# compiles importlib, os, site and the rest of the bootstrap modules into the C
# arrays the target interpreter starts from. The tarball ships none of those
# headers - Python/frozen_modules holds a README and nothing else - so every
# build freezes them again, and the bytecode inside the installed
# /usr/bin/python3.14 is whatever interpreter the build was handed.
#
# Upstream is satisfied by any interpreter agreeing in major.minor, which the
# host's python3 often does. Taking it at that would put whatever 3.14.x compiler
# the build machine carries inside the image and cap the pinned version at what
# every build host already provides. Building the pinned source twice - once
# for here, once for the target - costs a few minutes and removes the host from
# the answer.
#
# Nothing bootstraps this one: a native configure freezes with the
# _bootstrap_python it builds from the same source, so no Python has to exist
# on the build machine at all.

require_command gcc
require_command make

python_source="$(prepare_source python)"
python_version="$(source_version python)"
build_tree="${BUILD_DIR}/host-python"
reset_build_dir "${build_tree}"
# The prefix is keyed by the series, not by the release within it, so an
# interpreter left by an earlier pin would keep its files alongside the new one.
remove_tree "${HOST_PYTHON_DIR}"
cd "${build_tree}"

# A build tool, so nothing is configured for the sake of the finished article:
# no ensurepip (the cross build installs the bundled wheel itself), no readline
# (nothing here is interactive), and no test modules.
"${python_source}/configure" \
    --prefix="${HOST_PYTHON_DIR}" \
    --with-ensurepip=no \
    --without-readline \
    --disable-test-modules
make -j"${JOBS}"
make install

[[ -x "${HOST_PYTHON}" ]] || die "the build python was not installed"
host_python_version="$("${HOST_PYTHON}" -c \
    'import platform; print(platform.python_version())')"
[[ "${host_python_version}" == "${python_version}" ]] \
    || die "the build python reports ${host_python_version}, not the pinned ${python_version}"

# zlib is what makes this interpreter usable for the last step of the cross
# build, where it installs CPython's bundled pip wheel - a deflate-compressed
# zip that zipfile cannot read without the extension. Refuse it here rather
# than an hour into stage packages/python: this is a missing header on the
# build machine, not something the build can put right.
"${HOST_PYTHON}" -c 'import zlib' \
    || die "the build python has no zlib module; install the host zlib development headers"

log "installed the build-time CPython ${python_version}"
