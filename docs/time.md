# Time and time zones

Sowa starts chronyd during multi-user boot to discipline the system clock. Its
configuration is `/etc/chrony.conf`, and its direct service output is written
to `/var/log/chronyd.log`.

## Synchronization

The default configuration uses `pool.ntp.org` and `time.cloudflare.com`, keeps
measured drift under `/var/lib/chrony`, permits an initial step when the clock
is more than one second out, and enables `rtcsync`.

Inspect synchronization with:

```sh
chronyc tracking
chronyc sources -v
```

chronyd can do nothing until networking is available, so it keeps retrying
after an offline boot. Replace the source lines when a deployment has its own
time service, then apply the change:

```sh
service chronyd restart
```

Network Time Security is not enabled in the current build because its required
TLS backends are not part of the image.

## Time zones

The `tzdata` package installs the IANA database below `/usr/share/zoneinfo`.
`/etc/localtime` is a symlink into that tree and defaults to UTC.

Change the system zone by replacing the link, for example:

```sh
ln -sfn /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
date
```

Applications may override the system setting with the `TZ` environment
variable. Locale selection is separate; see [Locales](locale.md).
