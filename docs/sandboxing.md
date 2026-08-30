# Landlock sandboxing

Sowa builds Landlock into its kernel and installs `landlock-sandboxer` from the
same pinned kernel source. Landlock lets a process remove its own access to
filesystem paths and TCP ports. The restriction is inherited by child
processes and cannot be widened again.

It requires no root account, capability, namespace, or system-wide policy.
Capabilities control privileges held by a process, while seccomp filters system
calls; Landlock controls which paths and ports a process may use.

## Filesystem policy

`landlock-sandboxer` reads its policy from environment variables and then
executes a command:

```sh
LL_FS_RO="/usr:/etc:/lib64" LL_FS_RW="/tmp/work:/dev/null" \
    landlock-sandboxer bash
```

The shell can read the paths in `LL_FS_RO` and write the paths in `LL_FS_RW`.
Both variables are mandatory, their entries are colon-separated, and each
entry grants access below that path. A missing path is an error.

Dynamically linked commands need read access to their loader and libraries.
Use `ldd` to inspect them. TLS clients commonly also need `/dev/urandom`, while
many commands expect `/dev/null` or `/dev/zero`.

## Network and process scope

`LL_TCP_BIND` and `LL_TCP_CONNECT` contain allowed port numbers. An unset
variable leaves that class unrestricted; an empty value denies every port:

```sh
LL_FS_RO="/usr:/etc:/lib64:/dev/urandom" \
LL_FS_RW="/dev/null:/tmp" \
LL_TCP_BIND="" LL_TCP_CONNECT="443" \
    landlock-sandboxer curl -sS https://example.com/
```

`LL_SCOPED=a` isolates abstract Unix sockets, `LL_SCOPED=s` prevents signalling
processes outside the sandbox, and `LL_SCOPED=as` enables both. Policy variables
are removed from the environment before the requested command starts.

## Troubleshooting

A denied operation normally reports `Permission denied` and may sometimes
appear as `No such file or directory`. Trace filesystem access while developing
a policy:

```sh
LL_FS_RO=... LL_FS_RW=... \
    landlock-sandboxer strace -f -e trace=file command
```

Run `landlock-sandboxer` without arguments to print usage and the Landlock ABI
offered by the running kernel. `LL_FORCE_LOG=1` requests audit logging of
denials when diagnosing a policy.

See `landlock-sandboxer(1)` and `/root/sowa-howto/sandboxing.txt` on a running
system.
