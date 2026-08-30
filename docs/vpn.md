# VPNs on Sowa

Sowa ships both tunnels in the image: WireGuard, through the kernel and the
`wireguard-tools` package, and OpenVPN 2.7.6. They are not alternatives that
duplicate each other, and which one to reach for is usually decided by what is
at the other end.

**WireGuard** is a network device the kernel drives. There is no daemon and
nothing in the data path outside the kernel, a peer is a public key and a list
of addresses, and the whole configuration of an interface is a dozen lines. It
is the faster and the simpler of the two, and it is what to use when both ends
are yours.

**OpenVPN** is a userspace daemon over `/dev/net/tun` that speaks TLS. It
authenticates with X.509, so a peer is a certificate rather than a key that had
to be exchanged out of band; it runs over TCP as well as UDP, which matters on
a network that passes nothing else; and it can be *pushed* routes, addresses and
DNS by the server, so a client can be told what the network looks like instead
of being configured. It is what to use when the other end already exists.

Both are switched off in a fresh image. Neither has anything to do until a
configuration file has been written, and neither starts one on its own.

## What the kernel provides

`config/kernel-x86_64.fragment` carries both:

- `CONFIG_WIREGUARD=y` is the whole of WireGuard. This kernel has no modules,
  so it is built in, and it pulls in its own Curve25519 and ChaCha20-Poly1305
  through Kconfig `select`.
- `CONFIG_TUN=y` is the `/dev/net/tun` character device OpenVPN attaches to.
  Without it the daemon exits at startup.
- `CONFIG_IP_NF_RAW`, `CONFIG_IP6_NF_RAW`, `CONFIG_NETFILTER_XT_MATCH_ADDRTYPE`,
  `CONFIG_NETFILTER_XT_MATCH_MARK` and `CONFIG_NETFILTER_XT_TARGET_CONNMARK` are
  there for `wg-quick(8)` and nothing else. See "Routing everything" below.

A machine that will never run either can take those lines out and rebuild; the
kernel is a few tens of kilobytes smaller and nothing else in the image notices.

## WireGuard

`wg` configures an interface, `wg-quick` reads a file and issues the `ip` and
`wg` commands it describes. Both have manual pages in the image.

Make a key pair, and take the public half from it:

```sh
umask 077
wg genkey > /etc/wireguard/wg0.key
wg pubkey < /etc/wireguard/wg0.key
```

Then write `/etc/wireguard/wg0.conf`. The interface is named after the file:

```ini
[Interface]
Address = 10.10.0.2/24
PrivateKey = <the contents of wg0.key>
ListenPort = 51820

[Peer]
PublicKey = <the other end's public key>
AllowedIPs = 10.10.0.0/24
Endpoint = vpn.example.net:51820
PersistentKeepalive = 25
```

`/etc/wireguard` is mode 0700, because every file in it contains a private key.
Keep it that way.

Bring it up, look at it, take it down:

```sh
wg-quick up wg0
wg show
wg-quick down wg0
```

`AllowedIPs` is doing two jobs at once and it is worth being clear about which:
outbound it is a routing table - traffic for those addresses goes to this peer -
and inbound it is an access control list, since a packet arriving from a peer
with a source address outside its `AllowedIPs` is dropped. There is no
negotiation, so both ends have to agree.

### The service

`/etc/rc.d/init.d/wg-quick` brings up one interface for each `.conf` file in
`/etc/wireguard`, and is off by default:

```sh
chkconfig wg-quick on           # start every configured interface at boot
service wg-quick start          # or now
service wg-quick status         # what "wg show" says
service wg-quick restart wg0    # one interface by name
```

Anything `wg-quick` says goes to `/var/log/wg-quick.log`. To keep an interface
around but stop it starting at boot, rename its file to something other than
`.conf`.

### Routing everything

A peer with `AllowedIPs = 0.0.0.0/0` is the "route all my traffic through the
tunnel" case, and `wg-quick` handles it with more than a default route: it marks
the tunnel's own packets, puts everything else in a routing table selected by
the absence of that mark, and installs firewall rules that drop packets arriving
from elsewhere claiming the tunnel's address and that keep replies leaving by
the interface their requests arrived on.

