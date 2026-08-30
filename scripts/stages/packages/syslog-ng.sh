#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# syslog-ng, the system logger.
#
# Until this package the image had no syslog daemon at all, and it shows all
# over the tree: cronie is started with "-m off" because there is nothing to
# mail and nothing to log to, chronyd and named are configured to write to
# stderr, and the rc framework's daemon helper appends each service's output to
# a /var/log/<name>.log of its own. That arrangement keeps working - it is what
# a service's *own* output does - but it never covered the other half, which is
# everything that calls syslog(3): sshd's authentication records, su and sudo,
# crond's own accounting of what it ran, and anything installed from the
# repository afterwards. All of it was written to /dev/log, which nothing was
# listening on, and silently discarded.
#
# What is built here is deliberately a small syslog-ng. Nearly every optional
# module is a network or database client, and each is autodetected from what is
# lying about in the sysroot: libcurl is there for curl, Python is there because
# the image ships it, and OpenSSL is there for everything. A logger that grew an
# HTTP destination because the image happens to contain libcurl is not a
# decision anybody made, so the modules are turned off by name and the ones
# that remain are the files, the sockets, the parsers and TLS.
#
# ivykis is syslog-ng's event loop and is built from the copy inside the
# tarball (--with-ivykis=internal, which is also the default). It is not a
# package: it has one consumer, it is linked statically, and upstream ships it
# in the same release precisely so that it does not have to be tracked apart.

syslog_ng_source="$(prepare_source syslog-ng)"
build_tree="${BUILD_DIR}/syslog-ng"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage syslog-ng)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
cd "${build_tree}"

# syslog-ng keeps __FILE__ in diagnostic messages throughout the core and its
# modules. Map the workspace prefix to a stable target-side source name so the
# package identity and bytes do not depend on where the checkout lives.
#
# The name it is mapped to must not contain the checkout path, because the leak
# check at the end of this stage is a substring grep for that path: the
# container builds in /sowa, and a package sanitised to /usr/src/sowa would
# still match it and fail as though nothing had been mapped at all.
export CFLAGS="${CFLAGS:-} -O2 -ffile-prefix-map=${PROJECT_ROOT}=/usr/src/syslog-ng"
export CXXFLAGS="${CXXFLAGS:-} -O2 -ffile-prefix-map=${PROJECT_ROOT}=/usr/src/syslog-ng"

# syslog-ng requires GLib, PCRE2, JSON-C and OpenSSL unconditionally. Its
# configure script asks pkg-config for them, so confine that query to the target
# sysroot and have pkg-config prefix every include and library directory with
# the root the cross compiler is actually building against.
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig:${SYSROOT}/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"

"${syslog_ng_source}/configure" \
    --prefix=/usr \
    --sbindir=/usr/sbin \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc/syslog-ng \
    --localstatedir=/var/lib/syslog-ng \
    --datadir=/usr/share \
    --mandir=/usr/share/man \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-ivykis=internal \
    --with-module-dir=/usr/lib64/syslog-ng \
    --with-pidfile-dir=/run \
    --with-timezone-dir=/usr/share/zoneinfo \
    --with-manpages=local \
    --enable-manpages \
    --enable-manpages-install \
    --without-compile-date \
    --without-libnet \
    --without-net-snmp \
    --enable-ipv6 \
    --disable-native \
    --disable-python \
    --disable-python-modules \
    --disable-java \
    --disable-java-modules \
    --disable-http \
    --disable-afsnmp \
    --disable-mqtt \
    --disable-redis \
    --disable-riemann \
    --disable-smtp \
    --disable-mongodb \
    --disable-amqp \
    --disable-kafka \
    --disable-stomp \
    --disable-sql \
    --disable-geoip2 \
    --disable-grpc \
    --disable-cloud \
    --disable-cloud-auth \
    --disable-ebpf \
    --disable-systemd \
    --disable-linux-caps \
    --disable-spoof-source \
    --disable-tcp-wrapper \
    --disable-example-modules \
    --disable-tests

