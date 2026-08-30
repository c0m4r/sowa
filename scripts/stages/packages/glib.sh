#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GLib, the C utility library syslog-ng is written against.
#
# It is here for one consumer and would not otherwise be in the image. It is a
# package rather than a private static library - the way nginx's PCRE2 and
# logrotate's popt are - because syslog-ng is not one program: it is a small
# binary, a core library, and around thirty modules it dlopens at start-up
# through gmodule. A statically absorbed GLib would be linked into the core
# library alone, and a module reaching for a GLib function the core happens not
# to call would fail to resolve at dlopen time - which is a broken module on a
# running machine rather than a failed build. So GLib is shared, and everything
# syslog-ng loads resolves against the same copy.
#
# Its dependencies go two different ways. PCRE2 is what GLib's GRegex is made
# of and syslog-ng also requires it directly, so it is the shared package built
# immediately before this one. libffi is only what GObject's closures are made
# of, so it remains a private static library absorbed here.
#
# GLib is a meson project and does not cross-compile from the environment: CC
# and friends describe the *build* machine, and everything about the target
# comes from a cross file. packages/plocate.sh explains that at length; this
# stage differs from it in one way worth stating: one dependency is private in
# a build directory while PCRE2 and zlib are in the sysroot. A small private
# pkg-config directory below rewrites those two .pc prefixes to absolute
# sysroot paths and leaves libffi's already-absolute prefix alone.

require_command meson
require_command ninja
require_command pkg-config

libffi_source="$(prepare_source libffi)"
glib_source="$(prepare_source glib)"

libffi_build="${BUILD_DIR}/glib-libffi"
libffi_root="${BUILD_DIR}/glib-libffi-root"
build_tree="${BUILD_DIR}/glib"
reset_build_dir "${libffi_build}"
reset_build_dir "${libffi_root}"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage glib)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env

# libffi is linked into a shared object, so its static archive must be PIC. An
# archive of non-PIC objects fails only at the final GLib link on x86_64.
cd "${libffi_build}"
"${libffi_source}/configure" \
    --prefix="${libffi_root}" \
    --libdir="${libffi_root}/lib" \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-shared \
    --enable-static \
    --with-pic \
    --disable-docs \
    --disable-multi-os-directory
make -j"${JOBS}"
make install
[[ -f "${libffi_root}/lib/libffi.a" ]] || die "the static libffi for GLib was not built"

dependency_pc="${build_tree}/pkgconfig"
mkdir -p "${dependency_pc}"
for module in libpcre2-8 zlib; do
    source_pc="${SYSROOT}/usr/lib64/pkgconfig/${module}.pc"
    [[ -f "${source_pc}" ]] || die "GLib needs ${module}.pc from the sysroot"
    sed -e "s|^prefix=/usr$|prefix=${SYSROOT}/usr|" \
        "${source_pc}" > "${dependency_pc}/${module}.pc"
done
[[ -f "${libffi_root}/lib/pkgconfig/libffi.pc" ]] \
    || die "the private libffi did not install libffi.pc"
cp "${libffi_root}/lib/pkgconfig/libffi.pc" "${dependency_pc}/libffi.pc"

cross_file="${build_tree}/cross.ini"
mkdir -p "${build_tree}"
cat > "${cross_file}" <<EOF
[binaries]
c = '${TARGET}-gcc'
cpp = '${TARGET}-g++'
ar = '${TARGET}-ar'
strip = '${TARGET}-strip'
pkg-config = 'pkg-config'

[properties]
pkg_config_libdir = '${dependency_pc}'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${dependency_pc}"
unset PKG_CONFIG_SYSROOT_DIR

# --wrap-mode=nodownload is the one that has to be there rather than the one
# that is tidy: GLib ships wrap files for PCRE2 and libffi, and without this a
# build that failed to find either would quietly try to fetch it from the
# network instead of failing. Everything after it is a subsystem this image
# does not have and must not be autodetected into:
#
#   libmount   util-linux's, which is in the sysroot and would be found. GIO
#              uses it to watch /proc/self/mountinfo; nothing here reads GIO's
#              mount monitor, and it would make GLib depend on util-linux.
#   libelf     used only to read GResource sections out of ELF files.
#   selinux, xattr, dtrace, systemtap, sysprof, nls, introspection: no policy,
#              no attributes on a squashfs built -all-root, no tracing
#              framework, no gettext catalogues, no GObject introspection.
meson setup "${build_tree}/obj" "${glib_source}" \
    --cross-file="${cross_file}" \
    --prefix=/usr \
    --bindir=bin \
    --libdir=lib64 \
    --mandir=share/man \
    --buildtype=release \
    --wrap-mode=nodownload \
    -Ddefault_library=shared \
    -Dlibmount=disabled \
    -Dlibelf=disabled \
    -Dselinux=disabled \
    -Dxattr=false \
    -Ddtrace=disabled \
    -Dsystemtap=disabled \
    -Dsysprof=disabled \
    -Dnls=disabled \
    -Dintrospection=disabled \
    -Dman-pages=disabled \
    -Ddocumentation=false \
    -Dtests=false \
    -Dinstalled_tests=false \
    -Dglib_assert=false \
    -Dglib_checks=false \
    -Dmultiarch=false

