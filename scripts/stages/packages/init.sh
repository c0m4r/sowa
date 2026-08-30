#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# sowa-init is Sowa's own source, not a pinned upstream release, so there is
# no archive to prepare and no version to read from the lock: it is versioned by
# the distribution it is part of. Everything else is the usual shape - build in
# a copy under BUILD_DIR, install into a staging tree, check that tree, merge.
source_tree="${PROJECT_ROOT}/src/init"
build_tree="${BUILD_DIR}/sowa-init"
[[ -f "${source_tree}/init.c" ]] || die "the init sources are missing from ${source_tree}"
reset_build_dir "${build_tree}"
cp -a "${source_tree}/." "${build_tree}/"
pkgdir="$(pkg_stage sowa-init)"

target_configure_env
# The copy carries whatever a "make" run in src/init left behind, and a host
# binary is indistinguishable from a cross-compiled one by architecture alone.
# Cleaning first is what guarantees these are the compiler's output.
make -C "${build_tree}" clean
make -C "${build_tree}" VERSION="${DISTRO_VERSION}" -j"${JOBS}"
make -C "${build_tree}" DESTDIR="${pkgdir}" install

for program in init telinit shutdown halt runlevel; do
    [[ -f "${pkgdir}/sbin/${program}" ]] || die "${program} was not installed"
    "${TARGET}-strip" "${pkgdir}/sbin/${program}"
    "${TARGET}-readelf" -h "${pkgdir}/sbin/${program}" \
        | grep -q 'Advanced Micro Devices X86-64' \
        || die "${program} was not built for the target architecture"
done

# PID 1 is the one program whose absence is unrecoverable, so the checks here
# are about the shape of the installed tree rather than about the compiler.
[[ "$(readlink "${pkgdir}/sbin/poweroff")" == halt ]] \
    || die "poweroff is not linked to halt"
[[ "$(readlink "${pkgdir}/sbin/reboot")" == halt ]] \
    || die "reboot is not linked to halt"
for script in sbin/service sbin/chkconfig etc/rc.d/rc usr/bin/sowa-boottime; do
    [[ -x "${pkgdir}/${script}" ]] || die "${script} was not installed"
done
[[ -f "${pkgdir}/etc/rc.d/init.d/functions" ]] \
    || die "the init script function library was not installed"
# The library is what times the boot, and the two things that can be wrong in it
# without any build failing are silent: a wait that sleeps for a fixed length of
# time rather than polling puts half a second per service back into every boot,
# and a record written with the wrong number of fields is one sowa-boottime
# misreads rather than rejects.
if grep -q 'sleep 0\.5' "${pkgdir}/etc/rc.d/init.d/functions"; then
    die "the function library still sleeps for a fixed half second;" \
        "see daemon() and killproc()"
fi
grep -q '^timing_file=' "${pkgdir}/etc/rc.d/init.d/functions" \
    || die "the function library does not say where timing records go"
# They run under the target's Bash, and the host's parses the same language.
# The completions are in the list because they are shell too: a syntax error in
# one is not a failed build but an interactive shell that prints it at every
# Tab, and nothing else in the build would look at them.
while IFS= read -r script; do
    bash -n "${script}" || die "${script} is not valid shell"
done < <(find "${pkgdir}/sbin" "${pkgdir}/etc" "${pkgdir}/usr/bin" \
    "${pkgdir}/usr/share/bash-completion" \
    -type f \( -name service -o -name chkconfig -o -name rc -o -name functions \
    -o -name sowa-boottime -o -path '*/completions/*' \) -print)

# The manual pages. Everything in this package is a program somebody has to
# type, and until these existed the only description of any of them was the
# comment at the top of the source. They are checked by name and by what they
# declare themselves to be: mandoc looks a page up by the directory it is in
# and by its file name, so a page whose .Dt says something else is one that
# "man" finds and "apropos" files under another title.
man_page_declares() {
    local page="$1" name="$2" section="$3"
    [[ -f "${pkgdir}/usr/share/man/man${section}/${page}" ]] \
        || die "the ${page} manual page was not installed"
    grep -qi "^\.Dt ${name} ${section}\$" "${pkgdir}/usr/share/man/man${section}/${page}" \
        || die "${page} does not declare itself as ${name}(${section})"
    grep -q '^\.Os ' "${pkgdir}/usr/share/man/man${section}/${page}" \
        || die "${page} has no .Os line; mandoc would put the build host's uname in its footer"
}
man_page_declares inittab.5 INITTAB 5
for program in init telinit shutdown halt runlevel service chkconfig sowa-boottime; do
    man_page_declares "${program}.8" "${program^^}" 8
done
# halt, poweroff and reboot are one program, so they are one page. Links rather
# than copies, for the same reason poweroff and reboot themselves are links.
for alias_name in poweroff reboot; do
    [[ "$(readlink "${pkgdir}/usr/share/man/man8/${alias_name}.8")" == halt.8 ]] \
        || die "the ${alias_name} manual page is not a link to halt.8"
done

# The completions, and the one thing about them that can be wrong without
# anything failing: the loader sources the file named after the command, so a
# file that does not register the name it was installed under is a Tab that
# silently does nothing.
completion_dir="${pkgdir}/usr/share/bash-completion/completions"
for command_name in service chkconfig telinit shutdown halt init poweroff reboot \
    sowa-boottime; do
    [[ -e "${completion_dir}/${command_name}" ]] \
        || die "no bash completion for ${command_name} was installed"
    grep -qE "^complete -F [_a-z]+( [a-z]+)* ${command_name}( |\$)" \
        "${completion_dir}/${command_name}" \
        || die "the ${command_name} completion file does not register ${command_name}"
done
# The three that are other names for a program already here. A copy would be a
# second file to keep in step with the first.
[[ "$(readlink "${completion_dir}/init")" == telinit ]] \
    || die "the init completion is not a link to telinit"
for alias_name in poweroff reboot; do
    [[ "$(readlink "${completion_dir}/${alias_name}")" == halt ]] \
        || die "the ${alias_name} completion is not a link to halt"
done

pkg_merge sowa-init
log "installed sowa-init ${DISTRO_VERSION}"
