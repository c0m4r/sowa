# Building Sowa in a container

Sowa's build wants around thirty host programs, a GCC no older than 10, and a
Go no older than the floor in Buildx's `go.mod`. This directory packages all of
it as a container image so that a checkout can be built on any machine that runs
containers, with nothing installed on that machine.

The image is only the host side of the bootstrap. It contains no part of Sowa,
it is not built from anything under `scripts/`, and it reads none of the
project's configuration - so it works against any revision of the repository,
including revisions written after it. The build inside is the same `make` the
top-level README documents.

## Quick start

```sh
docker/sowa-env.sh run make check     # validate the environment
docker/sowa-env.sh run make fetch     # download and verify the pinned sources
docker/sowa-env.sh run make all       # build Sowa
```

Or open a shell and work in it:

```sh
docker/sowa-env.sh shell
[builder@sowa /sowa]$ make check && make fetch && make all
```

## Signing and publishing packages

The private repository key stays outside the checkout. Pass its absolute host
path only to the invocation that cuts and signs the packages; the helper mounts
the file read-only under `/run/secrets` and points the build's `REPO_KEY` there:

```sh
SOWA_REPO_KEY="$HOME/.config/sowa/repo-ed25519.key" \
    docker/sowa-env.sh run make packages
docker/sowa-env.sh run make publish-repo
```

`make packages` signs the generated index. `make publish-repo` only stages that
already-signed index and its archives under `dist/`, so the second invocation
does not need access to the private key. The key is not copied into the image,
checkout, or build artifacts.

The first command builds the image if it is not there yet. Artifacts land in
`artifacts/` in the checkout on the host, sources in `downloads/`, and the build
tree in `work/`, exactly where a build on the host would put them.

`docker compose -f docker/compose.yml run --rm build` does the same thing if you
would rather read a compose file than a shell script; both drive the same image.

## Building a fresh clone instead

To prove a checkout builds somewhere that has never had a Sowa build in it,
clone into a volume that shares nothing with the host:

```sh
docker/sowa-env.sh clone
```

With no argument it clones *this checkout*, which needs no network and no
credentials - git clones a directory as happily as a URL - and gives a pristine
tree with nothing carried over from a build that has already happened here. The
checkout is mounted read-only for the clone to read, so the build in the volume
cannot reach back through it.

Give it a URL and optionally a branch to clone something else:

```sh
docker/sowa-env.sh clone https://github.com/you/sowa.git wip
```

A private remote needs a key. Lend it the agent rather than copying one in:

```sh
SOWA_SSH_AGENT=1 docker/sowa-env.sh clone git@github.com:you/sowa.git
```

Artifacts then stay in the volume. `docker/sowa-env.sh clean` removes it along
with the image.

## What you need on the host

Docker or Podman, an x86_64 Linux kernel, and room. A full `make all` leaves
about **38 GB** in the checkout - 31 GB of build tree under `work/`, 6 GB of
artifacts, and under 1 GB of sources - so leave **60 GB** free, and expect
**hours**: it builds a cross toolchain, a kernel, and about a hundred packages
from source. `JOBS`
controls parallelism and defaults to every CPU the container can see:

```sh
JOBS=8 docker/sowa-env.sh run make all
```

Nothing runs privileged. The disk image is assembled with `fakeroot`, `mke2fs`
and `sfdisk` rather than by mounting anything, which is what lets the whole
build run as an ordinary user inside an ordinary container.

## Booting what you built

`make run-qemu` and the other `run-*` targets work inside the container, but
without `/dev/kvm` they emulate rather than virtualise, which is slow enough to
be a different activity. Pass the device through when you want the fast one:

```sh
SOWA_KVM=1 docker/sowa-env.sh run make run-qemu
```

It is off by default because a container that can open `/dev/kvm` can use the
host's hardware virtualisation, and that is not something to hand over silently
for a build. The QEMU targets are headless and exit with `Ctrl-a x`.

Alternatively, don't: the artifacts are on the host, so `make run-qemu` from the
host works too, on a host that has QEMU.

## Who the build runs as

`scripts/host-check.sh` refuses to build as root, correctly, so the container
does not. It starts as root, moves its `builder` account onto your UID and GID,
and drops privilege before your command runs. That is why a bind-mounted
checkout comes back owned by you rather than by root.

`sudo` works inside without a password, so a missing host-side package can be
installed while diagnosing the environment instead of requiring an image
rebuild first.

## Why this base

Sowa pins recent upstreams, so its container base must provide Go at least as
new as the floor in Buildx's `go.mod`, the GCC version used for development,
and GRUB's `i386-pc` and `x86_64-efi` platform trees. The selected base provides
those together through its package manager, avoiding tool archives layered over
the container filesystem.

## Pinning the environment

A rolling base means `docker build` is not reproducible by default. Two build
arguments make it so, and they only work together:

```sh
SOWA_ARCH_SNAPSHOT=2026/08/23 docker/sowa-env.sh build
```

`ARCH_SNAPSHOT` points the mirror list at the dated package archive, so the
package set is a function of the date rather than the day of the build.
`BASE_IMAGE` pins the starting point; on its own it pins very little, because
the upgrade step moves everything to whatever is current.

## Files

| File | What it is |
| --- | --- |
| `Dockerfile` | The environment: the host prerequisites and the unprivileged account |
| `entrypoint.sh` | UID mapping, the optional clone, and dropping privilege |
| `compose.yml` | The two ways of running it, as compose services |
| `sowa-env.sh` | The same two, as one command, and working with Podman |
