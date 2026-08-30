#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

python_source="$(prepare_source python)"
python_version="$(source_version python)"
# The interpreter that freezes this one's bootstrap modules into it and then
# installs its pip. Stage host/python builds it from this same tarball for
# the build machine, which makes the frozen bytecode the pinned release's own
# rather than the build host's; asking it its version keeps that a fact rather
# than an assumption.
build_python="${HOST_PYTHON}"
[[ -x "${build_python}" ]] || die "the build python is missing; run stage host/python"
build_python_version="$("${build_python}" -c \
    'import platform; print(platform.python_version())')"
[[ "${build_python_version}" == "${python_version}" ]] \
    || die "the build python is ${build_python_version}, not the pinned ${python_version}; rerun stage host/python"

build_tree="${BUILD_DIR}/python"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage python)"
build_triplet="$(gcc -dumpmachine)"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"

# The _uuid extension is refused rather than left to chance. CPython's configure
# links it against whatever libuuid it finds, and what it finds depends on which
# stages have already populated the sysroot: e2fsprogs used to leave a static,
# non-PIC libuuid.a there, which fails to link into a shared object with
# "relocation R_X86_64_32 ... recompile with -fPIC", and util-linux now leaves a
# shared one, which would link but would make the interpreter depend on it. The
# stdlib uuid module works without the extension either way, so the answer is
# stated here instead of following from stage order.
ac_cv_buggy_getaddrinfo=no \
ac_cv_file__dev_ptc=no \
ac_cv_file__dev_ptmx=yes \
py_cv_module__uuid=n/a \
"${python_source}/configure" \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-build-python="${build_python}" \
    --with-system-libmpdec=no \
    --with-ensurepip=no \
    --with-openssl-rpath=no \
    --without-readline \
    --disable-test-modules
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

pip_wheel="$(find "${python_source}/Lib/ensurepip/_bundled" \
    -type f -name 'pip-*.whl' -print -quit)"
[[ -n "${pip_wheel}" ]] || die "CPython's bundled pip wheel is missing"
PIP_DISABLE_PIP_VERSION_CHECK=1 \
PIP_NO_CACHE_DIR=1 \
PYTHONPATH="${pip_wheel}" \
"${build_python}" -m pip install \
    --root="${pkgdir}" \
    --prefix=/usr \
    --no-compile \
    --no-deps \
    --no-index \
    --ignore-installed \
    "${pip_wheel}"

# pip writes the path of the interpreter that ran it into the console scripts it
# generates, and that interpreter is now one inside the build tree - a path that
# exists on this machine and nowhere else. The scripts run on the target, so the
# interpreter they name is the one the image installs. This was invisible while
# the build python was the host's /usr/bin/python3: the path it wrote happened
# to be a path the target also has.
for pip_script in pip pip3 pip3.14; do
    pip_script_path="${pkgdir}/usr/bin/${pip_script}"
    [[ -f "${pip_script_path}" ]] || die "pip did not install ${pip_script}"
    sed -i '1s|^#!.*|#!/usr/bin/python3.14|' "${pip_script_path}"
    if grep -qF "${WORK_DIR}" "${pip_script_path}"; then
        die "${pip_script} records the build directory"
    fi
done

"${TARGET}-strip" "${pkgdir}/usr/bin/python3.14"
while IFS= read -r extension; do
    "${TARGET}-strip" "${extension}"
done < <(find "${pkgdir}/usr/lib/python3.14/lib-dynload" \
    -type f -name '*.so' -print)
ln -sfn python3.14 "${pkgdir}/usr/bin/python3"
ln -sfn python3 "${pkgdir}/usr/bin/python"

[[ -x "${pkgdir}/usr/bin/python3.14" ]] || die "CPython was not installed"
[[ -L "${pkgdir}/usr/bin/python3" ]] || die "Python 3 link was not installed"
[[ -x "${pkgdir}/usr/bin/pip3" ]] || die "pip was not installed"
[[ -f "${pkgdir}/usr/lib/python3.14/ssl.py" ]] \
    || die "Python ssl standard-library module was not installed"
[[ -n "$(find "${pkgdir}/usr/lib/python3.14/lib-dynload" \
    -type f -name '_ssl*.so' -print -quit)" ]] || die "Python _ssl extension was not built"
[[ -n "$(find "${pkgdir}/usr/lib/python3.14/lib-dynload" \
    -type f -name 'zlib*.so' -print -quit)" ]] || die "Python zlib extension was not built"
[[ -z "$(find "${pkgdir}/usr/lib/python3.14/lib-dynload" \
    -type f -name '_uuid*.so' -print -quit)" ]] \
    || die "the _uuid extension was built; Python is meant not to depend on a libuuid"
"${TARGET}-readelf" -l "${pkgdir}/usr/bin/python3.14" \
    | grep -q 'Requesting program interpreter'
pkg_merge python
log "installed CPython ${python_version}"
