#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# GnuPG, which is eight tarballs rather than one. gpg is the front end of a
# small constellation - gpg-agent holds the secret keys, dirmngr talks to
# keyservers and the network, scdaemon drives smartcards, and pinentry is what
# any of them asks a passphrase with - and all of it is built
# on five libraries from the same authors that nothing else in the image uses:
# libgpg-error, libgcrypt, libassuan, libksba and npth. NTBTLS is the sixth,
# and it is what gives dirmngr TLS: GnuPG does not speak to OpenSSL, so without
# it hkps:// keyservers and Web Key Directory lookups would both be unreachable
# on a system that otherwise has TLS everywhere.
#
# They are built here rather than as packages of their own, in the same spirit
# as the PCRE2 that goes into nginx: they are GnuPG's libraries, they move with
# GnuPG's releases, and one package that owns all of them is one thing to
# upgrade rather than seven. They are still shared libraries - a dozen GnuPG
# programs link libgcrypt, and a copy of it in each is neither small nor
# something a security fix could reach.
#
# The order below is the dependency order: libgpg-error is what every other
# component reports errors with, and each library is merged into the sysroot as
# it is built so the next one can configure against it.

pkgdir="$(pkg_stage gnupg)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
# pkg-config drops -L for a library directory it considers a system one, which
# /usr/lib64 is, so the flags for these libraries come back as a bare
# "-lgcrypt". The compiler resolves that inside its sysroot and is right;
# libtool resolves it by searching directories of its own, finds the build
# host's libgcrypt - the host is a machine that has GnuPG - and links a library
# of this image against it. Naming the sysroot first is what settles it; where
# it survives into an installed file, it is taken back out below.
export LDFLAGS="-L${SYSROOT}/usr/lib64"
# The GnuPG autoconf macros ask gpgrt-config - libgpg-error's own pkg-config,
# which understands PKG_CONFIG_SYSROOT_DIR - for the flags of every library
# here. Naming the one just built is what stops AC_PATH_PROG from finding the
# build host's copy and linking the image against the host's libraries.
export GPGRT_CONFIG="${SYSROOT}/usr/bin/gpgrt-config"

# Builds one component into the shared staging tree. Every component is
# autotools, takes the same prefix, and is then merged into the sysroot: the
# staging tree is what the package is cut from, and the sysroot is what the
# next configure looks in. Only the options every one of them understands are
# passed here; the rest are per component below, so that a warning about an
# unrecognized option means something.
gnupg_component() {
    local name="$1"
    shift
    local source_tree build_tree
    source_tree="$(prepare_source "${name}")"
    build_tree="${BUILD_DIR}/${name}"
    reset_build_dir "${build_tree}"
    cd "${build_tree}"
    "${source_tree}/configure" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --libexecdir=/usr/libexec/gnupg \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --build="${build_triplet}" \
        --host="${TARGET}" \
        "$@"
    make -j"${JOBS}"
    make DESTDIR="${pkgdir}" install
    # The libtool archives go no further than the build directory they were
    # made in. There are no static libraries here for them to describe, and
    # what they do describe is where their dependencies live - as "/usr/lib64",
    # the path on the target. libtool believes that path while linking on the
    # build host, so a libtool archive left in the sysroot is what makes the
    # next component link against the host's copy of libgpg-error rather than
    # this one. Without them libtool resolves -lgpg-error through -L and the
    # sysroot wins, which is what the LDFLAGS above are for.
    find "${pkgdir}" -name '*.la' -delete
    cp -a --remove-destination "${pkgdir}/." "${SYSROOT}/"
    log "built ${name} $(source_version "${name}") for GnuPG"
}

# libgpg-error carries the lock object layout of the target in a header, and for
# a triplet it has never seen it generates one at configure time with the
# target's objdump rather than falling back to a guess - which is why the cross
# toolchain's binutils have to be on PATH here. They are: common.sh puts them
# there.
gnupg_component libgpg-error --disable-nls --disable-rpath --disable-static
[[ -x "${GPGRT_CONFIG}" ]] || die "libgpg-error did not install gpgrt-config"

gnupg_component npth --disable-static
gnupg_component libassuan --disable-static \
    --with-libgpg-error-prefix="${SYSROOT}/usr"
gnupg_component libgcrypt --disable-static \
    --with-libgpg-error-prefix="${SYSROOT}/usr"
gnupg_component libksba --disable-static \
    --with-libgpg-error-prefix="${SYSROOT}/usr"