# libtool otherwise emits RUNPATH=/usr/lib64 into the daemon and every module.
# That directory is already the target loader's default and must not be baked
# into each object a second time.
for libtool_file in libtool lib/ivykis/libtool; do
    sed -i -e 's|^hardcode_libdir_flag_spec=.*|hardcode_libdir_flag_spec=""|' \
        -e 's|^runpath_var=LD_RUN_PATH|runpath_var=|' "${libtool_file}"
done
sed -i "s|${PROJECT_ROOT}|/usr/src/syslog-ng|g" config.h syslog-ng-config.h

make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

# Cross pkg-config correctly supplies sysrooted link paths to configure, but
# syslog-ng copies that build-only path into its public .pc file. Express the
# same directory through the installed metadata's own libdir instead.
sed -i "s|${SYSROOT}/usr/lib64|\${libdir}|g" \
    "${pkgdir}/usr/lib64/pkgconfig/syslog-ng.pc"
sed -i "s|${PROJECT_ROOT}|/usr/src/syslog-ng|g" \
    "${pkgdir}/usr/include/syslog-ng/syslog-ng-config.h"

for binary in usr/sbin/syslog-ng usr/sbin/syslog-ng-ctl; do
    [[ -f "${pkgdir}/${binary}" ]] || die "syslog-ng did not install ${binary}"
    "${TARGET}-strip" "${pkgdir}/${binary}"
done
# The core library carries the release in its name, so it is looked for by
# shape rather than by a version this stage would then have to keep up with.
[[ -n "$(find "${pkgdir}/usr/lib64" -maxdepth 1 -name 'libsyslog-ng*.so*' -print -quit)" ]] \
    || die "syslog-ng did not install its core library"
while IFS= read -r object; do
    "${TARGET}-strip" --strip-unneeded "${object}"
done < <(find "${pkgdir}/usr/lib64" -name '*.so*' -type f)
while IFS= read -r -d '' program; do
    if "${TARGET}-readelf" -h "${program}" >/dev/null 2>&1; then
        "${TARGET}-strip" --strip-unneeded "${program}"
    fi
done < <(find "${pkgdir}/usr/bin" "${pkgdir}/usr/sbin" -type f -perm /111 \
    -print0 2>/dev/null)
# libtool archives name DESTDIR and are unusable without libtool on the image.
find "${pkgdir}" -name '*.la' -delete

# The modules the configuration needs, checked by name. A syslog-ng whose
# afsocket module did not build starts, reads its configuration, and fails on
# the unix-dgram source that is the entire point of the daemon.
for module in affile afsocket afuser afprog syslogformat basicfuncs; do
    [[ -f "${pkgdir}/usr/lib64/syslog-ng/lib${module}.so" ]] \
        || die "syslog-ng did not build the ${module} module"
done

# The modules that must *not* be here. Each of these is a network or database
# client that would have been autodetected out of the sysroot, and each is a
# listener or an outbound connection the machine did not ask for.
for module in afmongodb afamqp afsnmp afstomp mod-python http kafka redis \
    riemann afsmtp grpc; do
    if compgen -G "${pkgdir}/usr/lib64/syslog-ng/*${module}*" > /dev/null; then
        die "syslog-ng built the ${module} module; it was meant to be disabled"
    fi
done

# What the daemon may link. GLib is the package this one exists beside;
# everything else is either the C library or something already in the image.
needed="$("${TARGET}-readelf" -d "${pkgdir}/usr/sbin/syslog-ng")"
grep -q 'libglib-2.0.so.0' <<< "${needed}" \
    || die "syslog-ng does not link the shared GLib"
grep -q 'libpcre2-8.so.0' <<< "${needed}" \
    || die "syslog-ng does not link the shared PCRE2"
