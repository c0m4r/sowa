# Networking

Sowa uses `nic` for declarative interface configuration, iproute2 for routing
and link administration, and iptables for packet filtering. The `network`
service applies `/etc/nic.conf` during multi-user boot.

## Interface configuration

The shipped configuration brings up `eth0` and requests a DHCP lease:

```text
up eth0
dhcp eth0

include nic.d/*.conf
```

Inspect and apply it with:

```sh
nic show
nic dry-run
nic start
nic status
```

`nic dry-run` prints the operations without changing the machine. The annotated
reference at `/usr/share/doc/nic/nic.conf` covers static addresses, routes,
resolvers, and included files. Files below `/etc/nic.d/` are loaded in natural
sort order.

Apply changes through the service framework:

```sh
service network restart
chkconfig network off
```

The initial `/etc/resolv.conf` contains public resolvers so name resolution is
available once a route exists. Resolver directives in `nic.conf` can replace
it for a specific deployment.

## Routing and packet filtering

iproute2 supplies `ip`, `ss` (also available as `netstat`), `tc`, and `bridge`.
Useful first checks are:

```sh
ip address
ip route
ip -6 route
ss -lntup
```

Sowa installs the legacy iptables interface for IPv4 and IPv6. The kernel has
the filter, mangle, and NAT tables plus common conntrack, masquerade, reject,
logging, multiport, limit, and comment matches built in.

```sh
iptables -L -n -v
ip6tables -L -n -v
iptables-save
```

No firewall ruleset is loaded by default. Persist one with a local init script
or another explicit boot-time action. VPN-specific packet handling is described
in [VPNs](vpn.md).

## Diagnostic tools

The image includes tools for the common layers of network diagnosis:

- `ping`, `ping6`, `mtr`, and `ss` for reachability and sockets;
- `dig`, `host`, and `nslookup` for DNS;
- `tcpdump` for packet capture;
- `curl`, `wget`, and `openssl s_client` for application and TLS checks; and
- `whois`, `lspci`, and `ethtool`-independent kernel information exposed through
  `ip` and `/sys`.

Nmap, Ncat, and Nping are published as an optional package:

```sh
sowa-pkg install nmap
```

The BIND server is installed but disabled by default. Its shipped configuration
defines a validating resolver on the loopback interface. Enable it only after
reviewing `/etc/named.conf`:

```sh
chkconfig named on
service named start
```

## QEMU port forwarding

The QEMU targets use unprivileged user-mode networking. Host port 2222 is
forwarded to guest SSH port 22 by default. Extra forwards use
`HOST:GUEST[/tcp|/udp]`:

```sh
SOWA_QEMU_FORWARD=8080:80 make run-qemu
SOWA_QEMU_FORWARD='8080:80 8443:443 5353:53/udp' make run-disk-image
```

Comma-separated mappings are also accepted, and a single port such as `8080`
means `8080:8080`. Forwards bind to `127.0.0.1` by default.
`SOWA_QEMU_BIND=0.0.0.0` exposes them on every host interface and should be used
only deliberately. Set `SOWA_SSH_PORT=0` to disable the default SSH mapping or
choose another host port.

See [OpenSSH](ssh.md) for login setup and [Sowa Monitor](sowa-monitor.md) for
the optional read-only dashboard.
