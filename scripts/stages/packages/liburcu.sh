#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Userspace RCU, the read-copy-update library.
#
# The second of the three dependencies packages/bind cannot be built without.
# BIND reads its caches and zone databases from many query threads at once and
# writes them from few, which is the shape RCU is for: a reader takes no lock
# and the writer publishes a new version beside the old one, so lookups do not
# serialise against each other. Since 9.19.7 this is not optional and there is
# no flag to refuse it.
#
# Upstream builds several flavours of the same library, which differ only in
# how a reader announces that it is inside a critical section. BIND asks for
# the membarrier flavour, which pkg-config calls plain "liburcu", and for the
# lock-free data structures in "liburcu-cds". All of them are installed rather
# than pruned to those two: they share liburcu-common, they are a few tens of
# kilobytes each, and each one's .pc file names the others, so a partial
# install is a set of pkg-config files that describe libraries that are not
# there.
#
# The membarrier fallback is left on. It is what the library uses when the
# kernel it is running on has no sys_membarrier, and turning it off would trade
# a kernel configuration this image controls today for a startup abort on any
# kernel it does not.

liburcu_source="$(prepare_source userspace-rcu)"
build_tree="${BUILD_DIR}/liburcu"
reset_build_dir "${build_tree}"
# Built in a copy of the source rather than beside it. urcu_die() - the report
# it makes before it aborts, not an assertion - quotes __FILE__ in a format
# string that is compiled in unconditionally, so NDEBUG does not remove it and
# an out-of-tree build writes the builder's home directory into all six
# libraries, which is what pkg_merge's build-path check rejects.
cp -a "${liburcu_source}/." "${build_tree}/"
pkgdir="$(pkg_stage liburcu)"

# AC_CONFIG_AUX_DIR puts the helper scripts in config/ rather than at the top.
build_triplet="$(sh "${liburcu_source}/config/config.guess")"
target_configure_env
cd "${build_tree}"
# A release build of a library should not be checking its own invariants at
# every call.
export CPPFLAGS="-DNDEBUG"
./configure \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-static \
    --disable-silent-rules
# No --disable-rpath here either, so the generated libtool is edited the way
# packages/file and packages/libuv edit theirs.
sed -i -e 's|^hardcode_libdir_flag_spec=.*|hardcode_libdir_flag_spec=""|' \
    -e 's|^runpath_var=LD_RUN_PATH|runpath_var=|' libtool
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

rm -f "${pkgdir}"/usr/lib64/*.la
# The API documents are kept; the examples beside them are not. They are sixty
# files of sample programs and the makefiles that build them out of the source
# tree, which is a build tree rather than documentation and does not build
# anywhere else.
rm -rf "${pkgdir}/usr/share/doc/userspace-rcu/examples"

# The three BIND actually links, plus the flavours that come with them. Each is
# stripped and checked for a soname, because a library without one cannot be
# recorded as a dependency by anything that links it.
for flavour in liburcu liburcu-common liburcu-cds \
    liburcu-bp liburcu-mb liburcu-memb liburcu-qsbr; do
    library="$(find "${pkgdir}/usr/lib64" -type f -name "${flavour}.so.8*" -print -quit)"
    [[ -n "${library}" ]] || die "the ${flavour} shared library was not installed"
    "${TARGET}-strip" "${library}"
    "${TARGET}-readelf" -d "${library}" | grep -q "SONAME.*${flavour}\.so\.8" \
        || die "${flavour} carries no soname"
    if "${TARGET}-readelf" -d "${library}" | grep -qE 'RPATH|RUNPATH'; then
        die "${flavour} carries a run-time library path"
    fi
    [[ ! -e "${pkgdir}/usr/lib64/${flavour}.a" ]] \
        || die "${flavour} installed a static library; the image ships none"
    for link in "${flavour}.so" "${flavour}.so.8"; do
        [[ -L "${pkgdir}/usr/lib64/${link}" ]] \
            || die "the ${link} symbolic link is missing"
    done
done

# The two pkg-config names BIND's configure asks for by name, and the version
# comparison it makes against them. Getting either wrong stops packages/bind
# rather than this stage.
liburcu_version="$(source_version userspace-rcu)"
for module in liburcu liburcu-cds; do
    pkgconfig_file="${pkgdir}/usr/lib64/pkgconfig/${module}.pc"
    [[ -f "${pkgconfig_file}" ]] || die "the ${module} pkg-config file was not installed"
    grep -q '^libdir=/usr/lib64$' "${pkgconfig_file}" \
        || die "${module}.pc does not point at /usr/lib64"
    grep -qx "Version: ${liburcu_version}" "${pkgconfig_file}" \
        || die "${module}.pc does not declare version ${liburcu_version}"
done
[[ -f "${pkgdir}/usr/include/urcu.h" ]] || die "urcu.h was not installed"
[[ -f "${pkgdir}/usr/include/urcu/rculfhash.h" ]] \
    || die "the lock-free hash table header was not installed; BIND includes it directly"
membarrier="$(find "${pkgdir}/usr/lib64" -type f -name 'liburcu.so.8*' -print -quit)"
# The membarrier flavour's own entry points, read back from the library. A
# liburcu built as some other flavour would still be called liburcu.so.
for symbol in urcu_memb_read_lock urcu_memb_synchronize_rcu; do
    "${TARGET}-nm" -D --defined-only "${membarrier}" | grep -qE " T ${symbol}(@|$)" \
        || die "liburcu does not export ${symbol}; it is not the membarrier flavour BIND asks for"
done
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${membarrier}" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "liburcu was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "liburcu installed files containing the build path: ${leaked}"
pkg_merge liburcu
log "installed Userspace RCU ${liburcu_version}"
