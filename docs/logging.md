# Logging

Sowa keeps direct service output and syslog records separately. The first tells
you what a daemon printed, including early startup failures; the second records
messages sent through `syslog(3)` and the kernel log stream.

## Service logs

The service framework starts daemons in the foreground and appends their
standard output and standard error to `/var/log/<service>.log`. Examples
include:

```text
/var/log/sshd.log
/var/log/crond.log
/var/log/chronyd.log
/var/log/network.log
/var/log/named.log
```

When a service does not start, check its file first:

```sh
tail -n 40 /var/log/sshd.log
service sshd status
```

## Syslog

syslog-ng listens on `/dev/log`, reads the kernel stream, and writes:

| File | Contents |
| --- | --- |
| `/var/log/messages` | general messages and persistent kernel records |
| `/var/log/secure` | authentication, login, `su`, `sudo`, and sshd records |
| `/var/log/cron` | commands run by crond |
| `/var/log/maillog` | mail facility messages |

`dmesg` still reads the current kernel ring buffer; `/var/log/messages` is the
copy retained across boots.

The configuration is `/etc/syslog-ng/syslog-ng.conf`. Its final commented
example shows how to forward records to a TLS collector. Apply edits without
dropping the listening socket:

```sh
service syslog-ng reload
syslog-ng-ctl stats
```

## Rotation

logrotate runs daily at 03:15 from `/etc/cron.d/logrotate`. Global policy lives
in `/etc/logrotate.conf`, with Sowa's rules in `/etc/logrotate.d/sowa`:

- per-service `*.log` files rotate weekly, retain four copies, and use
  `copytruncate`; and
- syslog-ng destinations rotate weekly, retain eight copies, and reload the
  daemon after rotation.

Rotated logs are gzip-compressed except for the newest copy. Preview or force a
run with:

```sh
logrotate --debug /etc/logrotate.conf
logrotate --force /etc/logrotate.conf
```

Place package- or site-specific rules in `/etc/logrotate.d/`.

## Package transactions

`sowa-pkg` appends state-changing transactions to `/var/log/sowa-pkg.log`. The
record includes the requested operation, plan, package versions and build IDs,
declared steps, and final result. The package database describes current state;
this log describes how the machine reached it.

```sh
tail -n 50 /var/log/sowa-pkg.log
```

See [Cron](cron.md) for scheduled jobs and `/root/sowa-howto/logging.txt` on a
running system for a short operational guide.
