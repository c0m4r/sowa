# OpenSSH on Sowa

Sowa ships the OpenSSH 10.5p1 client and server. `make openssh` builds both;
`make rootfs` pulls the stage in, so a plain `make all` includes them.

| Path | Contents |
| --- | --- |
| `/usr/bin` | `ssh`, `scp`, `sftp`, `ssh-add`, `ssh-agent`, `ssh-keygen`, `ssh-keyscan` |
| `/usr/sbin/sshd` | the server |
| `/usr/lib/openssh` | `sshd-session`, `sshd-auth`, `sftp-server`, `ssh-keysign`, the PKCS#11 and FIDO helpers |
| `/etc/ssh` | `sshd_config`, `ssh_config`, `moduli` |
| `/var/empty` | the privilege separation chroot |
| `/usr/share/man` | the upstream manual pages |

The build has no PAM, Kerberos, GSSAPI, SELinux, libedit or lastlog support.
The last of those is disabled because Sowa ships no lastlog database or reader;
without that explicit choice OpenSSH detects glibc's legacy lastlog structures
and complains about the missing `/var/log/lastlog` on every login. It links
OpenSSL 3.5.7 for cryptography, zlib for compression and libxcrypt for
`crypt(3)`, and the privilege-separated network code runs under a
`seccomp_filter` sandbox, so the image needs `CONFIG_SECCOMP_FILTER` (pinned in
the kernel fragment).

## crypt(3) and libxcrypt

glibc 2.44 no longer builds `libcrypt`, so password authentication would have
no way to check a stored hash. Sowa pins **libxcrypt 4.5.2** to supply
`crypt(3)` as `libcrypt.so.2`. `passwd` writes SHA-512 tokens of the form
`$6$rounds=100000$...` into `/etc/shadow`, and `sowa-setup` uses
`openssl passwd -6` for `SOWA_SETUP_ROOT_PASSWORD`; libxcrypt is built with
the `sha512crypt` hash enabled so `sshd-auth` reads both. `yescrypt` and
`bcrypt` are enabled as well, with yescrypt the default for new hashes.

The `strong` hash keyword is deliberately not used: it also selects the
`gost_yescrypt` and `sm3_yescrypt` national variants, which nothing here needs
and which fail to compile under GCC 16 with upstream's `-Werror`.

## Host keys

No host key is shipped in the image - that would give every Sowa installation
the same identity, and `make rootfs` fails if one is ever found in the tree.
`/etc/rc.d/init.d/sshd` instead runs `/usr/sbin/sowa-sshd-keygen` before it
starts the daemon, which creates `/etc/ssh/ssh_host_ed25519_key` on first boot
and does nothing on later boots. Ed25519 is the only type generated, matching the single `HostKey`
line in `sshd_config`; `ssh-keygen -A` adds RSA and ECDSA keys if an old client
needs them, and they then need `HostKey` lines of their own.

`sowa-setup` deletes the key it copied from the live environment, so a
freshly installed disk generates its own on its first boot.

## Starting and stopping

sshd is a System V service, started in runlevels 2 through 5 by
`/etc/rc.d/init.d/sshd`, which runs:

```
/usr/sbin/sshd -D
```

`-D` keeps sshd in the foreground. Authentication and normal daemon records go
through `syslog(3)` to syslog-ng and land in `/var/log/secure`; stderr from
host-key generation or an early start failure is appended to
`/var/log/sshd.log`. The init script deliberately does not pass `-e`, because
that would divert all OpenSSH logging away from syslog.

```sh
service sshd status
service sshd restart      # after editing /etc/ssh/sshd_config
service sshd reload       # SIGHUP; sshd re-executes itself and rereads it
service sshd stop
chkconfig sshd off        # and it does not come back at the next boot
```

See [init.md](init.md) for the service framework itself. Nothing respawns sshd
if it dies - that is what stopping it means under System V init - so a
`respawn` line in `/etc/inittab` is the way to have it watched instead.

The image ships a root-only `/etc/shadow` with entries for every stock account.
This is what shadow's tools expect, and it keeps password hashes out of
world-readable `/etc/passwd`.

## Logging in

Root is the only account on a stock image and it has an **empty password**, so
`sshd_config` ships with `PermitRootLogin prohibit-password` and
`PermitEmptyPasswords no`. Nothing can authenticate until an administrator
acts, which is what makes it safe to run sshd on a live image that boots
straight to a root prompt.

To allow a key:

```sh
mkdir -p /root/.ssh && chmod 700 /root/.ssh
printf '%s\n' 'ssh-ed25519 AAAA... you@example' > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

`/root/.ssh` is in the image already, mode 0700, and empty. No package owns
`authorized_keys` - the file is the administrator's, and a package that shipped
one would write its own copy back over it at the next upgrade. The `mkdir` above
is left in because it costs nothing on a machine that already has the
directory, and because a root that predates this is a root where it is needed.

To allow a password instead, set one and relax the policy - `prohibit-password`
blocks password logins for root even after `passwd` has run:

```sh
passwd
# then change PermitRootLogin to "yes" in /etc/ssh/sshd_config
pkill sshd
```

## Networking

The `network` service applies `/etc/nic.conf` at boot, before sshd starts, so a
booted machine already has an address: as shipped that means `eth0` up with a
DHCP lease over IPv4 and IPv6. `ip -brief addr` says what it got, and
`/var/log/network.log` says how. If the service has been turned off
(`chkconfig network off`), or the configuration needs applying again:

```sh
service network restart
```

By hand instead, with a static address:

```sh
ip link set dev eth0 up
ip addr add 192.168.1.50/24 dev eth0
ip route add default via 192.168.1.1
```

`ip` is iproute2. There is no standalone DHCP client in the image - nic has its
own - so asking for a lease means letting nic do it, against a configuration
file of your own if `/etc/nic.conf` is not what should change:

```sh
printf 'up eth0\ndhcp eth0\n' > /tmp/net.conf
nic start --config=/tmp/net.conf
```

`/etc/resolv.conf` already points at public resolvers.

## Trying it in QEMU

`scripts/run-qemu.sh` forwards host port 2222 to the guest's port 22, for every
run mode. Set `SOWA_SSH_PORT` to move it, or `SOWA_SSH_PORT=0` to drop the
forward. From the host, once the guest has an address and a key is installed:

```sh
ssh -p 2222 root@127.0.0.1
```

The same path works for arbitrary TCP and UDP services. `SOWA_QEMU_FORWARD`
accepts comma- or space-separated `HOST:GUEST[/tcp|/udp]` mappings; the protocol
defaults to TCP and a lone port maps to the same guest port:

```sh
SOWA_QEMU_FORWARD=8080:80 make run-qemu
curl http://127.0.0.1:8080

SOWA_QEMU_FORWARD='8443:443 5353:53/udp 9000' make run-disk
```

SSH and extra forwards bind to `127.0.0.1`, so they are reachable from the host
but not its network. Set `SOWA_QEMU_BIND` to another host IPv4 address when a
different scope is intentional; `0.0.0.0` exposes every forwarded service on
every host interface. Duplicate protocol/host-port pairs and ports outside
1-65535 are rejected before QEMU starts.
