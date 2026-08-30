#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GNU Wget.
#
# curl is already in the image and fetches a single URL better than this does,
# so the case for Wget is the part curl has never had: -r, -m and -np, which
# walk a site rather than name a file. That, and the fact that every script
# written outside this distribution reaches for "wget -O-" without asking
# whether the image has it.
#
# Wget carries gnulib, which probes the host for a long list of replacement
# functions. Everything it looks for is in glibc 2.44, so nothing here has to
# pin a cache variable; what does have to be spelled out is the optional
# libraries, since the sysroot has zlib and OpenSSL and Wget would find and use
# both while silently doing without the four it cannot find.

require_command perl
wget_source="$(prepare_source wget)"
build_tree="${BUILD_DIR}/wget"
reset_build_dir "${build_tree}"
# Built in a copy of the source rather than beside it. Wget compiles the whole
# compiler command line into the binary for "wget --version" to print, and
# asserts with __FILE__, so an out-of-tree build - where configure spells srcdir
# absolutely - ships the builder's home directory inside /usr/bin/wget. In-tree
# those paths are relative, which is also how iproute2, Git and nic are built.
cp -a "${wget_source}/." "${build_tree}/"
pkgdir="$(pkg_stage wget)"

# Wget ships doc/wget.pod rather than a built wget.1, so the manual page exists
# only if pod2man runs. It comes with Perl but is not always on PATH, and
# configure gives up quietly when it is missing, leaving an image whose
# downloader has no manual. Perl is asked where its own scripts live instead of
# guessing at the path.
pod2man="$(perl -MConfig -e 'print "$Config{scriptdirexp}/pod2man"')"
[[ -x "${pod2man}" ]] || die "pod2man was not found at ${pod2man}; wget.1 comes from it"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"
# --without-libpsl is not optional in the sense the others are: without it
# configure stops rather than building a Wget that cannot check a cookie
# domain against the public suffix list. The image has no libpsl, so Wget is
# built the way it was before that list existed - it still refuses a cookie
# for a bare TLD, it just cannot refuse one for "co.uk".
#
# --with-ssl=openssl picks the TLS backend the rest of the image already links;
# the GnuTLS alternative would mean a second TLS stack. It is given no
# --with-libssl-prefix on purpose: the cross compiler already searches its own
# sysroot, while the prefix makes gnulib link the libraries by absolute build
# path and Wget bakes that path into the "Link:" line "wget --version" prints -
# putting the builder's home directory in a shipped binary. Certificate
# verification then falls to OpenSSL's built-in default paths, which are
# /etc/ssl/cert.pem and /etc/ssl/certs - exactly where
# packages/ca-certificates.sh installs the Mozilla bundle - so no
# --ca-certificate default has to be compiled in or written into /etc/wgetrc.
#
# --with-openssl is a different switch from --with-ssl: it hands the MD5 and
# SHA hashes Wget uses for digest auth and --checksum to libcrypto instead of
# gnulib's own implementations, which is code the image is already carrying.
#
# The four refusals are libraries the sysroot does not have (libpsl, libidn2
# behind --disable-iri, PCRE and PCRE2 behind the two --disable-pcre switches -
# the image's PCRE2 is a static one private to nginx and Git) and one it does
# have and should not use here: libuuid, wanted only to stamp WARC archives
# with a record ID. Extended attributes go the same way as in GNU tar and
# coreutils, which are also built without them.
POD2MAN="${pod2man}" ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-nls \
    --disable-rpath \
    --disable-iri \
    --disable-pcre \
    --disable-pcre2 \
    --disable-xattr \
    --with-ssl=openssl \
    --with-openssl \
    --with-zlib \
    --without-libpsl \
    --without-libuuid \
    --without-metalink \
    --without-cares \
    --without-linux-crypto
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/bin/wget"
[[ -x "${pkgdir}/usr/bin/wget" ]] || die "wget was not installed"
[[ -f "${pkgdir}/etc/wgetrc" ]] || die "the wget configuration was not installed"
[[ -f "${pkgdir}/usr/share/man/man1/wget.1" ]] || die "the wget manual page was not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/wget" | grep -q 'libssl.so.3' \
    || die "wget was built without OpenSSL; it could not fetch an https:// URL"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/wget" | grep -q 'libcrypto.so.3'
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/wget" | grep -q 'libz.so.1'
# A library the image does not carry, or one it carries for something else and
# that this package has no business pulling in, is a Wget that either will not
# start or quietly grows a dependency nobody declared.
for unwanted in libpsl libidn2 libidn libpcre2 libpcre libuuid libcares libgnutls; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/wget" | grep -q "${unwanted}"; then
        die "wget links ${unwanted}; the image has no such library"
    fi
done
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/wget" | grep -qE 'RPATH|RUNPATH'; then
    die "wget carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/wget" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "wget was not built with the cross compiler"
# Not just the sysroot: "wget --version" prints the compile and link lines, so
# any build directory that reached the command line is published with the
# package. The whole project root is the thing that must not appear.
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "wget installed files containing the build path: ${leaked}"
pkg_merge wget
log "installed GNU Wget $(source_version wget)"
