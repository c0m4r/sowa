# The system locale, for every login shell.
# shellcheck shell=bash
#
# glibc reads no configuration file of its own: LANG and the LC_* variables are
# the whole of how a program is told what language, character set, collation and
# formats to use, and something has to put them in the environment. On a system
# with systemd or PAM that is pam_env reading /etc/locale.conf; here there is
# neither, so this is that something, and /etc/locale.conf is the file it reads.
#
# What is already set is left alone. sshd_config accepts LANG and LC_* from the
# client, so a person logging in from a machine that speaks Polish keeps their
# own locale rather than being given the server's - which is the behaviour every
# other Unix has and the reason AcceptEnv exists. su(1) and login(1) pass the
# environment they were given through the same way.
#
# The file is parsed rather than sourced. It is root's file and sourcing it
# would work, but a configuration file is data, and the parse is what keeps a
# stray line in it from being a command every login shell runs.

if [[ -r /etc/locale.conf ]]; then
    while IFS='=' read -r locale_variable locale_value; do
        case "${locale_variable}" in
            LANG | LANGUAGE | LC_ALL | LC_CTYPE | LC_NUMERIC | LC_TIME \
                | LC_COLLATE | LC_MONETARY | LC_MESSAGES | LC_PAPER | LC_NAME \
                | LC_ADDRESS | LC_TELEPHONE | LC_MEASUREMENT \
                | LC_IDENTIFICATION) ;;
            *) continue ;;
        esac
        [[ -n "${!locale_variable:-}" ]] && continue
        locale_value="${locale_value%\"}"
        locale_value="${locale_value#\"}"
        # A locale name, or LANGUAGE's colon-separated list of them. Anything
        # else is a line that would put nonsense in the environment of every
        # program on the system.
        [[ "${locale_value}" =~ ^[A-Za-z0-9_@.:+-]+$ ]] || continue
        export "${locale_variable}=${locale_value}"
    done < /etc/locale.conf
    unset locale_variable locale_value
fi
