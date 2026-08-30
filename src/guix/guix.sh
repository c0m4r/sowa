# /etc/profile.d/guix.sh - the environment GNU Guix expects, when it is there.
#
# Two profiles matter, and neither exists until someone asks for it, so each is
# only added if it is present: this file is inert on a machine where nobody has
# run guix.
#
#   ~/.config/guix/current   the "guix pull" profile - guix itself. root's is
#                            linked by sowa-guix-setup; another user's appears
#                            the first time they run "guix pull".
#   ~/.guix-profile          the default profile - what "guix install" fills.
#
# /usr/bin/guix is what makes the command available before any of this: it is a
# link into root's pull profile, shipped by the guix package, and it is how a
# user who has never pulled runs guix at all.
#
# The work is in a function rather than written out once, because it has to
# happen more than once. A profile is created by the command that first installs
# into it, which is to say after the shell that ran the command had already
# started, so a login shell that read this file before there was a profile has
# none of the profile's environment - and that is exactly what guix says at the
# end of every such install:
#
#   hint: Consider setting the necessary environment variables by running:
#
#        GUIX_PROFILE="$HOME/.guix-profile"
#        . "$GUIX_PROFILE/etc/profile"
#
# No child process can do that for the shell that started it, which is why guix
# asks rather than acts, and why /usr/bin/guix could not do it either. A shell
# function runs in the shell itself and can. That is the "guix" at the bottom of
# this file: it runs the real command and then applies the profiles again, so
# the hint describes something that has already happened by the time it is read.

# Every search path applying the profiles prepends to. Doing it a second time
# would otherwise put another copy of each directory in front of the one already
# there, so the list is folded afterwards - the first occurrence of an entry is
# kept and the rest are dropped, which leaves a re-application with no effect
# rather than with a longer PATH. Empty entries, which name the current
# directory, are dropped with them.
_sowa_guix_search_paths='PATH INFOPATH MANPATH GUILE_LOAD_PATH GUILE_LOAD_COMPILED_PATH GUIX_LOCPATH'

_sowa_guix_fold() {
    eval "_sowa_guix_value=\${$1-}"
    [ -n "${_sowa_guix_value}" ] || return 0

    # Splitting on ":" is what the loop is for, and unquoted expansion is also
    # where the shell would expand a "*" in a directory name, so globbing is
    # switched off for the length of it and switched back only if it was on.
    case $- in
        *f*) _sowa_guix_glob=kept ;;
        *) _sowa_guix_glob=disabled; set -f ;;
    esac
    _sowa_guix_ifs="${IFS}"
    IFS=:
    _sowa_guix_folded=
    for _sowa_guix_entry in ${_sowa_guix_value}; do
        [ -n "${_sowa_guix_entry}" ] || continue
        case ":${_sowa_guix_folded}:" in
            *":${_sowa_guix_entry}:"*) continue ;;
        esac
        _sowa_guix_folded="${_sowa_guix_folded:+${_sowa_guix_folded}:}${_sowa_guix_entry}"
    done
    IFS="${_sowa_guix_ifs}"
    [ "${_sowa_guix_glob}" = disabled ] && set +f

    eval "$1=\${_sowa_guix_folded}"
    export "$1"
    unset _sowa_guix_value _sowa_guix_folded _sowa_guix_entry \
        _sowa_guix_ifs _sowa_guix_glob
}

_sowa_guix_environment() {
    if [ -d "${HOME}/.config/guix/current/bin" ]; then
        export PATH="${HOME}/.config/guix/current/bin${PATH:+:}${PATH}"
        export INFOPATH="${HOME}/.config/guix/current/share/info:${INFOPATH:-}"
        export MANPATH="${HOME}/.config/guix/current/share/man:${MANPATH:-}"
        # Guile has to find the modules of the same generation as the guix that
        # is running, or "guix repl" and "guix shell" load whatever is older.
        export GUILE_LOAD_PATH="${HOME}/.config/guix/current/share/guile/site/3.0${GUILE_LOAD_PATH:+:}${GUILE_LOAD_PATH:-}"
        export GUILE_LOAD_COMPILED_PATH="${HOME}/.config/guix/current/lib/guile/3.0/site-ccache${GUILE_LOAD_COMPILED_PATH:+:}${GUILE_LOAD_COMPILED_PATH:-}"
    fi

    if [ -f "${HOME}/.guix-profile/etc/profile" ]; then
        GUIX_PROFILE="${HOME}/.guix-profile"
        export GUIX_PROFILE
        # The profile describes its own search paths - PATH, and whatever else
        # the packages in it need - so it is sourced rather than second-guessed.
        # It is also the reason the folding below is not limited to the
        # variables named in this file: a package can bring a search path of its
        # own with it, and that one is prepended to here too.
        . "${GUIX_PROFILE}/etc/profile"
        # Locales are a package like any other ("guix install glibc-locales"),
        # and the C library in the store looks for them here rather than in
        # /usr/lib.
        if [ -d "${GUIX_PROFILE}/lib/locale" ]; then
            export GUIX_LOCPATH="${GUIX_PROFILE}/lib/locale${GUIX_LOCPATH:+:}${GUIX_LOCPATH:-}"
        fi
    fi

    for _sowa_guix_path in ${_sowa_guix_search_paths}; do
        _sowa_guix_fold "${_sowa_guix_path}"
    done
    unset _sowa_guix_path
}

_sowa_guix_environment

# The wrapper. Only the subcommands that can create or replace a profile are
# followed by applying it again - "guix build" and "guix describe" change
# nothing about the environment, and re-reading the profile after every command
# would be work done for nothing.
#
# "command" is what keeps this from calling itself, and the exit status of the
# real guix is the exit status of the function: a script that tests whether an
# install succeeded gets the same answer it would have got without any of this.
guix() {
    command guix "$@"
    _sowa_guix_status=$?

    case "${1:-}" in
        install | remove | upgrade | package | pull)
            _sowa_guix_before="${PATH}"
            _sowa_guix_environment
            # Said only when the environment actually gained something, and only
            # to somebody who is there to read it. It is the answer to the hint
            # guix has just printed above it.
            if [ "${PATH}" != "${_sowa_guix_before}" ]; then
                case $- in
                    *i*) printf 'guix: this shell now has the profile in its environment\n' >&2 ;;
                esac
            fi
            unset _sowa_guix_before
            ;;
    esac

    return "${_sowa_guix_status}"
}
