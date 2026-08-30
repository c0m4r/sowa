# Sowa Monitor

Sowa Monitor is the optional, read-only dashboard for a running Sowa machine.
The backend has no third-party Python dependencies and opens no TCP or UDP
port. It reads bounded system counters, serves a versioned JSON snapshot and
the bundled dashboard on a Unix socket, and permanently becomes `nobody`
before it accepts a request.

## Install and start

Install the backend and nginx from the signed Sowa repository:

```sh
sowa-pkg install sowa-monitor nginx
```

Both services arrive disabled. Configure nginx before starting either of them.
The complete example is installed at
`/usr/share/doc/sowa-monitor/nginx.conf.example`; it deliberately contains
invalid placeholder names and certificate paths so it cannot accidentally
publish a machine unchanged. Copy the relevant `upstream` and `server` blocks
into `/etc/nginx/nginx.conf`, then replace:

- `monitor.example.invalid` with the dashboard's DNS name;
- the TLS certificate and key paths;
- `/etc/nginx/sowa-monitor.htpasswd` with a password file nginx can read.

Check the proxy configuration, then enable and start the services:

```sh
service nginx configtest
chkconfig sowa-monitor on
chkconfig nginx on
service sowa-monitor start
service nginx start
```

The socket is `/run/sowa-monitor/sowa-monitor.sock`, owned by `nobody:nobody`
and mode 0660. The containing directory is root-owned and not group-writable.
nginx's `nobody` workers can connect but cannot replace the socket.

## What the dashboard sees

One request to `/api/v1/summary` returns:

- CPU use and load averages;
- memory, cache and swap use;
- real mounted filesystem capacity and read-only state;
- per-interface traffic totals and live rates, excluding loopback;
- process state counts and the eight largest resident sets, using process names
  but never command lines or environment variables;
- services marked active by Sowa init;
- readable thermal-zone temperatures and basic system identity.

Results are cached for half a second, lists are capped, file reads are bounded,
and concurrent request work is limited to 32 threads. The frontend polls every
two seconds and keeps its two-minute graph only in the browser.

The health endpoint at `/healthz` says that the monitor process can answer. It
does not claim the host is healthy. `/api/v1/summary` carries the dashboard's
`healthy`, `attention`, or `critical` assessment.

## Security model

The HTTP handler has an exact route table. A request cannot select a file on
disk. Only GET and HEAD are accepted; POST, PUT, PATCH, DELETE, OPTIONS, TRACE
and CONNECT receive 405. The backend does not invoke a shell or another
program, has no configuration-changing endpoint, and sends a restrictive
Content Security Policy plus anti-framing and MIME-sniffing headers.

The Unix socket is the trust boundary between the backend and nginx. nginx is
the network security boundary and must provide TLS and authentication. The
example also rejects every method other than GET and HEAD at nginx. Do not
remove authentication merely because the page contains no control buttons:
hostnames, service names, process names, capacity and load are still operational
information.

Stop the public and backend halves independently with:

```sh
service nginx stop
service sowa-monitor stop
```

Removing `sowa-monitor` stops it and removes its boot links first through the
package's declared hooks. It holds no database and leaves no application state.
