# Cron on Sowa

Sowa ships [Cronie](https://github.com/cronie-crond/cronie) 1.7.2. `make cron`
builds it, and `make rootfs` includes it automatically. The image starts
Cronie from `/etc/rc.d/init.d/crond`, which runs:

```
/usr/sbin/crond -n -m off
```

`-n` keeps the daemon in the foreground, which is how its own output reaches
`/var/log/crond.log`: the init script starts it under `setsid` with that
redirection, so that what crond says about itself — a table it could not parse,
a job it could not run — is in one file. What it ran and for whom goes through
`syslog(3)` to syslog-ng and lands in `/var/log/cron`. `-m off` disables mail
delivery, because there is no mail transfer agent; redirect any output that
matters from a job to a file in `/var/log` instead.

`chkconfig --list crond` shows the runlevels it starts in - 2 through 5 - and
`service crond {start|stop|restart|status}` drives it by hand. See
[init.md](init.md) for the rest of the service framework.

## Adding jobs

For root's personal crontab, use the standard five time fields followed by a
command:

```sh
crontab -e
# minute hour day-of-month month day-of-week command
* * * * * /usr/bin/date >>/var/log/cron-example.log 2>&1
```

`crontab -l` lists the installed table, `crontab -r` removes it, and
`crontab -T FILE` checks a file before installation. Per-user tables are stored
privately in `/var/spool/cron`; do not edit those files directly.

`/etc/crontab` and files in `/etc/cron.d` use a sixth field to select the
account that runs the command:

```
# minute hour day-of-month month day-of-week user command
17 * * * * root /usr/bin/python3 /root/hourly-task.py >>/var/log/hourly-task.log 2>&1
```

The stock `/etc/crontab` contains only comments, and `/etc/cron.d` is ready for
package or site files. The e2fsprogs e2scrub schedule is intentionally omitted:
it needs LVM and systemd services that Sowa does not ship. Cronie notices table
changes through inotify; restarting the daemon is not normally necessary. To
apply a daemon option change, edit `/etc/rc.d/init.d/crond` and run
`service crond restart`.

## Environment and access

Jobs use `/bin/sh` (Bash in Sowa) and Cronie's limited default `PATH`; set
`SHELL`, `PATH`, and other environment variables explicitly in a crontab when a
job needs them. Cron follows the system clock, and Sowa does not yet include a
time-synchronization service, so ensure the clock is correct before relying on
time-sensitive jobs.

`/usr/bin/crontab` is setuid root solely to replace validated files in the
root-owned spool. With neither `/etc/cron.allow` nor `/etc/cron.deny` present,
Cronie permits only root to use `crontab`, matching Sowa's stock root-only
account set. After adding users, create `/etc/cron.allow` with one allowed user
name per line to grant them access.
