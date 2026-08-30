# /etc/bash.bashrc - the interactive defaults every Bash session starts from.
#
# Bash reads this file for an interactive shell that is not a login shell, and
# only because the bash stage turns on SYS_BASHRC, which upstream ships
# commented out. Login shells get here through /etc/profile, which sources it
# for exactly that reason.
#
# Everything in this file is presentation. Nothing a script depends on belongs
# here, because a non-interactive shell never reaches it.

# Bash normally skips this file for a non-interactive shell, but BASH_ENV can
# reach it anyway, and a prompt set in a shell with no terminal is at best
# wasted work.
[[ $- != *i* ]] && return

PS1='[\u@\h \w]\$ '

HISTFILESIZE=5000
HISTSIZE=5000

alias ip='ip --color'
alias grep='grep --color'
alias ls='ls --color=auto'

# Some packages Sowa builds and publishes are deliberately not in the image:
# they are servers and toolchains that most machines should not be running, and
# an installed system fetches them by name when it wants them. The failure that
# produces is "command not found", which is true and useless - the program is
# one command away and nothing says so.
#
# Bash calls this function instead of printing that message. The names below are
# the programs the optional packages install; 10-rootfs.sh checks this list
# against their staging trees at build time, so a new optional package whose
# commands are missing here fails the build rather than shipping a system that
# cannot tell anyone how to get it.
#
# A package that is actually installed never reaches this code, because then the
# command exists and Bash runs it.
command_not_found_handle() {
    local attempted="$1"
    local package=

    case "${attempted}" in
        sowa-monitor) package=sowa-monitor ;;
        nginx) package=nginx ;;
        haproxy | haproxy-dump-certs | haproxy-reload) package=haproxy ;;
        docker | ctr | docker-init | dockerd | docker-proxy | containerd | containerd-shim-runc-v2 | runc) package=docker ;;
        guix | sowa-guix-setup) package=guix ;;
        7z | 7zz) package=7zip ;;
        nmap | ncat | nping) package=nmap ;;
    esac

    if [[ -n "${package}" ]]; then
        printf '%s: not installed. It is in the Sowa repository:\n\n    sowa-pkg install %s\n\n' \
            "${attempted}" "${package}" >&2
    else
        printf 'bash: %s: command not found\n' "${attempted}" >&2
    fi
    return 127
}
