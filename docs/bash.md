# GNU Bash integration

Sowa builds GNU Bash 5.3 with all official upstream patches through patch
level 15. It is dynamically linked against Sowa's glibc, installed as
`/bin/bash`, and selected by `/bin/sh`. It is also the shell every init
script and the rc framework run under; PID 1 itself is
[sowa-init](init.md).

## Command-history logging

Bash still contains its compile-time `SYSLOG_HISTORY` feature. Sowa compiles
that code and the `SYSLOG_SHOPT` runtime control into Bash, but defaults the
option to off — a shell that records every command anyone typed is a policy
decision, not a default. syslog-ng is in the image and listening, so turning it
on is all that is needed and the commands appear in `/var/log/messages`:

```sh
shopt -s syslog_history
```

Disable it with `shopt -u syslog_history`. Bash sends each line accepted into
history through `syslog()` using the `LOG_USER` facility and `LOG_INFO` level;
the record includes the shell PID and current UID. Sowa ships no `syslogd` or
`klogd`, so enabling the option alone does not persist records.

Command logging can disclose passwords, tokens, private URLs, and other
secrets supplied as arguments. Keep the default off unless the machine's log
access, retention, and rotation policy has been defined.
