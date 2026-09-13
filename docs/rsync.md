# File transfers with rsync

The base image includes `rsync` for incremental local copies and transfers over
SSH, plus the upstream `rsync-ssl` client helper. Build the package with
`make rsync`. The release archive and its SHA-256 are pinned in
`config/sources.lock`.

```sh
rsync -a --dry-run --itemize-changes source/ backup/
rsync -a source/ backup/
rsync -az source/ user@host:/path/to/backup/
```

The trailing slash on `source/` copies its contents into the destination.
Without it, rsync copies the directory itself. SSH transfers require rsync on
both machines and use `/usr/bin/ssh` by default. Neither local nor SSH transfers
require the rsync daemon.

The build enables zlib and Zstandard compression, OpenSSL checksums, IPv6,
filename conversion through glibc iconv, and extended attributes (`-X`). Use
`-H` to preserve hard links. Archive mode (`-a`) does not include `-H` or `-X`.
ACL preservation (`-A`), LZ4 compression, and xxHash checksums are disabled
because Sowa does not package their libraries. `rsync --version` lists the
compiled capabilities. Bash completion comes from `bash-completion`.

## Optional daemon

`rsyncd` is installed but disabled at boot. Its `/etc/rsyncd.conf` binds to
`127.0.0.1:873` and exports no directories. The commented module example is
read-only, uses chroot, and runs transfers as `nobody:nobody`.

To use daemon transfers, create a directory readable by `nobody`, configure a
module in `/etc/rsyncd.conf`, then start the service:

```sh
service rsyncd start
service rsyncd status
rsync rsync://127.0.0.1/
chkconfig rsyncd on
```

Change the listen address and access controls deliberately before allowing
remote connections. Plain `rsync://` traffic is unencrypted; use SSH for
encrypted transfers. `rsync-ssl` can connect through OpenSSL to a separately
configured TLS endpoint; Sowa does not install a TLS listener for rsyncd.

The service logs to `/var/log/rsyncd.log`, covered by the existing logrotate
policy. Restart it after changing global settings. Package upgrades restart
an already running daemon; removal stops and disables it.

See `man rsync`, `man rsync-ssl`, and `man rsyncd.conf` for the upstream
references. Service management is described in [Init and services](init.md).
