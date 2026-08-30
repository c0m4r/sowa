#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

perl_source="$(prepare_source perl)"
perl_version="$(source_version perl)"
# Perl keys the installed tree by release series: 5.44.0 and a later 5.44.1
# share their modules.
perl_series="${perl_version%.*}"
build_tree="${BUILD_DIR}/perl"
reset_build_dir "${build_tree}"
# Perl has no out-of-tree build - Configure writes into the source directory -
# so the checksum-verified unpacked source is copied and built from the copy.
cp -a "${perl_source}/." "${build_tree}/"
pkgdir="$(pkg_stage perl)"

target_configure_env
cd "${build_tree}"

# Perl is configured, not autoconfigured: Configure compiles small probes and
# *runs* them, and it then runs the miniperl it has just built to construct the
# rest of the build. That works here for the same reason nginx's configure does -
# Sowa's target architecture is the build host's, which scripts/host-check.sh
# insists on - and it is why there is no --host to pass instead. -Dsysroot is
# what keeps the probes looking at the target's headers and libraries rather
# than at the build host's.
#
# The identity fields are pinned rather than probed. Configure would otherwise
# bake the builder's hostname and mail address into Config.pm, and they would be
# published with the package.
#
# -ffile-prefix-map is what keeps the build directory out of the compiled
# objects: XS modules pass __FILE__ to newXS, so without it every extension's
# shared object would carry the absolute path it was compiled from.
sh ./Configure -des \
    -Dcc="${CC}" \
    -Dsysroot="${SYSROOT}" \
    -Accflags="-ffile-prefix-map=${build_tree}=/usr/src/perl" \
    -Dprefix=/usr \
    -Dvendorprefix=/usr \
    -Dprivlib="/usr/lib/perl5/${perl_series}/core_perl" \
    -Darchlib="/usr/lib/perl5/${perl_series}/core_perl" \
    -Dsitelib="/usr/lib/perl5/${perl_series}/site_perl" \
    -Dsitearch="/usr/lib/perl5/${perl_series}/site_perl" \
    -Dvendorlib="/usr/lib/perl5/${perl_series}/vendor_perl" \
    -Dvendorarch="/usr/lib/perl5/${perl_series}/vendor_perl" \
    -Dman1dir=/usr/share/man/man1 \
    -Dman3dir=/usr/share/man/man3 \
    -Dpager=/usr/bin/more \
    -Dmyhostname=localhost \
    -Dperladmin=root@localhost \
    -Dcf_by=sowa \
    -Duseshrplib \
    -Dusethreads
# ExtUtils::MakeMaker records the directory it resolved each library in as
# LD_RUN_PATH, so an extension that links anything outside the compiler's own
# defaults - Time::HiRes and librt is the one that does - comes out with a
# RUNPATH pointing into this checkout's sysroot. Overriding it on the command
# line reaches the sub-makes each extension is built by, and the shared objects
# are left to find their libraries the way every other one in the image does.
make -j"${JOBS}" LD_RUN_PATH=
make DESTDIR="${pkgdir}" LD_RUN_PATH= install

archlib="${pkgdir}/usr/lib/perl5/${perl_series}/core_perl"
[[ -x "${pkgdir}/usr/bin/perl" ]] || die "perl was not installed"
[[ -f "${archlib}/CORE/libperl.so" ]] || die "libperl.so was not installed"
[[ -f "${archlib}/Config.pm" ]] || die "perl's Config.pm was not installed"
[[ -f "${archlib}/auto/POSIX/POSIX.so" ]] \
    || die "the POSIX extension was not built"

# Perl installs its shared objects and its generated configuration read-only,
# so each one is made writable for exactly as long as it takes to rewrite it and
# is then put back the way perl wanted it.
rewrite_in_place() {
    local path="$1"
    shift
    local mode
    mode="$(stat -c '%a' "${path}")"
    chmod u+w "${path}"
    "$@" "${path}"
    chmod "${mode}" "${path}"
}

"${TARGET}-strip" "${pkgdir}/usr/bin/perl"
rewrite_in_place "${archlib}/CORE/libperl.so" "${TARGET}-strip" --strip-unneeded
while IFS= read -r extension; do
    rewrite_in_place "${extension}" "${TARGET}-strip" --strip-unneeded
done < <(find "${archlib}/auto" -type f -name '*.so' -print)

# Configure records the include and library search paths it used, and those are
# all inside this checkout: the sysroot, and the cross compiler's own directories
# under work/tools. They are meaningless on an installed system and would publish
# the build directory, so the sysroot prefix is dropped - leaving the target path
# it stands for - and the toolchain entries are removed whole, since nothing on
# the target corresponds to them. "perl -V" then reports the paths an installed
# perl actually has. Only text files are rewritten - deleting a string from a
# binary would change its length - and the check that follows is what would catch
# one that had it anyway.
while IFS= read -r generated; do
    rewrite_in_place "${generated}" sed -i \
        -e "s|${SYSROOT}||g" \
        -e "s|[^ '\"]*${TOOLS_DIR}[^ '\"]*||g" \
        -e "s|[^ '\"]*${WORK_DIR}[^ '\"]*||g"
done < <({ grep -rlIF "${SYSROOT}" "${pkgdir}"; \
    grep -rlIF "${TOOLS_DIR}" "${pkgdir}"; \
    grep -rlIF "${WORK_DIR}" "${pkgdir}"; } 2>/dev/null | sort -u)
if grep -rqF "${WORK_DIR}" "${pkgdir}" 2>/dev/null; then
    die "the perl installation records the build directory"
fi

"${TARGET}-readelf" -d "${pkgdir}/usr/bin/perl" | grep -q 'libperl.so'
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/perl" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "perl was not built with the cross compiler"
pkg_merge perl
log "installed perl ${perl_version}"