gnupg_component ntbtls \
    --disable-static \
    --with-libgpg-error-prefix="${SYSROOT}/usr" \
    --with-libgcrypt-prefix="${SYSROOT}/usr"

# pinentry is what gpg-agent execs to ask for a passphrase, and without one the
# agent can neither unlock a secret key nor create one - a gpg that can verify
# and encrypt but not sign or decrypt. The curses and tty prompts are the two
# that make sense on a machine with no display server; the toolkit ones are
# refused by name rather than left to be auto-detected, so a library that
# happens to be on the build host cannot decide what the image ships.
gnupg_component pinentry \
    --disable-rpath \
    --with-libgpg-error-prefix="${SYSROOT}/usr" \
    --with-libassuan-prefix="${SYSROOT}/usr" \
    --enable-pinentry-tty \
    --enable-pinentry-curses \
    --enable-fallback-curses \
    --disable-pinentry-emacs \
    --disable-inside-emacs \
    --disable-libsecret \
    --disable-pinentry-efl \
    --disable-pinentry-fltk \
    --disable-pinentry-gtk2 \
    --disable-pinentry-gnome3 \
    --disable-pinentry-qt \
    --disable-pinentry-qt5 \
    --disable-pinentry-tqt

# What the rest of the options say GnuPG is on this system: no LDAP (dirmngr
# keeps HTTP, HKP and its own DNS resolver), no internal CCID driver since the
# image has no libusb - a smartcard is reached through pcscd if one is
# installed - and NTBTLS as the TLS library, GnuTLS being neither present nor
# wanted. The trust store is the same CA bundle everything else in the image
# verifies against, so gpgsm and dirmngr agree with curl about who signs the
# internet.
#
# SQLite is the one that shows: the image has none - not even Python's module -
# and both the TOFU trust model and keyboxd, which is the key store GnuPG 2.5
# would otherwise prefer, are databases in it. Without it gpg keeps its keys in
# the keyring files it always did, which is what every gpg before this one used
# and what "gpg --export" and "gpg --import" speak anyway. Naming the option is
# how that stays a decision rather than a consequence of what the build host
# happened to have installed.
#
# The test suite is not built: it is a Scheme interpreter and a few hundred
# test scripts, none of which could run here anyway - they would have to run on
# the target - and gpgscm would be installed into the image if it were.
gnupg_component gnupg \
    CC_FOR_BUILD=gcc \
    --disable-nls \
    --disable-rpath \
    --disable-tests \
    --with-libgpg-error-prefix="${SYSROOT}/usr" \
    --with-libgcrypt-prefix="${SYSROOT}/usr" \
    --with-libassuan-prefix="${SYSROOT}/usr" \
    --with-libksba-prefix="${SYSROOT}/usr" \
    --with-npth-prefix="${SYSROOT}/usr" \
    --with-ntbtls-prefix="${SYSROOT}/usr" \
    --with-default-trust-store-file=/etc/ssl/certs/ca-certificates.crt \
    --enable-build-timestamp="$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%dT%H:%M+0000')" \
    --disable-ldap \
    --disable-sqlite \
    --disable-ccid-driver \
    --disable-gnutls

# gpg-agent execs /usr/bin/pinentry by name, and upstream ships every prompt
# under its own name and no such link. The curses one is the default because it
# is the one that works over ssh and on the console alike; PINENTRY_USER_DATA
# and gpg-agent.conf can still name pinentry-tty instead.
ln -sfn pinentry-curses "${pkgdir}/usr/bin/pinentry"

