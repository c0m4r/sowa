#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# mandoc, and with it the manual page reader the image has never had.
#
# Nearly every package in this distribution installs pages under
# /usr/share/man, and until this stage existed nothing in the image could
# format one - which is why the Git section of the howto had to say that
# "git help commit" cannot work.
#
# mandoc rather than groff because mandoc parses mdoc(7) and man(7) directly
# instead of being a roff that happens to have manual page macros. That is one
# 400 kB binary linking zlib, against a typesetter with its own macro and font
# trees, a preprocessor pipeline and a Perl dependency - for output that is
# indistinguishable on a terminal.
#
# One binary answers to five names, dispatching on argv[0]: mandoc formats a
# file given by path, man looks a page up by name and pages it, apropos and
# whatis search the mandoc.db index, and makewhatis writes that index.
#
# The image ships no mandoc.db. Building one would mean running makewhatis,
# which is a target binary this host cannot execute, and the index would be
# wrong the moment sowa-pkg installed a package anyway. It is not needed for
# the common case: "man name" falls back to walking the manual tree when no
# index is there - which is what the patch below is about, since upstream reads
# a missing entry as a stale index and says so above every page it formats.
# apropos and whatis do need the index, and the answer for them is to run
# makewhatis on the running system, which is what the howto now says.

require_command patch
mandoc_source="$(prepare_source mandoc)"
build_tree="${BUILD_DIR}/mandoc"
reset_build_dir "${build_tree}"
# Built in a copy of the source: the Makefile has no VPATH and configure writes
# config.h and Makefile.local into the current directory, so there is no
# out-of-tree build to do. The copy is also what is patched, so the cached,
# checksum-verified unpacked source stays pristine across rebuilds.
cp -a "${mandoc_source}/." "${build_tree}/"
patch --directory="${build_tree}" --strip=1 \
    --input="${PROJECT_ROOT}/patches/mandoc-1.14.6-no-mandoc-db.patch"
pkgdir="$(pkg_stage mandoc)"

target_configure_env
cd "${build_tree}"

# mandoc's configure is hand-written, and for every library function it might
# have to substitute it compiles a test program *and runs it*. Under a cross
# compiler that answers for the build host, or fails outright - and because the
# target is the same architecture as the host, some tests could even appear to
# pass while measuring the build environment instead of the image.
#
# configure.local is read before any test runs and each value in it is taken as
# final, so every test is pre-empted here. The values are not guesses: they are
# what the same tests report against glibc 2.44, the C library this image is
# built on. A wrong one is not a failed build but a mandoc that quietly carries
# its own copy of a function glibc already provides, or calls one it does not.
#
# Also spelled out are the compiler and archiver, since configure initialises
# CC=cc and AR=ar itself specifically so that nothing leaks in from the
# environment - target_configure_env above would otherwise be ignored - and
# CFLAGS, which configure leaves at "-g" with no optimisation at all when it is
# not given one.
cat > configure.local <<EOF
CC="${TARGET}-gcc"
AR="${TARGET}-ar"
CFLAGS="-O2"

# Installed as the rest of the image is: programs 0755, everything else 0644,
# where upstream's defaults are the read-only 0555 and 0444.
PREFIX="/usr"
BINDIR="/usr/bin"
SBINDIR="/usr/sbin"
MANDIR="/usr/share/man"
INSTALL_PROGRAM="install -m 0755"
INSTALL_MAN="install -m 0644"
INSTALL_DATA="install -m 0644"

# man, apropos, whatis and makewhatis are the same binary under other names.
# Upstream hard links them; a package manifest records a symbolic link as a
# link and a hard link as a second, identical file, so linking them symbolically
# is the difference between one copy of mandoc in the image and five.
LN="ln -sf"

# The image has no /usr/X11R6 and no /usr/local, which is all that upstream's
# defaults add to these.
MANPATH_BASE="/usr/share/man"
MANPATH_DEFAULT="/usr/share/man"

