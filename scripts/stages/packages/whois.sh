#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Marco d'Itri's standalone whois rather than the copy inside inetutils.
#
# They are the same program by descent, which is exactly why the choice has to
# be made deliberately. inetutils forked this code around 2005 and froze the
# server tables into its source; that copy still falls back to
# whois.networksolutions.com and knows none of the gTLDs delegated since. The
# tables here are regenerated from the .lst files on every build, so the
# package is current as of the pinned release. packages/inetutils.sh refuses
# its own whois for this reason and asserts that it did.
#
# The build is a plain Makefile with no configure, and it autodetects its two
# optional libraries by running pkg-config - the build host's, which would
# answer for the build host's libraries. PKG_CONFIG is pointed at a program that
# always fails so that both come out unfound, which is the right answer: the
# image has no libidn2, so international domain names are passed through as
# entered rather than punycoded.
#
# Only whois itself is installed. The tree also builds mkpasswd, which would be
# a second, unrelated program - the image already hashes passwords with openssl
# and with Python - so it is neither built nor shipped.

require_command perl
whois_source="$(prepare_source whois)"
build_tree="${BUILD_DIR}/whois"
reset_build_dir "${build_tree}"
# Built in a copy: the Makefile generates seven headers from the .lst tables
# directly inside the tree it runs in and has no out-of-tree mode at all.
cp -a "${whois_source}/." "${build_tree}/"
pkgdir="$(pkg_stage whois)"

target_configure_env
cd "${build_tree}"
# CONFIG_FILE is where whois looks for the operator's own server overrides. The
# image ships no such file - the compiled-in tables are the answer - but the
# path has to be compiled in for one to work when someone writes it, and
# whois.conf(5) is installed to document it.
make -j"${JOBS}" whois \
    CC="${CC}" \
    PKG_CONFIG=/bin/false \
    PERL=perl \
    CONFIG_FILE=/etc/whois.conf \
    HAVE_ICONV=
make DESTDIR="${pkgdir}" prefix=/usr install-whois

[[ -x "${pkgdir}/usr/bin/whois" ]] || die "whois was not installed"
"${TARGET}-strip" "${pkgdir}/usr/bin/whois"
for page in man1/whois.1 man5/whois.conf.5; do
    [[ -f "${pkgdir}/usr/share/man/${page}" ]] \
        || die "the ${page} manual page was not installed"
done
# install-bashcomp would install a completion for mkpasswd as well, which this
# package does not ship. The one file that belongs here is copied by hand.
install -d -m 0755 "${pkgdir}/usr/share/bash-completion/completions"
install -m 0644 whois.bash \
    "${pkgdir}/usr/share/bash-completion/completions/whois"
[[ ! -e "${pkgdir}/usr/bin/mkpasswd" ]] \
    || die "the whois package installed mkpasswd; only whois belongs to it"

# The point of preferring this source over the inetutils one is the server
# tables, and they are not shipped as tables: the Makefile generates seven
# headers from the .lst files on every build. If that step were skipped the
# compile would still succeed against whatever headers were lying around, so
# both halves are checked - that the headers were generated here, and that what
# they contain reached the binary.
#
# The gTLD list is checked by counting rather than by name. Its entries are bare
# labels - "dev", not "whois.nic.dev", which whois builds at run time - and the
# short ones get merged into the string table, so no single label can be looked
# for reliably. A four-figure count is the real assertion: the frozen fork this
# package exists to avoid has a few hundred.
# servers_charset.h is deliberately not in this list: it is generated only for
# the iconv recoding this build does without, so its absence is the switch
# above working rather than a step that was skipped.
for generated in tld_serv.h new_gtlds.h ip_del.h ip6_del.h as_del.h \
    nic_handles.h; do
    [[ -s "${build_tree}/${generated}" ]] \
        || die "${generated} was not generated; whois would have been built against a stale server table"
done
[[ ! -e "${build_tree}/simple_recode.o" ]] \
    || die "whois was built with iconv support; the image has no libiconv separate from glibc"
gtld_count="$(grep -c '^[^#]' new_gtlds_list)"
((gtld_count > 1000)) \
    || die "the gTLD list has only ${gtld_count} entries; this tarball's tables are not current"
for table_entry in whois.iana.org whois.verisign-grs.com whois.nic.uk; do
    grep -aqF "${table_entry}" "${pkgdir}/usr/bin/whois" \
        || die "whois has no ${table_entry} in its server table; the tables did not reach the binary"
done
for unwanted in libidn libiconv; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/whois" | grep -q "${unwanted}"; then
        die "whois links ${unwanted}; the image has no such library"
    fi
done
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/whois" | grep -qE 'RPATH|RUNPATH'; then
    die "whois carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/whois" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "whois was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "whois installed files containing the build path: ${leaked}"
pkg_merge whois
log "installed whois $(source_version whois)"