Upstream writes those rules with `nft` where it finds it and with `iptables`
where it does not. Sowa ships iptables-legacy and no `nft`, so it is the
`iptables` path that runs, and the five kernel options listed above are what it
needs. They are in the fragment; if `wg-quick up` ever stops with an `iptables`
error part way through - leaving the interface created but unrouted - a missing
one of those is the first thing to check, and `wg-quick down wg0` cleans up.

### DNS

`DNS =` in an interface configuration does **not** work here. `wg-quick`
implements it by calling `resolvconf`, which Sowa does not ship. Set resolvers
in `/etc/nic.conf` instead, or write them from the interface itself:

```ini
PostUp = printf 'nameserver 10.10.0.1\n' > /etc/resolv.conf
PostDown = printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf
```

## OpenVPN

Configurations go in `/etc/openvpn`, one file per tunnel, and the tunnel is
named after the file: `/etc/openvpn/office.conf` is the tunnel `office`. The
daemon is started with `--cd /etc/openvpn`, so a configuration can name its
certificates relative to that directory, which is how nearly every OpenVPN
configuration is written. Like `/etc/wireguard`, the directory is mode 0700.

A client configuration handed over by whoever runs the server usually only needs
to be dropped in and renamed:

```sh
install -m 0600 ~/client.ovpn /etc/openvpn/office.conf
service openvpn start office
```

### The service

`/etc/rc.d/init.d/openvpn` runs one `openvpn` per configuration file, and is off
by default:

```sh
chkconfig openvpn on             # start every configured tunnel at boot
service openvpn start            # or now, all of them
service openvpn start office     # one tunnel by name
service openvpn status
service openvpn reload office    # SIGHUP: reread the configuration, renegotiate
```

Each tunnel keeps its pid in `/run/openvpn/<tunnel>.pid` and its own subsystem
lock, so they start, stop and fail independently. All of them log to
`/var/log/openvpn.log`; openvpn prefixes its own messages, so the file stays
readable with several tunnels in it. `verb 3` is the useful default in a
configuration, and `verb 4` is what to raise it to when a handshake is failing.

### How this OpenVPN is built

The build choices are worth knowing:

- **OpenSSL** is the crypto backend, the same one the rest of the image links.
  mbedTLS and wolfSSL are not built.
- **No DCO.** Data channel offload - the kernel moving packets without waking
  the daemon - is on by default upstream on Linux and is turned off here,
  because it is reached through `libnl-genl-3` and the image has no libnl. This
  is the one thing given up rather than declined; the tunnel works, it is just
  the userspace data path.
- **No compression.** LZO and LZ4 are both refused. Compression inside a TLS
  tunnel is what VORACLE attacks, upstream deprecated it and disables it at both
  ends by default. A server that insists can be met with `comp-lzo stub`.
- **No PAM plugin.** `openvpn-plugin-auth-pam` needs a library the image does
  not have. The `down-root` plugin *is* installed, at
  `/usr/lib64/openvpn/plugins/openvpn-plugin-down-root.so`; it is what lets a
  tunnel run its `--down` script after `--user` has dropped privilege.
- **No DNS hook by default.** Upstream's `--dns-updown` script on Linux drives
  systemd-resolved. Sowa has neither systemd-resolved nor resolvconf, so the
  script is not shipped and the option defaults to off. A server that pushes
  `dhcp-option DNS` will be ignored unless an `--up` script of your own writes
  `/etc/resolv.conf`.
- **libcap-ng is linked**, which is not optional on Linux: it is how openvpn
  keeps `CAP_NET_ADMIN` across the `user`/`group` it drops to, so a tunnel can
  still change routes after it has stopped being root. Note that other files it
  re-reads after dropping privilege - a CRL named by `crl-verify` is the usual
  one - have to be readable by that account, which for anything inside
  `/etc/openvpn` they will not be. Put a CRL somewhere else.

`openvpn --show-ciphers`, `--show-digests` and `--show-tls` list what this build
will negotiate.

## Both at once

Nothing stops it. WireGuard interfaces and OpenVPN tunnels are separate
services, they take no locks in common, and the shutdown links stop OpenVPN
(`K55`) and then WireGuard (`K56`) before the network goes down at `K90`.

## See also

- [init.md](init.md) for `chkconfig`, `service`, and how the runlevel links work
- [ssh.md](ssh.md), which is the other way into a machine when a tunnel breaks
- `wg(8)`, `wg-quick(8)`, `openvpn(8)` and `openvpn-examples(5)` in the image