# The pager man(1) runs when neither MANPAGER nor PAGER is set.
#
# This used to be /usr/bin/manpager, a wrapper that ran every page through
# "col -bx" first. That existed because the image's only pager could not resolve
# overstriking: mandoc marks bold and underline that way - NAME is written
# "N\bNA\bAM\bME\bE" - and that pager printed the control character in caret
# notation instead, so the wrapper stripped the overstriking before it could be
# mangled. It cost the bold and the underline to keep the page readable.
#
# The image now has GNU less, which resolves overstriking into bold and
# underline itself. Man can therefore page through less directly and preserve
# the manual pages' formatting without a wrapper.
#
# HAVE_LESS_T decides whether man passes the pager the "-T tagfile" that jumps
# straight to the requested option. GNU less does support it, but the test for
# it would have been run against the build host's less rather than the one being
# shipped, so it stays off: without it man still pages, it just starts at the
# top of the page instead of at the option asked for.
BINM_PAGER=/usr/bin/less
HAVE_LESS_T=0

# UTF-8 output is compiled in but reached only if setlocale succeeds at run
# time, so this names the locale mandoc will ask for. C.UTF-8 is the one to
# name because it is the one the image is certain to have: stage
# packages/locales compiles it and /etc/locale.conf defaults to it, and it is a
# locale that decides nothing except the character set. Before there were
# compiled locales this setting was aspirational and every page rendered as
# -Tascii.
HAVE_WCHAR=1
UTF8_LOCALE="C.UTF-8"

# Not OpenBSD and not NetBSD, which is all OSENUM is asked to distinguish;
# uname would have said so, but it would have been the host's uname.
OSENUM=MANDOC_OS_OTHER

# Skipping the two tests that are not about the C library: the compiler
# understands the warning flags, and the binaries are dynamically linked like
# every other program in the image.
HAVE_WFLAG=1
HAVE_STATIC=0

# glibc 2.44 has these.
HAVE_ATTRIBUTE=1
HAVE_CMSG=1
HAVE_ENDIAN=1
HAVE_ERR=1
HAVE_FTS=1
HAVE_GETLINE=1
HAVE_GETSUBOPT=1
HAVE_ISBLANK=1
HAVE_MKDTEMP=1
HAVE_MKSTEMPS=1
HAVE_NANOSLEEP=1
HAVE_NTOHL=1
HAVE_O_DIRECTORY=1
HAVE_PATH_MAX=1
HAVE_REALLOCARRAY=1
HAVE_RECVMSG=1
HAVE_STRCASESTR=1
HAVE_STRLCAT=1
HAVE_STRLCPY=1
HAVE_STRNDUP=1
HAVE_STRPTIME=1
HAVE_STRSEP=1
HAVE_VASPRINTF=1

# glibc 2.44 does not, so mandoc compiles its own: d_namlen and EFTYPE are BSD,
# pledge is OpenBSD, sandbox_init is macOS, getprogname, recallocarray and
# strtonum are BSD library functions, <stringlist.h> and <ohash.h> are BSD
# headers, and <sys/endian.h> is where the BSDs keep what glibc puts in
# <endian.h>.
HAVE_DIRENT_NAMLEN=0
HAVE_EFTYPE=0
HAVE_OHASH=0
HAVE_PLEDGE=0
HAVE_PROGNAME=0
HAVE_RECALLOCARRAY=0
HAVE_SANDBOX_INIT=0
HAVE_STRINGLIST=0
HAVE_STRTONUM=0
HAVE_SYS_ENDIAN=0

# Word boundaries in a regular expression, which apropos passes to regcomp.
# glibc understands the System V \\< and \\>, not the BSD [[:<:]] and [[:>:]];
# this pair is genuinely behavioural rather than a matter of what compiles, and
# is the one place where running the test on the host was worth doing, since
# the host runs the same glibc 2.44 the image is built from.
HAVE_REWB_BSD=0
HAVE_REWB_SYSV=1

# strptime and vasprintf are behind _GNU_SOURCE on glibc, and configure would
# have set this itself had it been allowed to run the tests.
NEED_GNU_SOURCE=1
EOF

./configure
make -j"${JOBS}"
make install DESTDIR="${pkgdir}"

# The values above decide which of mandoc's compat_*.c files are compiled in,
# and a wrong one costs nothing at build time and shows up as a subtly wrong
# program later. config.h is what configure concluded, so it is checked rather
# than trusted.
for expected in 'HAVE_FTS 1' 'HAVE_OHASH 0' 'HAVE_WCHAR 1' 'HAVE_LESS_T 0' \
    'HAVE_REWB_SYSV 1' 'HAVE_REWB_BSD 0' 'HAVE_PROGNAME 0' 'HAVE_STRLCAT 1'; do
    grep -qx "#define ${expected}" config.h \
        || die "mandoc was configured with something other than '#define ${expected}'"
