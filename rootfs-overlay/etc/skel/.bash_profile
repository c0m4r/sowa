# ~/.bash_profile - read once by a login shell, before anything else of yours.
#
# A login shell reads /etc/profile and then this file, and does not read
# ~/.bashrc at all. Sourcing it here is what keeps a session that arrived
# through login the same as one started from a shell that was already running.
[[ -f ~/.bashrc ]] && . ~/.bashrc
