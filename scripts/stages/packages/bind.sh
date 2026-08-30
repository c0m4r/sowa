#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# ISC BIND 9, all of it: the named server, dig, host and nslookup, the DNSSEC
# signing and checking tools, and the five libraries the rest of it is built
# from.
#
# Taking the whole stack rather than the three commands is a decision about
# where the weight is. dig, host and nslookup are about 360 KB between them;
# the three libraries they need are about ten times that, and there is no
# configure option that builds the commands without the libraries;
# --enable-tools-only is not an upstream option. Once those libraries are in
# the image, named costs libns and libisccc on top of them,
# and every dnssec-* tool costs nothing at all: they link exactly what dig
# links. So the choice was never "three commands or twenty-nine", it was "three
# commands or a DNS server, a DNSSEC toolchain and a zone checker for about
# another third".
#
# Everything optional is refused by name. Left to itself, configure would build
# against whatever the sysroot happened to grow later - and against libraries
# this image does not have at all, since several of these checks fall back to
# the build host. The three that are not optional are handled by the stages
# ahead of this one: libuv, liburcu and, on Linux, libcap, which BIND 9.20
# requires unconditionally now that --disable-linux-caps has been removed. All
# four dependencies including OpenSSL are found through pkg-config, which is
# what the three PKG_CONFIG variables below are for.
#
# named ships with a configuration and a service, and the service ships
# disabled. A resolver that starts listening the first time a machine boots is
# a surprise, and this one is in the image because dig is - so /etc/named.conf
# describes a caching resolver bound to the loopback interface, and turning it
# on is "chkconfig named on".

bind_source="$(prepare_source bind)"
build_tree="${BUILD_DIR}/bind"
reset_build_dir "${build_tree}"
# In-tree, because BIND's REQUIRE and INSIST are not assertions that a release
# build compiles out - they are how the server decides it has lost track of its
# own state, and each one names __FILE__. An out-of-tree build would put the
# builder's home directory into every one of those strings.
cp -a "${bind_source}/." "${build_tree}/"
pkgdir="$(pkg_stage bind)"

bind_version="$(source_version bind)"
build_triplet="$(sh "${bind_source}/config.guess")"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
# BIND's five libraries depend on each other - libisccfg calls into libns, and
# every command links libisccfg - so linking a command means resolving a
# library that is named by another library and is not installed yet. libtool
# would normally answer that by recording the build tree as a run-time path and
# then relinking at install time to record /usr/lib64 instead, and the edit to
# libtool below refuses both. -rpath-link is the third answer: it tells the
# linker where to look for an indirectly named library without writing
# anything into what it produces, so it holds for the build tree only and the
# installed programs come out with no run-time path at all.
link_paths=()
for library_dir in isc dns ns isccc isccfg; do
    link_paths+=("-Wl,-rpath-link,${build_tree}/lib/${library_dir}/.libs")
done
export LDFLAGS="${link_paths[*]}"
# Every one of these was checked against this tarball's configure rather than
# carried over from an older branch: the spellings churn between 9.18 and 9.20.
# --disable-tests does not exist - refusing cmocka is what turns the unit tests
# off - and neither does --disable-linux-caps.
#
# zlib and nghttp2 are refused together with DoH, which is the only thing
# either is used for. The image has a zlib, so this is a choice not to build
# the feature rather than an absence.
./configure \
    --prefix=/usr \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --runstatedir=/run \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --disable-static \
    --disable-silent-rules \
    --disable-doh \
    --disable-geoip \
    --disable-dnstap \
    --without-cmocka \
    --without-gssapi \
    --without-jemalloc \
    --without-json-c \
    --without-libidn2 \
    --without-libnghttp2 \
    --without-libxml2 \
    --without-lmdb \
    --without-maxminddb \
    --without-readline \
    --without-zlib
sed -i -e 's|^hardcode_libdir_flag_spec=.*|hardcode_libdir_flag_spec=""|' \
    -e 's|^runpath_var=LD_RUN_PATH|runpath_var=|' libtool
