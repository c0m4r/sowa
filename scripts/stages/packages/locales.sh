#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# The compiled locales, which are what makes this image UTF-8.
#
# glibc installs 17 MB of locale definitions under /usr/share/i18n and 15 MB of
# character-set converters under /usr/lib64/gconv, and until this stage existed
# the image compiled none of them. That is not a missing feature so much as a
# system that is quietly wrong about text: with no compiled locale, setlocale
# can only succeed for "C" and "POSIX", both of which are ASCII. ls quotes every
# file name outside it, sort collates by byte, mandoc renders pages with -Tascii
# because its own configure said so in as many words, and a terminal that has
# been speaking UTF-8 since the nineties is answered in a character set that
# cannot express a Polish surname. Naming a locale that does not exist is worse
# than not naming one: every program prints a setlocale warning at startup and
# carries on in C anyway.
#
# So the image compiles the set in config/locales.conf, ships the whole
# catalogue as /etc/locale.gen, and ships locale-gen(8) so the rest can be
# compiled on a running machine - offline, out of files the image already
# carries, with no package to install. That last part is why the raw locale
# sources are worth their 17 MB.
#
# THE CROSS-COMPILE PROBLEM, AND WHY THERE IS NO HOST GLIBC HERE
#
# A locale archive is not portable: its contents are laid out for one word size
# and one byte order, and its format belongs to the C library that reads it. So
# it has to be produced by the target's own localedef, and the usual answers are
# all bad ones - run the build host's localedef and let a foreign glibc decide
# what this image's locales look like, build a second native glibc just to get a
# localedef, or put qemu-user in the middle.
#
# None of that is necessary here. The target is x86_64 and so is the build host
# - host-check.sh refuses anything else - so the localedef this build already
# produced is a program this machine can execute. It is not on the host's
# loader, which is the whole trick: it is invoked through the sysroot's own
# ld-linux with the sysroot's libraries, so the program that writes the archive
# is the pinned glibc's, exactly as it will be on the target. Nothing of the
# host's C library takes part, and the check below on its --version is what
# holds that to be true.
#
# The one requirement this places on the build host is a kernel new enough for
# the pinned glibc, which is GLIBC_MIN_KERNEL. The failure is immediate and
# says so.

glibc_source="$(prepare_source glibc)"
glibc_version="$(source_version glibc)"
supported="${glibc_source}/localedata/SUPPORTED"
locales_conf="${PROJECT_ROOT}/config/locales.conf"
source_tree="${PROJECT_ROOT}/src/locales"
pkgdir="$(pkg_stage locales)"

[[ -f "${supported}" ]] \
    || die "glibc ${glibc_version} has no localedata/SUPPORTED to take the catalogue from"
[[ -f "${locales_conf}" ]] || die "config/locales.conf is missing"

# Everything the target's localedef reads is named explicitly: the definitions
# and character maps out of the sysroot rather than the host's /usr/share/i18n,
# and the converters out of the sysroot too. localedef resolves them relative to
# these, not to --prefix, which applies to what it writes.
export I18NPATH="${SYSROOT}/usr/share/i18n"
export GCONV_PATH="${SYSROOT}/usr/lib64/gconv"

loader="${SYSROOT}/lib64/ld-linux-x86-64.so.2"
[[ -e "${loader}" ]] || loader="${SYSROOT}/lib/ld-linux-x86-64.so.2"
[[ -e "${loader}" ]] || die "the sysroot has no dynamic loader; build the toolchain first"
[[ -x "${SYSROOT}/usr/bin/localedef" ]] \
    || die "the sysroot has no localedef; glibc did not finish installing"
[[ -d "${I18NPATH}/locales" ]] || die "${I18NPATH}/locales is missing from the sysroot"

target_localedef() {
    "${loader}" --library-path "${SYSROOT}/usr/lib64:${SYSROOT}/lib64" \
        "${SYSROOT}/usr/bin/localedef" "$@"
}

# The proof that the program about to write the archive is the pinned glibc's
# and that this machine can run it at all. A host kernel older than
# GLIBC_MIN_KERNEL fails here, before an hour of compiling locales.
localedef_banner="$(target_localedef --version 2>&1 | sed -n '1p')" \
    || die "the target localedef would not run on this build host;" \
        "the host kernel may be older than the ${GLIBC_MIN_KERNEL} glibc was configured for"
[[ "${localedef_banner}" == *"${glibc_version}"* ]] \
    || die "localedef reports '${localedef_banner}', not the pinned glibc ${glibc_version}"