grep -q 'libjson-c.so.5' <<< "${needed}" \
    || die "syslog-ng does not link the shared json-c package"
for unwanted in libcurl libpython libsystemd libcap.so libmongoc librdkafka \
    libhiredis; do
    if grep -q "${unwanted}" <<< "${needed}"; then
        die "syslog-ng links ${unwanted}; that module was meant to be disabled"
    fi
done
while IFS= read -r library; do
    case "${library}" in
        libglib-2.0.so.0 | libgmodule-2.0.so.0 | libgthread-2.0.so.0) ;;
        libpcre2-8.so.0 | libjson-c.so.5) ;;
        libsyslog-ng*.so* | libevtlog*.so* | libsecret-storage.so*) ;;
        libssl.so.3 | libcrypto.so.3 | libz.so.1) ;;
        libm.so.6 | libgcc_s.so.1 | libc.so.6 | ld-linux-x86-64.so.2) ;;
        *) die "syslog-ng needs ${library}, which the image does not ship" ;;
    esac
done < <(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' <<< "${needed}")
if grep -qE 'RPATH|RUNPATH' <<< "${needed}"; then
    die "syslog-ng carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
compiler_comment="$("${TARGET}-readelf" -p .comment \
    "${pkgdir}/usr/sbin/syslog-ng")"
grep -q "GCC: (GNU) ${cross_gcc_version}" <<< "${compiler_comment}" \
    || die "syslog-ng was not built with the cross compiler"

for page in man8/syslog-ng.8 man5/syslog-ng.conf.5; do
    [[ -f "${pkgdir}/usr/share/man/${page}" ]] \
        || die "syslog-ng did not install ${page}"
done

# Where the daemon keeps what it has to remember across a restart: which byte
# of each followed file it had reached, and the disk buffers if one is ever
# configured. 0700 because the persist file names every path the daemon reads.
install -d -m 0700 "${pkgdir}/var/lib/syslog-ng"

# The configuration is the overlay's, like sshd_config: it describes this
# image's idea of where its logs go, not upstream's. The one the tarball
# installs is removed so that the two cannot disagree - it would otherwise be a
# second answer to the same question, with the overlay winning by copy order
# rather than on purpose.
#
# scl.conf stays. It is not a configuration but the entry point to the
# configuration library - the definitions behind system(), network() and the
# rest - and a machine that adds one of those to its own configuration needs it
# to be there.
rm -f "${pkgdir}/etc/syslog-ng/syslog-ng.conf"
[[ -f "${pkgdir}/usr/share/syslog-ng/include/scl.conf" ]] \
    || die "syslog-ng did not install scl.conf; the configuration library would be unreachable"
find "${pkgdir}/etc" -type d -empty -delete 2> /dev/null || true

leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "syslog-ng carries a build path: ${leaked}"

# Parse the configuration the image will actually ship, with the target
# loader, target libraries and freshly built modules. Autoconf can prove that
# the parser compiled; only this catches a misspelled source, destination or
# module in the overlay before it becomes an init-time failure.
shipped_config="${PROJECT_ROOT}/rootfs-overlay/etc/syslog-ng/syslog-ng.conf"
target_loader="${SYSROOT}/lib64/ld-linux-x86-64.so.2"
[[ -f "${shipped_config}" ]] || die "the shipped syslog-ng configuration is missing"
[[ -x "${target_loader}" ]] || die "the target loader is missing; cannot validate syslog-ng"
"${target_loader}" \
    --library-path "${pkgdir}/usr/lib64:${SYSROOT}/usr/lib64:${SYSROOT}/lib64" \
    "${pkgdir}/usr/sbin/syslog-ng" \
    --module-path="${pkgdir}/usr/lib64/syslog-ng" \
    --cfgfile="${shipped_config}" --syntax-only

pkg_merge syslog-ng
log "installed syslog-ng $(source_version syslog-ng)"