# The build sysroot reaches the development metadata through the LDFLAGS above
# and through the flags the config scripts were generated with. It is not a
# directory the image has, and every path that names it is right once the
# prefix is taken off: what is left is the /usr the image is.
GNUPG_BUILD_SYSROOT="${SYSROOT}" perl -pi -e \
    's/\Q$ENV{GNUPG_BUILD_SYSROOT}\E//g' \
    "${pkgdir}"/usr/lib64/pkgconfig/*.pc "${pkgdir}"/usr/bin/*-config

# /usr/bin holds the config scripts of the libraries as well as the programs,
# so only what is an ELF file is stripped.
while IFS= read -r binary; do
    "${TARGET}-readelf" -h "${binary}" > /dev/null 2>&1 || continue
    "${TARGET}-strip" "${binary}"
done < <(find "${pkgdir}/usr/bin" "${pkgdir}/usr/libexec" -type f -perm -u+x -print)
find "${pkgdir}/usr/lib64" -name '*.so.*' -type f -exec "${TARGET}-strip" {} +

# The programs a working GnuPG is made of. gpgv is the one worth naming twice:
# it verifies signatures with nothing but a keyring, which is what a package
# manager or a boot script would use, and it is a separate binary precisely so
# it can be used where the rest of GnuPG cannot.
for program in gpg gpgv gpgsm gpgconf gpg-agent gpg-connect-agent gpgtar \
    gpgsplit gpg-card dirmngr dirmngr-client watchgnupg kbxutil; do
    [[ -x "${pkgdir}/usr/bin/${program}" ]] || die "GnuPG did not install ${program}"
done
# The programs GnuPG starts for itself rather than for the user, and does not
# put on anyone's PATH.
for helper in scdaemon gpg-protect-tool gpg-preset-passphrase gpg-check-pattern; do
    [[ -x "${pkgdir}/usr/libexec/gnupg/${helper}" ]] \
        || die "GnuPG did not install ${helper}"
done
[[ ! -e "${pkgdir}/usr/bin/gpgscm" ]] \
    || die "the GnuPG test suite interpreter was installed into the image"
for prompt in pinentry-curses pinentry-tty; do
    [[ -x "${pkgdir}/usr/bin/${prompt}" ]] || die "pinentry did not install ${prompt}"
done
[[ -L "${pkgdir}/usr/bin/pinentry" ]] || die "the default pinentry link was not made"
for library in libgpg-error.so.0 libgcrypt.so.20 libassuan.so.9 libksba.so.8 \
    libnpth.so.0 libntbtls.so.0; do
    [[ -e "${pkgdir}/usr/lib64/${library}" ]] \
        || die "GnuPG's ${library} was not installed"
done

# gpg without libgcrypt is not a thing that can happen, but a gpg that found the
# build host's libraries instead of the image's is, and it would only be
# discovered by a system that could not start it.
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/gpg" | grep -q 'libgcrypt.so.20' \
    || die "gpg is not linked against the libgcrypt built here"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/gpg" | grep -q 'libbz2.so.1' \
    || die "gpg cannot read bzip2-compressed messages"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/gpg" | grep -q 'libz.so.1' \
    || die "gpg cannot read compressed messages"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/dirmngr" | grep -q 'libntbtls.so.0' \
    || die "dirmngr has no TLS library; hkps and Web Key Directory would not work"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/gpg-agent" | grep -q 'libnpth.so.0' \
    || die "gpg-agent is not linked against npth"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/pinentry-curses" | grep -q 'libncursesw.so.6' \
    || die "pinentry-curses is not linked against the image's ncurses"
# Nothing GnuPG installs may name the build sysroot: in a run path it would be
# a directory the image has not got, and in a config script or a pkg-config
# file it would send anything built later on the machine to the same place.
leaked="$(grep -rlF "${SYSROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] \
    || die "these name the build sysroot: ${leaked//${pkgdir}/}"
while IFS= read -r binary; do
    "${TARGET}-readelf" -h "${binary}" > /dev/null 2>&1 || continue
    if "${TARGET}-readelf" -d "${binary}" | grep -E 'R(UN)?PATH' \
        | grep -qv '\[/usr/lib64\]'; then
        die "${binary#"${pkgdir}"} has a run path outside /usr/lib64"
    fi
done < <(find "${pkgdir}/usr/bin" -type f -perm -u+x -print)
# Where GnuPG looks for the programs it starts. gpgconf holds the module table
# the others ask, and it names a directory and a program rather than a path:
# /usr/bin joined with /pinentry is the link made above, and /usr/libexec/gnupg
# is where scdaemon and the protect tool were installed. A build that took the
# default libexecdir would look in /usr/libexec and find nothing there.
gpgconf_paths="$("${TARGET}-strings" "${pkgdir}/usr/bin/gpgconf")"
for embedded in /usr/bin /usr/libexec/gnupg /pinentry; do
    grep -qxF -- "${embedded}" <<< "${gpgconf_paths}" \
        || die "gpgconf was not built to look in ${embedded}"
done
# dirmngr is the one that holds the system trust store: it is what validates a
# keyserver's certificate and what gpgsm asks about a system root.
dirmngr_paths="$("${TARGET}-strings" "${pkgdir}/usr/bin/dirmngr")"
grep -qxF /etc/ssl/certs/ca-certificates.crt <<< "${dirmngr_paths}" \
    || die "dirmngr was not pointed at the image's CA bundle"
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/gpg" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "GnuPG was not built with the cross compiler"
pkg_merge gnupg
log "installed GnuPG $(source_version gnupg)"