# BIND compiles its own configure line into named so that "named -V" can print
# it, which is a genuinely useful thing to be able to ask a running server -
# and it records the environment variables along with the options. Three of
# those name this machine: the sysroot in PKG_CONFIG_LIBDIR, the build tree in
# LDFLAGS, and the cross compiler in CC. The options are kept and the
# environment half is cut, so "named -V" still answers what it was built with
# and no longer answers where.
sed -i "s| 'build_alias=.*\$|\"|" config.h
grep -q "^#define PACKAGE_CONFIGARGS .*'--without-zlib'\"\$" config.h \
    || die "the recorded configure arguments were not trimmed as expected"
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

rm -f "${pkgdir}"/usr/lib64/*.la "${pkgdir}"/usr/lib64/bind/*.la
[[ -z "$(find "${pkgdir}" -name '*.a' -print -quit)" ]] \
    || die "BIND installed a static library; the image ships none"

# The five libraries, named for the version that built them: BIND has no stable
# soname across releases and does not pretend to, so libdns-9.20.26.so is both
# the file and the soname. Nothing outside this package links them.
for stem in isc dns ns isccfg isccc; do
    library="${pkgdir}/usr/lib64/lib${stem}-${bind_version}.so"
    [[ -f "${library}" ]] || die "lib${stem} was not installed"
    "${TARGET}-strip" "${library}"
    "${TARGET}-readelf" -d "${library}" | grep -q "SONAME.*lib${stem}-${bind_version}\.so" \
        || die "lib${stem} carries no soname; nothing could record a dependency on it"
    [[ -L "${pkgdir}/usr/lib64/lib${stem}.so" ]] \
        || die "the lib${stem}.so symbolic link is missing"
done

# What the image gets, by directory. named, rndc and the two key generators are
# administrative and go to sbin; everything anyone would run to ask a question
# goes to bin.
sbin_programs=(named rndc rndc-confgen tsig-keygen ddns-confgen)
bin_programs=(
    dig host nslookup delv nsupdate mdig
    named-checkconf named-checkzone named-compilezone
    named-journalprint named-rrchecker arpaname nsec3hash
    dnssec-cds dnssec-dsfromkey dnssec-importkey dnssec-keyfromlabel
    dnssec-keygen dnssec-ksr dnssec-revoke dnssec-settime
    dnssec-signzone dnssec-verify
)
for program in "${sbin_programs[@]}"; do
    [[ -e "${pkgdir}/usr/sbin/${program}" ]] || die "BIND did not install ${program}"
done
for program in "${bin_programs[@]}"; do
    [[ -e "${pkgdir}/usr/bin/${program}" ]] || die "BIND did not install ${program}"
done
# Strip the real files only: several of these names are links to a binary that
# behaves differently depending on which name invoked it.
find "${pkgdir}/usr/bin" "${pkgdir}/usr/sbin" -type f -exec "${TARGET}-strip" {} +
# The two query-filtering plugins named loads by name from its configuration.
for plugin in filter-a filter-aaaa; do
    [[ -f "${pkgdir}/usr/lib64/bind/${plugin}.so" ]] \
        || die "the ${plugin} plugin was not installed"
    "${TARGET}-strip" "${pkgdir}/usr/lib64/bind/${plugin}.so"
done

# Sowa's own named.conf: BIND installs none, and the sample in its
# documentation is not one. This describes a caching, validating resolver that
# answers on the loopback interface and nowhere else, which is the only thing
# an image can assume about a machine it has never seen. A resolver for a
# network replaces the two listen-on lines and the two allow lines.
#
# There is no hint zone because there is no root hints file to keep up to date:
# named carries the root servers and the root DNSSEC trust anchor compiled in,
# and "dnssec-validation auto" is what tells it to use the latter and to
# maintain it through RFC 5011 rollovers afterwards.
install -d -m 0755 "${pkgdir}/etc"
cat > "${pkgdir}/etc/named.conf" <<'CONFIGURATION'
// Sowa's default named configuration: a caching resolver for this machine
// alone. named is not started at boot unless "chkconfig named on" says so.
//
// To resolve for a network instead, add its addresses to listen-on and to
// allow-query and allow-recursion. To serve a zone, add a "zone" block naming
// a file in /var/named and reload with "rndc reload".

options {
	// Where relative file names in this configuration are resolved, and
	// where named keeps the DNSSEC keys it manages itself.
	directory "/var/named";
	pid-file "/run/named/named.pid";
	session-keyfile "/run/named/session.key";

	// Loopback only. A resolver that answers the Internet is an open
	// resolver, which is a reflector for somebody else's attack.
	listen-on { 127.0.0.1; };
	listen-on-v6 { ::1; };
	allow-query { localhost; };
	recursion yes;
	allow-recursion { localhost; };

	// Validate every answer against the root trust anchor built into
	// named, and keep that anchor current as the root key rolls over.
	dnssec-validation auto;
};

// rndc's key. The file is generated on first start by the init script rather
// than shipped, because a key that every installation of an image shares is
// not a key.
include "/etc/rndc.key";

// named is started with -g and says everything on stderr, which the init
// script appends to /var/log/named.log - a resolver's own log, kept out of
// syslog so that query and DNSSEC diagnostics stay in one place.
CONFIGURATION
chmod 0644 "${pkgdir}/etc/named.conf"
# named's working directory. It is owned by the named account rather than by
# root because "dnssec-validation auto" writes the managed-keys database into
# it, and a resolver that cannot write there logs an error at every start.
install -d -m 0750 "${pkgdir}/var/named"

[[ -f "${pkgdir}/etc/named.conf" ]] || die "the named configuration was not installed"
[[ -d "${pkgdir}/var/named" ]] || die "named's working directory was not created"
for page in man1/dig.1 man1/host.1 man1/nslookup.1 man8/named.8 man8/rndc.8 \
    man1/dnssec-keygen.1 man5/named.conf.5; do
    [[ -f "${pkgdir}/usr/share/man/${page}" ]] \
        || die "the ${page} manual page was not installed"
done

# The three dependency stages ahead of this one, plus OpenSSL, read back from
# the object that actually names each. Which object that is matters: dig does
# not link libuv, because libisc owns the event loop and dig only calls into
# it, so asserting libuv on dig would be an assertion that passes on the day it
# should fail. libcap is named's alone - it is the only one of the twenty-nine
# that changes user.
for required in libuv.so.1 liburcu.so.8 libssl.so.3 libcrypto.so.3; do
    "${TARGET}-readelf" -d "${pkgdir}/usr/lib64/libisc-${bind_version}.so" \
        | grep -q "${required}" \
        || die "libisc is not linked against ${required}"
done
"${TARGET}-readelf" -d "${pkgdir}/usr/sbin/named" | grep -q 'libcap.so.2' \
    || die "named is not linked against libcap; it could not keep CAP_NET_BIND_SERVICE across -u"
# And the arrangement the whole package rests on: the commands resolve BIND
# from the shared libraries rather than carrying their own copies. Twenty-nine
# static links would be most of a hundred megabytes.
for required in libisc libdns libisccfg; do
    "${TARGET}-readelf" -d "${pkgdir}/usr/bin/dig" \
        | grep -q "${required}-${bind_version}.so" \
        || die "dig is not linked against the shared ${required}"
done
# Everything refused at configure time, read back the same way. Each of these
# is a library the image does not have, so linking one is a build that produced
# a program the image cannot run - and configure would have done it silently,
# since every one of these checks has a fallback.
for object in usr/bin/dig usr/sbin/named "usr/lib64/libisc-${bind_version}.so" \
    "usr/lib64/libdns-${bind_version}.so"; do
    for unwanted in libxml2 libjson-c liblmdb libmaxminddb libidn2 libjemalloc \
        libnghttp2 libgssapi_krb5 libreadline libedit libz.so; do
        if "${TARGET}-readelf" -d "${pkgdir}/${object}" | grep -q "${unwanted}"; then
            die "/${object} links ${unwanted}; the image has no such library"
        fi
    done
done
for linked in usr/bin/dig usr/sbin/named "usr/lib64/libdns-${bind_version}.so"; do
    if "${TARGET}-readelf" -d "${pkgdir}/${linked}" | grep -qE 'RPATH|RUNPATH'; then
        die "/${linked} carries a run-time library path"
    fi
done
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/sbin/named" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "named was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "BIND installed files containing the build path: ${leaked}"
pkg_merge bind
log "installed ISC BIND ${bind_version}"
