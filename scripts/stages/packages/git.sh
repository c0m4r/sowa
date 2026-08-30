#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Git. It is the one program here with no configure script worth using: the
# tarball ships none, and upstream's own way to build it is to hand make the
# handful of variables that would otherwise be probed. That suits a cross build
# better than the alternative, because every probe that would have to be
# answered by running a target binary is instead something said outright below.
#
# Everything Git links against is already in the image - zlib, OpenSSL, curl and
# its CA bundle, Perl - so the only thing built here besides Git is the PCRE2
# that "git grep -P" needs, as a private static library in the same way nginx
# builds one.

pcre2_source="$(prepare_source pcre2)"
git_source="$(prepare_source git)"
manpages="$(locked_download_path git-manpages)"
pcre2_build="${BUILD_DIR}/git-pcre2"
pcre2_root="${BUILD_DIR}/git-pcre2-root"
build_tree="${BUILD_DIR}/git"
reset_build_dir "${pcre2_build}"
reset_build_dir "${pcre2_root}"
reset_build_dir "${build_tree}"
# Git builds in its own source tree, so the verified source is copied and the
# copy is what is built.
cp -a "${git_source}/." "${build_tree}/"
pkgdir="$(pkg_stage git)"

build_triplet="$(sh "${pcre2_source}/config.guess")"
target_configure_env

# Only the 8-bit code units Git uses, and JIT left off: it would compile a
# regular expression to machine code at run time, which is a memory mapping
# Git's use of PCRE2 does not repay.
cd "${pcre2_build}"
"${pcre2_source}/configure" \
    --prefix="${pcre2_root}" \
    --libdir="${pcre2_root}/lib" \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-shared \
    --enable-static \
    --disable-pcre2-16 \
    --disable-pcre2-32 \
    --disable-pcre2grep-libz \
    --disable-pcre2grep-libbz2
make -j"${JOBS}"
make install
[[ -f "${pcre2_root}/lib/libpcre2-8.a" ]] || die "the static PCRE2 was not built"

# What Git is on this system, one variable at a time:
#
#   NO_GETTEXT      the image carries no message catalogues and no locale data,
#                   so Git speaks English and does not look for a translation
#   NO_TCLTK        there is no X11 here, so no gitk and no git-gui
#   NO_PYTHON       git-p4 talks to Perforce; nothing else in Git needs Python
#   NO_EXPAT        the only thing an XML parser buys Git is pushing over the
#                   old WebDAV transport, which no server has needed since the
#                   smart HTTP protocol
#   NO_RUST         Git 2.55 builds part of itself in Rust, through cargo,
#                   which knows nothing about the toolchain this image is made
#                   with: it would compile for the build host's target and its
#                   glibc, and the result only links here because both sides
#                   happen to be x86_64. There is no Rust cross toolchain in
#                   Sowa and no host check that asks for one, so the C
#                   implementations of the same subsystems are what is built
#   INSTALL_SYMLINKS  Git installs one binary and around a hundred names for
#   NO_INSTALL_HARDLINKS  it. Hard links would be a hundred copies once a
#                   package archive has been unpacked file by file, so the
#                   names are symbolic links instead - which is also the only
#                   one of the three shapes a package manifest can describe
#   CURL_CONFIG     the curl in the sysroot, not the one on the build host:
#                   Git asks it for the version, and the version decides which
#                   HTTP transports it builds
#   CURL_LDFLAGS    -lcurl, rather than what curl-config would answer, because
#                   that answer is a -L into the host's /usr/lib64
#   CC_LD_DYNPATH   emptied. Git pairs every -L it is given with a run path to
#                   the same directory, and the PCRE2 directory below is inside
#                   this checkout's build tree: linking statically against it is
#                   fine, telling the shipped binaries to search it at run time
#                   is a build machine's path in a published package
#
# Nothing sets a pager or an editor: Git's defaults are less and vi, and the
# image has both - GNU less, which takes the -FRX Git starts it with, and vi as
# the link to Vim in /bin.
git_make=(
    CC="${CC}"
    AR="${AR}"
    prefix=/usr
    gitexecdir=/usr/libexec/git-core
    PERL_PATH=/usr/bin/perl
    SHELL_PATH=/bin/bash
    NO_GETTEXT=1
    NO_TCLTK=1
    NO_PYTHON=1
    NO_EXPAT=1
    NO_RUST=1
    USE_LIBPCRE2=1
    LIBPCREDIR="${pcre2_root}"
    CURL_CONFIG="${SYSROOT}/usr/bin/curl-config"
    CURL_CFLAGS=
    CURL_LDFLAGS=-lcurl
    CC_LD_DYNPATH=
    INSTALL_SYMLINKS=1
    NO_INSTALL_HARDLINKS=1
)

