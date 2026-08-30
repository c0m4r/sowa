# Optional packages

Packages with the `optional` profile in
[`config/packages.conf`](../config/packages.conf) are built and published with
the base system but are not merged into the image. They use the same pinned
inputs, target libraries, manifests, signatures, and package hooks as software
that ships by default.

After configuring a repository:

```sh
sowa-pkg update
sowa-pkg list --available
sowa-pkg install <name>
```

The current optional set is 7-Zip, Nmap, Sowa Monitor, nginx, HAProxy, GNU Guix,
and Docker. The package table remains the authoritative inventory.

## nginx

nginx is built with TLS, HTTP/2, `gzip_static`, real IP handling, and
`stub_status`. PCRE2 is linked statically. Workers run as `nobody`, the default
document root is `/usr/share/nginx/html`, and logs go to `/var/log/nginx`.

```sh
sowa-pkg install nginx
service nginx configtest
chkconfig nginx on
service nginx start
```

Its configuration is `/etc/nginx/nginx.conf`. The service is disabled when
first installed, so placing the package on disk does not publish a server.
`configtest` validates changes before start, and `reload` starts workers with
the new configuration while established connections finish on the old workers:

```sh
service nginx configtest
service nginx reload
```

Package hooks restart nginx on upgrade only when it is already running. Removal
stops it and removes its runlevel links before deleting package-owned files.
Inspect the declared actions with `sowa-pkg hooks nginx`.

## HAProxy

HAProxy is built with threads, TLS, zlib, and the built-in Prometheus exporter.
The shipped `/etc/haproxy/haproxy.cfg` exposes only the statistics endpoint on
port 8404, with metrics below `/metrics`, providing a valid starting
configuration before any backends are defined.

```sh
sowa-pkg install haproxy
service haproxy configtest
chkconfig haproxy on
service haproxy start
service haproxy reload
```

The service runs in foreground master-worker mode. Reload uses HAProxy's
graceful re-exec path so established connections can finish. It is disabled
until explicitly enabled.

## Docker

The Docker package combines Docker Engine, containerd, runc, the command-line
client, `docker-init`, Buildx, and Compose. Buildx and Compose are installed as
CLI plugins:

```sh
sowa-pkg install docker
docker buildx version
docker compose version
docker run --rm hello-world
```

The supplied kernel enables cgroup v2, bridge, veth, overlayfs, namespaces, and
the packet-filtering features needed by the engine. First-install hooks enable
and start the service. An upgrade restarts it only when already running and
does not re-enable a service disabled by the administrator. Removal preserves
`/var/lib/docker`, treating images and volumes as machine data rather than
package payload.

This repository also produces a Sowa rootfs container artifact with
`make docker-image`. That artifact is a deployment format; it is separate from
the optional Docker engine package. See [Building Sowa](building.md).

## 7-Zip and Nmap

7-Zip installs `7zz` and the `7z` alias:

```sh
sowa-pkg install 7zip
7z l archive.7z
```

Nmap installs `nmap`, `ncat`, and `nping` for network discovery, auditing, and
connectivity tests:

```sh
sowa-pkg install nmap
```

## Sowa Monitor and GNU Guix

These packages have dedicated guides because they require additional setup:

- [Sowa Monitor](sowa-monitor.md) — Unix-socket dashboard and reverse-proxy example
- [GNU Guix](guix.md) — store layout, build users, daemon, profiles, and removal

See [Binary packages and updates](packages.md) for profiles, ownership,
configuration-file handling, hooks, and repository trust.