# glibc's own catalogue of what it supports: one "name/charset" per line, with
# the line continuations of the makefile variable it is. This is both what the
# image ships as /etc/locale.gen and what config/locales.conf is checked
# against, so a name that is not here is refused now rather than by localedef
# after the build has moved on.
declare -A catalogue=()
catalogue_order=()
while read -r name charset; do
    catalogue["${name}"]="${charset}"
    catalogue_order+=("${name}")
done < <(awk '/^[[:alnum:]]/ {
        sub(/[[:space:]]*\\$/, "")
        separator = index($0, "/")
        if (separator == 0) { next }
        printf "%s %s\n", substr($0, 1, separator - 1), substr($0, separator + 1)
    }' "${supported}")
((${#catalogue_order[@]} > 400)) \
    || die "glibc ${glibc_version} SUPPORTED parsed to only ${#catalogue_order[@]} locales"

# The set the image is built with. The list is read into a variable rather than
# straight into the loop, because a process substitution that fails is a loop
# that reads nothing and says nothing: awk refusing a malformed line has to stop
# the build.
requested_lines="$(awk '!/^[[:space:]]*(#|$)/ {
        if (NF != 2) {
            printf "config/locales.conf:%d: expected \"<name> <charset>\", got \"%s\"\n", \
                NR, $0 > "/dev/stderr"
            bad = 1
            next
        }
        print $1, $2
    }
    END { exit bad }' "${locales_conf}")" \
    || die "config/locales.conf has a line that is not \"<name> <charset>\""
[[ -n "${requested_lines}" ]] \
    || die "config/locales.conf enables no locales; the image would have no UTF-8 at all"

requested=()
requested_charsets=()
while read -r name charset; do
    [[ -n "${catalogue[${name}]:-}" ]] \
        || die "config/locales.conf asks for ${name}, which glibc ${glibc_version} does not support"
    [[ "${catalogue[${name}]}" == "${charset}" ]] \
        || die "config/locales.conf compiles ${name} against ${charset}, but glibc pairs it with ${catalogue[${name}]}"
    requested+=("${name}")
    requested_charsets+=("${charset}")
done <<< "${requested_lines}"

# /etc/locale.gen: the catalogue, with the image's own set uncommented. It is
# generated from the pinned glibc rather than kept in the repository so that it
# cannot drift from the C library that has to compile it, and it is a catalogue
# on purpose - "grep -i portuguese /etc/locale.gen" is how somebody who does not
# already know the name of their locale finds it.
install -d -m 0755 "${pkgdir}/etc"
locale_gen="${pkgdir}/etc/locale.gen"
{
    cat <<EOF
# /etc/locale.gen - which locales this machine compiles.
#
# One "<name> <charset>" per line; a line beginning with # is off. This file
# lists every locale glibc ${glibc_version} supports, which makes it the
# catalogue as well as the configuration: search it for the locale you want.
#
#     grep -i portuguese /etc/locale.gen
#     grep '^#pt_' /etc/locale.gen
#
# Nothing reads this file at run time. What programs read is the compiled
# archive /usr/lib/locale/locale-archive, so an edit here takes effect when
# locale-gen(8) has run:
#
#     locale-gen                  compile everything enabled below
#     locale-gen pl_PL.UTF-8      enable that one as well, then compile
#
# The archive is rebuilt from this file each time, so commenting a line out and
# running locale-gen removes that locale from the system.
#
# The locale a login shell starts in is /etc/locale.conf, which is a separate
# decision: see locale.conf(5). Compiling a locale does not select it.
#
# Everything needed is already installed - the definitions under
# /usr/share/i18n/locales, the character maps beside them, and localedef(1) -
# so this needs no network and no package.
EOF
    for name in "${catalogue_order[@]}"; do
        enabled=0
        for wanted in "${requested[@]}"; do
            [[ "${wanted}" == "${name}" ]] && enabled=1 && break
        done
        if ((enabled)); then
            printf '%s %s\n' "${name}" "${catalogue[${name}]}"
        else
            printf '#%s %s\n' "${name}" "${catalogue[${name}]}"
        fi
    done
} > "${locale_gen}"
chmod 0644 "${locale_gen}"

# The archive itself. --prefix decides where it is written and nothing else;
# what is read comes from I18NPATH above.
install -d -m 0755 "${pkgdir}/usr/lib/locale"
for ((index = 0; index < ${#requested[@]}; index++)); do
    name="${requested[index]}"
    charset="${requested_charsets[index]}"
    # The definition file is the name without its codeset and with its modifier
    # kept: ca_ES@valencia is a different definition from ca_ES, and no
    # definition file has ever been named after a character set.
    input="${name}"
    if [[ "${input}" == *.* ]]; then
        modifier=""
        [[ "${input}" == *@* ]] && modifier="@${input#*@}"
        input="${input%%.*}${modifier}"
    fi
    [[ -f "${I18NPATH}/locales/${input}" ]] \
        || die "glibc ${glibc_version} has no locale definition ${input} for ${name}"
    target_localedef --prefix="${pkgdir}" -i "${input}" -f "${charset}" "${name}" \
        || die "localedef could not compile ${name} from ${input}/${charset}"
done

archive="${pkgdir}/usr/lib/locale/locale-archive"
[[ -s "${archive}" ]] || die "localedef wrote no locale archive"
chmod 0644 "${archive}"

# What is in the archive, asked of the archive rather than assumed from the
# loop above. The comparison is made in the archive's own spelling, which is
# what normalise_locale_name is for.
archived="$(target_localedef --list-archive "${archive}")" \
    || die "the locale archive was written but cannot be listed"
for name in "${requested[@]}"; do
    grep -qxF "$(normalise_locale_name "${name}")" <<< "${archived}" \
        || die "${name} is not in the archive localedef just wrote"
done
archived_count="$(grep -c . <<< "${archived}" || true)"
((archived_count == ${#requested[@]})) \
    || die "the archive holds ${archived_count} locales, not the ${#requested[@]} that were asked for"

# locale-gen, and the two files it exists to serve. /usr/sbin because it writes
# /usr/lib/locale and edits /etc/locale.gen: it is administration, not a
# command a logged-in user runs.
install -d -m 0755 "${pkgdir}/usr/sbin" "${pkgdir}/etc/profile.d"
install -m 0755 "${source_tree}/locale-gen" "${pkgdir}/usr/sbin/locale-gen"
install -m 0644 "${source_tree}/locale.conf" "${pkgdir}/etc/locale.conf"
# The C library reads no configuration file, so the system locale reaches a
# program only because a login shell exported it. This is what does that.
install -m 0644 "${source_tree}/profile.d/locale.sh" "${pkgdir}/etc/profile.d/locale.sh"

install -d -m 0755 "${pkgdir}/usr/share/man/man5" "${pkgdir}/usr/share/man/man8"
install -m 0644 "${source_tree}/man/locale.conf.5" \
    "${pkgdir}/usr/share/man/man5/locale.conf.5"
install -m 0644 "${source_tree}/man/locale.gen.5" \
    "${pkgdir}/usr/share/man/man5/locale.gen.5"
install -m 0644 "${source_tree}/man/locale-gen.8" \
    "${pkgdir}/usr/share/man/man8/locale-gen.8"

# The shell that is installed is not run by this build, so nothing else here
# would notice that it stopped parsing. Both files are Bash: locale-gen is a
# program and locale.sh is sourced by /etc/profile.
for script in "${pkgdir}/usr/sbin/locale-gen" "${pkgdir}/etc/profile.d/locale.sh"; do
    bash -n "${script}" || die "${script} is not valid shell"
done
# mandoc finds a page by the directory it is in and the name of the file, so a
# page whose .Dt says something else is one man finds and apropos files
# elsewhere.
man_page_declares() {
    local page="$1" name="$2" section="$3"
    grep -qi "^\.Dt ${name} ${section}\$" \
        "${pkgdir}/usr/share/man/man${section}/${page}" \
        || die "${page} does not declare itself as ${name}(${section})"
    grep -q '^\.Os ' "${pkgdir}/usr/share/man/man${section}/${page}" \
        || die "${page} has no .Os line; mandoc would put the build host's uname in its footer"
}
man_page_declares locale.conf.5 LOCALE.CONF 5
man_page_declares locale.gen.5 LOCALE.GEN 5
man_page_declares locale-gen.8 LOCALE-GEN 8

# The default in /etc/locale.conf has to be one of the locales that were
# compiled, or the image ships a system whose every command opens with a
# setlocale warning. This is the check that would have caught it.
default_lang="$(locale_conf_lang "${pkgdir}/etc/locale.conf")"
[[ -n "${default_lang}" ]] || die "/etc/locale.conf sets no LANG"
grep -qxF "$(normalise_locale_name "${default_lang}")" <<< "${archived}" \
    || die "/etc/locale.conf sets LANG=${default_lang}, which config/locales.conf does not compile"

pkg_merge locales
log "installed locales for glibc ${glibc_version}: ${requested[*]} ($(du -h "${archive}" | cut -f1) archive), ${#catalogue_order[@]} in the catalogue for locale-gen"