cd "${build_tree}"
make -j"${JOBS}" "${git_make[@]}"
make "${git_make[@]}" DESTDIR="${pkgdir}" install

# Git's documentation is asciidoc, and building it would put asciidoc, xmlto and
# a DocBook toolchain on the list of things a build host needs. Upstream
# publishes the formatted manual pages as their own tarball for exactly this
# reason, so that is what the image gets - the same version, from the same
# directory, pinned the same way.
install -d -m 0755 "${pkgdir}/usr/share/man"
validate_archive_members "${manpages}"
tar -xf "${manpages}" -C "${pkgdir}/usr/share/man"
[[ -f "${pkgdir}/usr/share/man/man1/git-commit.1" ]] \
    || die "the Git manual pages were not unpacked"

while IFS= read -r program; do
    "${TARGET}-readelf" -h "${program}" > /dev/null 2>&1 || continue
    "${TARGET}-strip" "${program}"
done < <(find "${pkgdir}/usr/bin" "${pkgdir}/usr/libexec/git-core" -type f)

[[ -x "${pkgdir}/usr/bin/git" ]] || die "git was not installed"
for program in git-receive-pack git-upload-pack git-upload-archive git-shell; do
    [[ -e "${pkgdir}/usr/bin/${program}" ]] || die "git did not install ${program}"
done
# The transports. A Git without these is a Git that can only reach a repository
# on the same machine: git-remote-http is what an https:// remote is fetched
# with, and the ssh:// and git:// ones are built into the git binary itself.
for transport in git-remote-http git-remote-https git-http-fetch; do
    [[ -e "${pkgdir}/usr/libexec/git-core/${transport}" ]] \
        || die "git did not install ${transport}"
done
[[ -f "${pkgdir}/usr/share/git-core/templates/description" ]] \
    || die "the repository templates were not installed"
# One binary and a hundred names for it, as symbolic links rather than as a
# hundred copies.
[[ -L "${pkgdir}/usr/libexec/git-core/git-receive-pack" ]] \
    || die "git-receive-pack is a copy of git rather than a link to it"

# Nothing may point at a directory of the build host, which is what a run path
# to the static PCRE2 above would be.
while IFS= read -r program; do
    "${TARGET}-readelf" -h "${program}" > /dev/null 2>&1 || continue
    if "${TARGET}-readelf" -d "${program}" | grep -qE 'R(UN)?PATH'; then
        die "${program#"${pkgdir}"} carries a run path into the build tree"
    fi
done < <(find "${pkgdir}/usr/bin" "${pkgdir}/usr/libexec/git-core" -type f)

"${TARGET}-readelf" -d "${pkgdir}/usr/bin/git" | grep -q 'libz.so.1' \
    || die "git is not linked against zlib"
"${TARGET}-readelf" -d "${pkgdir}/usr/libexec/git-core/git-remote-http" \
    | grep -q 'libcurl.so.4' \
    || die "git-remote-http is not linked against libcurl; https remotes would not work"
# PCRE2 is linked in rather than loaded, so it shows in what the binary knows
# rather than in what it needs.
git_strings="$("${TARGET}-strings" "${pkgdir}/usr/bin/git")"
grep -qF 'pcre2_' <<< "${git_strings}" \
    || die "git was built without PCRE2; \"git grep -P\" would refuse to run"
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/git" | grep -q 'libpcre2'; then
    die "git links a shared PCRE2, which the image has not got"
fi
grep -qxF /usr/libexec/git-core <<< "${git_strings}" \
    || die "git does not know where its own commands were installed"
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/git" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "git was not built with the cross compiler"
pkg_merge git
log "installed Git $(source_version git)"