ninja -C "${build_tree}/obj" -j "${JOBS}"
DESTDIR="${pkgdir}" ninja -C "${build_tree}/obj" install

# The generated GObject and GIRepository metadata names libffi in
# Requires.private. These are shared-only libraries in Sowa, and their libffi
# code is already absorbed into the DSOs, so retaining that token would make a
# downstream `pkg-config --static` search for a package the image deliberately
# does not ship.
for file in "${pkgdir}/usr/lib64/pkgconfig"/*.pc; do
    sed -E -i \
        -e 's/(^Requires\.private:.*), libffi( >= +[^,]+)?$/\1/' \
        -e 's/^Requires\.private: libffi( >= +[^,]+)?$/Requires.private:/' \
        "${file}"
done
for module in glib-2.0 gobject-2.0 gmodule-2.0 gio-2.0 gthread-2.0 \
    girepository-2.0; do
    file="${pkgdir}/usr/lib64/pkgconfig/${module}.pc"
    [[ -f "${file}" ]] || die "GLib did not install ${module}.pc"
    if grep -qE 'libffi|-lffi' "${file}"; then
        die "${module}.pc names the private libffi absorbed into GObject"
    fi
done

for library in libglib-2.0 libgobject-2.0 libgmodule-2.0 libgio-2.0 libgthread-2.0 \
    libgirepository-2.0; do
    [[ -f "${pkgdir}/usr/lib64/${library}.so.0" ]] \
        || die "GLib did not install ${library}.so.0"
    "${TARGET}-strip" --strip-unneeded "${pkgdir}/usr/lib64/${library}.so.0"
done
while IFS= read -r -d '' program; do
    if "${TARGET}-readelf" -h "${program}" >/dev/null 2>&1; then
        "${TARGET}-strip" --strip-unneeded "${program}"
    fi
done < <(find "${pkgdir}/usr/bin" "${pkgdir}/usr/libexec" -type f -perm /111 \
    -print0 2>/dev/null)

# The dependency split, asserted rather than assumed: PCRE2 is shared, while a
# build that found a shared libffi somewhere would record an unavailable ABI.
needed="$("${TARGET}-readelf" -d "${pkgdir}/usr/lib64/libglib-2.0.so.0")"
grep -q 'libpcre2-8.so.0' <<< "${needed}" \
    || die "libglib does not link the shared PCRE2 package"
for unwanted in libffi libmount libselinux libelf; do
    if grep -q "${unwanted}" <<< "${needed}"; then
        die "libglib-2.0 links ${unwanted}; the image has no such library"
    fi
done
while IFS= read -r library; do
    case "${library}" in
        libpcre2-8.so.0 | libz.so.1 | libm.so.6 | libgcc_s.so.1 | libc.so.6) ;;
        *) die "libglib-2.0 needs ${library}, which the image does not ship" ;;
    esac
done < <(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' <<< "${needed}")

gobject_needed="$("${TARGET}-readelf" -d "${pkgdir}/usr/lib64/libgobject-2.0.so.0")"
grep -q 'libglib-2.0.so.0' <<< "${gobject_needed}" \
    || die "GObject does not link GLib"
if grep -q 'libffi' <<< "${gobject_needed}"; then
    die "GObject links a shared libffi; the image carries only the absorbed copy"
fi
if grep -qE 'RPATH|RUNPATH' <<< "${needed}"; then
    die "GLib carries a run-time library path"
fi
# GRegex is the reason GLib links PCRE2; retain its exported entry point too.
symbols="$("${TARGET}-nm" -D --defined-only \
    "${pkgdir}/usr/lib64/libglib-2.0.so.0")"
grep -qE ' [TW] g_regex_new(@|$)' <<< "${symbols}" \
    || die "GLib was built without GRegex; syslog-ng's filters need it"

cross_gcc_version="$("${CC}" -dumpfullversion)"
compiler_comment="$("${TARGET}-readelf" -p .comment \
    "${pkgdir}/usr/lib64/libglib-2.0.so.0")"
grep -q "GCC: (GNU) ${cross_gcc_version}" <<< "${compiler_comment}" \
    || die "GLib was not built with the cross compiler"

# The tools GLib installs are for people building against it. Only the ones the
# image can use are kept: gdbus-codegen and glib-genmarshal are Python and
# would need the interpreter at run time for a job nobody does on a running
# machine, and the GIO modules directory is for loadable back-ends the image
# has none of.
for tool in gdbus-codegen glib-genmarshal glib-mkenums gtester-report \
    glib-gettextize; do
    rm -f "${pkgdir}/usr/bin/${tool}"
done
rm -rf "${pkgdir}/usr/share/glib-2.0/codegen" \
    "${pkgdir}/usr/share/glib-2.0/gettext" \
    "${pkgdir}/usr/share/gettext" \
    "${pkgdir}/usr/share/gdb" \
    "${pkgdir}/usr/share/bash-completion"
find "${pkgdir}" -type d -empty -delete

leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "GLib carries a build path: ${leaked}"

pkg_merge glib
log "installed GLib $(source_version glib)"