done
grep -qx '#define BINM_PAGER "/usr/bin/less"' config.h \
    || die "mandoc was not configured to page through GNU less"
grep -qx '#define _GNU_SOURCE' config.h \
    || die "mandoc was configured without _GNU_SOURCE; strptime would be missing"
# Where man looks when MANPATH is unset and there is no /etc/man.conf. The
# image has neither, so this is the manual path. It is compiled in as a char
# array short enough for the compiler to store as immediates rather than as a
# string, so config.h is the only place it can be read back from.
grep -qx '#define MANPATH_DEFAULT "/usr/share/man"' config.h \
    || die "mandoc does not use /usr/share/man as its default manual path"
grep -qx '#define MANPATH_BASE "/usr/share/man"' config.h \
    || die "mandoc does not use /usr/share/man to resolve cross references"

# The pager is another package's program, so this stage cannot check that it
# exists - image/10-rootfs.sh does, once both are in the assembled tree. What
# it can check is that nothing here still installs the wrapper that used to
# stand in front of it.
[[ ! -e "${pkgdir}/usr/bin/manpager" ]] \
    || die "the manpager wrapper is still installed; man pages through less directly now"

for program in mandoc demandoc soelim; do
    [[ -f "${pkgdir}/usr/bin/${program}" && ! -L "${pkgdir}/usr/bin/${program}" ]] \
        || die "the mandoc ${program} program was not installed"
    "${TARGET}-strip" "${pkgdir}/usr/bin/${program}"
done
# The other four names, which must be links to the one binary rather than
# copies of it. "man" is the whole point of the package.
for alias_name in usr/bin/man usr/bin/apropos usr/bin/whatis usr/sbin/makewhatis; do
    [[ -L "${pkgdir}/${alias_name}" ]] \
        || die "${alias_name} is not a symbolic link; the package carries a second copy of mandoc"
done
[[ "$(readlink "${pkgdir}/usr/bin/man")" == mandoc ]] \
    || die "/usr/bin/man does not point at mandoc"
[[ "$(readlink "${pkgdir}/usr/sbin/makewhatis")" == ../bin/mandoc ]] \
    || die "/usr/sbin/makewhatis does not point at mandoc"

[[ -f "${pkgdir}/usr/share/man/man1/man.1" ]] || die "the man manual page was not installed"
[[ -f "${pkgdir}/usr/share/man/man1/mandoc.1" ]] \
    || die "the mandoc manual page was not installed"
[[ -f "${pkgdir}/usr/share/man/man5/man.conf.5" ]] \
    || die "the man.conf manual page was not installed"
# The two language descriptions. They are the reference for what the pages in
# this image are written in, so a package that formats them and cannot describe
# them is half installed.
[[ -f "${pkgdir}/usr/share/man/man7/mdoc.7" && -f "${pkgdir}/usr/share/man/man7/man.7" ]] \
    || die "the mdoc(7) and man(7) descriptions were not installed"
[[ -f "${pkgdir}/usr/share/man/man8/makewhatis.8" ]] \
    || die "the makewhatis manual page was not installed"

"${TARGET}-readelf" -d "${pkgdir}/usr/bin/mandoc" | grep -q 'libz.so.1' \
    || die "mandoc was built without zlib; it could not read a compressed manual page"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/mandoc" | grep -q 'libc.so.6'
# mandoc is its own parser and formatter. Anything else on the link line would
# mean it found a library on the host that the image does not have.
for unwanted in libutil libz.so.0 libpcre libiconv libintl; do
    if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/mandoc" | grep -q "${unwanted}"; then
        die "mandoc links ${unwanted}; it is built to need nothing but libc and zlib"
    fi
done
if "${TARGET}-readelf" -d "${pkgdir}/usr/bin/mandoc" | grep -qE 'RPATH|RUNPATH'; then
    die "mandoc carries a run-time library path"
fi
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/mandoc" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "mandoc was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "mandoc installed files containing the build path: ${leaked}"
pkg_merge mandoc
log "installed mandoc $(source_version mandoc)"
