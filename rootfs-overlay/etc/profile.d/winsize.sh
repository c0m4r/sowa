# Learn the real terminal size when logging in over a serial line.
# shellcheck shell=bash
#
# The video console needs none of this: the kernel draws it and therefore knows
# how big it is. A serial tty is stamped 24x80 by agetty and never corrected,
# which leaves Bash wrapping lines in the wrong place. See /usr/bin/resize.
#
# Only for an interactive shell - nothing else has a screen to size - and only
# on a line where the size is not already known, so a login on tty1 does not
# spend a second interrogating a terminal the kernel measured itself.

if [[ $- == *i* ]]; then
    case "$(tty 2>/dev/null)" in
        /dev/ttyS[0-9]* | /dev/ttyUSB[0-9]* | /dev/ttyAMA[0-9]*)
            eval "$(/usr/bin/resize 2>/dev/null)" || true
            ;;
    esac
fi
