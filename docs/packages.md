# Binary packages and updates

Sowa publishes its components as binary packages and installs them with
`sowa-pkg`. The repository is a directory of static files served over HTTPS:
no package server, no API, and nothing between an installed system and its
updates but a web server handing back files.

## The shape of it

```text
build host                                   installed system
----------                                   ----------------
make image      -> work/rootfs               sowa-pkg update
                     |                          GET index + index.sig
make packages   -> work/packages/*.tar.xz     verify Ed25519 signature
                   work/packages/index        |
                   work/packages/index.sig   sowa-pkg upgrade
                     |                          GET archives, check SHA-256
make publish-repo -> dist/x86_64/  ----------->  unpack, rename into place
                     (serve over HTTPS)
```

Package archives use XZ's defaults: the build does not force a numbered
compression preset. The current client auto-detects older `.tar.gz` archives,
but clients from before the format change must be updated before pointing them
at an XZ-only repository.

Interactive archive downloads use a meter capped at 72 columns. It shows the
percentage, transferred size, average speed and ETA, and drops the bar or less
essential detail as necessary on a narrow terminal.

Packages are cut out of the assembled root filesystem rather than built
separately. `scripts/stages/image/10-rootfs.sh` decides which package owns each
path in the image, so what is published is byte for byte what the image ships,
and the union of the packages is the image by construction.

## Package ownership

Every component stage installs into its own staging tree below
`work/pkgstage/<name>` and that tree is then merged into the sysroot, so the
build still compiles and links against one sysroot exactly as before. The
staging trees are what make ownership knowable afterwards. The rootfs stage
claims each path once, in a fixed order:

1. the root filesystem overlay, which is copied last and therefore wins wherever
   a component also installed that path (`/etc/ssh/sshd_config` is the standing
   example: OpenSSH installs one and `rootfs-overlay` replaces it, so
   `sowa-release` owns it and `openssh` does not)
2. the component staging trees, in `config/packages.conf` order
3. `sowa-base`, which is everything left - the glibc runtime, `libgcc_s.so.1`,
   `libstdc++.so.6`, the development headers, and the base directory layout

`make packages` refuses to build if any path in the image is unclaimed or
claimed twice, so the ownership map cannot silently drift from the image.

Optional packages (below) take no part in that split; their manifests are cut
from their staging trees at the end of the same stage.

The result is installed into the image as its own package database at
`/var/lib/sowa/db`, so a freshly booted system already knows what it is made of
and `sowa-pkg verify` works before it has ever reached the network.

## Packages the image does not ship

The fifth field of a `config/packages.conf` row is its profile:

```text
cronie|cronie|1|sowa-base|image|Cronie crond and crontab
sowa-monitor|-|1|python|optional|Read-only live system dashboard, ...
nginx|nginx|1|openssl,zlib|optional|nginx HTTP server and reverse proxy, ...
```

An `image` package is part of the image and is cut out of it. An `optional`
package is built by the same kind of stage, from the same pinned source, against
the same sysroot - and then stops there: its stage calls `pkg_keep_staged`
instead of `pkg_merge`, so nothing it installed reaches the sysroot, the image,
or the image's package database. It is packaged from `work/pkgstage/<name>`
and appears in the index like everything else, which is what `sowa-pkg install
nginx` needs and all it needs. Sowa Monitor, nginx, HAProxy, Docker and GNU
Guix are all built that way; Sowa Monitor uses repository-owned source rather
than a pinned upstream archive.

Two rules keep such a package installable on a system built from the image:

- a directory the image already has is dropped from its manifest, because
  `/usr/sbin` belongs to the packages that made the image and two owners for one
  path is what the client refuses to install over
- a *file* the image already has is a conflict, and the rootfs stage stops the
  build rather than publishing a package that could never be installed

An image package may not depend on an optional one - `make check` rejects it -
because that would describe an image the repository cannot reproduce.

Building one is still part of `make all`: the repository is published from the
same build as the image, and its manifest is written by the rootfs stage. Only
the installing is optional.

Guix stretches all of this further than anything else does, and is worth reading
about on its own - it is unpacked rather than built, it is around 220 MiB
compressed, and its 17,600 paths are a store rather than a prefix. See
[guix.md](guix.md).

## Versions

`config/packages.conf` lists every package, the `config/sources.lock` entry its
version comes from, a release counter, its dependencies, its profile, and a
description. The published version is `<upstream>-<release>`.

That version is the update contract. The client uses version ordering to decide
what to do and never treats a checksum or build-host identity as a newer
package. Change an upstream pin when upstream changes; for a patch, recipe,
dependency rebuild, or other change at the same upstream version, bump that
package's release counter. Rebuilding the complete repository from the same Git
revision on another host can then produce different archive hashes without
offering every package as an update.

An upgrade converges the system onto newer repository versions; a version that
has gone *backwards* does not. A repository behind the machine is either
somebody rolling a package back on purpose or a repository that has been rolled
back for them — a replayed index, a mirror that stopped being updated, a
restored backup — and nothing on the client can tell those apart:

```text
$ sowa-pkg upgrade
==> warning: keeping curl 8.21.0-1 (repository has 8.20.1-1)
```

Going back is a decision, so it has to be typed: the package by name, with
`--allow-downgrade`. Anything else keeps what is installed.

## Build identity

The version deliberately says *when users should update*, not which physical
build produced an archive. Every package separately carries a `pkgbuild`: a
digest over the manifest (with a SHA-256 for every file), installed metadata,
hooks and note, together with the producer recipe/input key,
compiler/toolchain identity, and dependency build keys. It identifies the
audited build, not only coincidentally identical output.

The id travels in `.PKGINFO`, the installed database, immutable archive
filename, and signed index. It prevents two builds from colliding in caches and
lets `sowa-pkg` verify that the archive's embedded identity agrees with the
index. It is visible in `sowa-pkg info` and the audit log, but it does not take
part in update planning. At an equal version, `--reinstall` is the explicit way
to replace a package.

This separation is intentional: build ids and archive SHA-256 values can change
between clean build hosts. Only an upstream-version change or a release-counter
bump offers an update to installed systems. Forgetting the bump therefore means
the new build is published for fresh installs but is not an update.

New indexes spell the build field `pkgbuild=<digest>`. The prefix is a migration
detail with a useful property: the earlier client, which treated a bare digest
as an update identity, sees no digest there and upgrades only the packages whose
versions changed while the `sowa-release` package installs the new client. The
current client accepts both tagged and older bare build identities and verifies
either against the archive metadata.

The build id is computed twice for everything the image ships: once by
`image/10-rootfs`, into the database the image carries, and once by
`make packages`, into the index. The two have to agree, or a machine installed
from the image and the repository made alongside it would record contradictory
provenance for the same release. `scripts/package.sh` compares them before
publishing anything and refuses if they differ.

They disagreed once, and the shape of it is worth remembering. `sowa-base` and
`sowa-release` are described while `image/10-rootfs` is still running, so their
producer key has to be predicted before the stage has a stamp. A stage key
carries the pinned sources the stage was *observed* to use, and that record is
written when the stage exits — so the prediction was reading the previous run's
record, and on a build from scratch there was no record at all. The image
published an identity computed over no sources; the repository computed the same
identity over 102 of them an hour later. It was invisible on incremental builds,
where the previous run's record happened to be the right answer.

## Licences

`config/licenses.conf` gives every package a copyright holder (`sowa` or
`upstream`), an SPDX expression, and the licence texts it installs into
`/usr/share/licenses/<package>/`. Those texts are files the package owns like
any other - in its `.FILES`, resolvable with `sowa-pkg owns`, checked by
`sowa-pkg verify`, removed with the package - and they are copied out of the
same pinned tarball the code was built from, so they cannot drift from the
version they apply to.

Both fields travel in the `.PKGINFO`, in the installed database entry, and in
the index:

```text
# name|version|arch|archive|sha256|size|depends|license|copyright|pkgbuild|description
```

so `sowa-pkg info` answers for an installed package and for one merely on
offer. `sowa-license` is the program that reads all of it - the whole system in
one screen, a table of every package, or the full text of one. `make check`
rejects a package with no licence row and `make packages` refuses to publish an
archive that carries no licence. See [licensing.md](licensing.md).

## Trust

The index carries a SHA-256 for every archive, so signing the index covers the
whole repository. `make repo-key` creates an Ed25519 pair:

```sh
make repo-key
```

The private key is written outside the checkout (`~/.config/sowa/repo-ed25519.key`
by default, `REPO_KEY` overrides it) and must be backed up - it cannot be
recovered. The public half is written to
`rootfs-overlay/etc/sowa/keys/sowa-repo.pub`; commit it and rebuild the image,
because that copy is what every installation checks against. Replacing the key
invalidates every image already built with the old one.

`make packages` still works without a key and says so loudly, but
`make publish-repo` refuses to upload an unsigned index.

Verification uses OpenSSL, which the image already carries:

```sh
openssl pkeyutl -verify -rawin -pubin -inkey /etc/sowa/keys/sowa-repo.pub \
    -in index -sigfile index.sig
```

## Publishing

```sh
make image        # the packages are cut from this
make packages     # archives, index, signature
make publish-repo # assemble dist/<arch>/
```

`make publish-repo` stages the repository under `dist/${PKG_ARCH}` and stops
there; getting that directory onto a web server - rsync, a bind mount, a
container image - is deliberately left outside the build, because it is the one
part that depends on how the machine serving it is run. `DIST_DIR` overrides
the location.

Two orderings inside it are deliberate, because the directory may be served
while it is being rewritten:

- archives are written before the index, so a client that fetches the index
  mid-publish can never see it reference an archive that has not landed
- every file is written under a temporary name and renamed into place, so a
  request never catches a half-written file

Republishing is incremental: an archive already present with identical content
is left alone. The comparison is on content, not on the file name, because the
build is not yet bit-reproducible - the same version rebuilt can produce a
different archive, and publishing an index whose SHA-256 did not match the
served file would make every client refuse the package. Such an archive gets a
different build-addressed filename, but it is not an installed-system update
until its package version is bumped. Archives the current index no longer lists
are withdrawn, which `--keep-old` prevents.

The index must be signed; `--allow-unsigned` stages it anyway with a warning,
which is useful while bringing a server up but not something to serve.

## Where it is served from

The URL is not a build-time setting. It lives in `/etc/sowa/pkg.conf` as
`SOWA_REPO_URL`, the single place the client reads it, so there is nothing for
it to drift from. The images built from this tree ship
`https://sowa.wolfet.pl/x86_64`; change it in
`rootfs-overlay/etc/sowa/pkg.conf` to serve from somewhere else. A URL left as
a `example.org`-style placeholder is refused by name, by both the rootfs stage
and the client, rather than producing an image that cannot update.

Serving the repository yourself is what makes the signature load-bearing. On a
self-hosted repository the Ed25519 key is the whole of the trust: it is what
stops a compromised or impersonated server from shipping code to every machine
that trusts it. TLS protects the transport; the signature protects the content,
and only the signature survives a server that has been taken over.

## What an update trusts

The signature settles who wrote the index. Three things it does not settle are
settled separately, because each of them is a way to do damage without forging
anything.

**Whether this is the newest index that author wrote.** Anybody who can answer
for the repository URL — a network in between, a proxy, a mirror, or the server
itself once it is somebody else's — can serve last year's index and last year's
archives forever. Every signature verifies, every checksum matches, and the
machine is held at a version whose defects are public while `upgrade -y` reports
that there is nothing to do. So the index carries a `serial` and an `expires`
inside the signed bytes:

```text
# sowa-repo serial=1787435168 expires=1795211168 published=2026-08-22T21:46:08Z valid-until=2026-11-20T21:46:08Z
```

The client keeps the highest serial it has accepted in
`/var/lib/sowa/repo/serial` and refuses a lower one, refuses an expired one,
and — once it has seen a serial — refuses an index that has stopped carrying
one, because that is the same replay with the header removed. `--allow-stale`
takes any of those anyway, loudly; it exists because the machine that most needs
an update is sometimes the one that has been switched off for a year.

The other side of that is a duty: `REPO_INDEX_VALIDITY_DAYS` in
`config/build.conf` is how long a published index stays believable, ninety days
by default, and a repository that is not republished before it runs out stops
being usable by everything reading it. `make publish-repo` refuses to serve an
index whose serial is behind the one already being served, so a rollback is
found at the moment of publication rather than from machines that have gone
quiet.

**Whether the index is well formed.** A valid signature over a malformed
document is still a malformed document, and every field in it drives a
filesystem operation. Before an index replaces the one in use, every entry needs
a usable name, version, architecture, archive *basename*, 64-hex SHA-256 and
bounded positive size; no name and no archive may appear twice; every dependency
has to be a package the same index offers; the graph has to be acyclic; and no
line may carry a control character.

**Whether the package matches its own manifest.** The `.FILES` manifest is a
separate document from the archive it travels in, and it is what `mv`, `chmod`,
`rm` and `sowa-pkg verify` are all driven from. After unpacking and before
anything is moved, the staged tree has to be exactly what the manifest says —
same paths, types, modes, sizes and contents, no member the manifest does not
list, and nothing that is not a file, a directory or a link.

Manifest paths are checked too, and this is where `--root` earns its keep. Every
path has to be relative and normalised, and nothing may sit below a path the
same manifest calls a file or a link. Under `--root` the directory each entry
will be written into is then *resolved* and required to land below that root —
which a `${ROOT}/${path}` string cannot see, and which is exactly how a
`usr/lib` that is a link to `/` in an image being repaired would otherwise turn
an install into a write to the host. The manifests already in a root's database
get the same treatment before a removal, because on another root somebody else
wrote them.

`sowa-pkg --root DIR` reads that root's `pkg.conf` as well. It is parsed as
data: five known settings, one layer of quotes, no expansions, no unknown keys.
It used to be sourced, which meant repairing a downloaded image ran that image's
configuration file on the host, as root.

`scripts/selftest.sh` asserts all of it — a configuration value that tries to run
something, every malformed index shape above, a manifest that climbs out of the
root, a root whose `usr/bin` is a link to `/tmp`, an archive that disagrees with
its manifest, a replayed and an expired index, and a downgrade that was not
asked for.

## Using it on an installed system

```sh
sowa-pkg update              # fetch and verify the index
sowa-pkg list --upgradable   # what has moved
sowa-pkg upgrade             # converge on the repository
sowa-pkg install nginx       # add what the image did not ship
sowa-pkg remove nginx        # or "uninstall", which is the same command
sowa-pkg verify              # re-check every installed file
sowa-pkg owns /usr/bin/vim   # which package a path came from
sowa-pkg hooks               # the steps installed packages declare
```

`man sowa-pkg` is the reference for all of it on the machine itself, and `man
sowa-pkg.conf` for the file that says where the repository is. There is a Tab
completion too: it reads the local database and the verified index directly
rather than running `sowa-pkg`, so `install <Tab>` offers what the repository
carries and `remove <Tab>` what is installed, and neither can hang a terminal
on a repository that is not answering. `--root` is honoured while completing,
so `sowa-pkg --root /mnt install <Tab>` offers what that root's index has.

The live ISO's root filesystem is a read-only squashfs with a tmpfs written
over it, so anything installed there lands in memory and is gone at the next
boot. Updates persist on a system installed with `sowa-setup`.

Upgrading the `linux` package replaces `/boot/vmlinuz`. An installed system
boots that kernel directly, so the change takes effect on the next reboot; the
running kernel is untouched.

## How an install is applied

An archive is never unpacked over the live tree. It is unpacked into
`/var/cache/sowa/staging` and its files are then moved into place, so every
replacement is a `rename(2)`. That matters for a system upgrading itself:

- a running program keeps the inode it started with, so replacing `/bin/bash`
  under a live shell is safe
- a shared library is never truncated under the processes that mapped it, which
  is what a `cp`-style install would do to `libc.so.6` - `cp` gets `ETXTBSY` on
  a running executable but happily truncates a mapped library
- an interrupted install cannot leave a half-written binary behind
- `sowa-pkg` can therefore replace itself while it is running

Files are moved in batches grouped by destination directory, so a package with
thousands of files costs a few hundred processes rather than thousands.

## Post-install notes

Most packages are finished by being unpacked. A few have something to say
afterwards anyway - what was just done to the machine, or what is left that
only a person can decide.

Such a package gets a note. Put it in `config/messages/<name>.txt` and
`make packages` carries it in the archive as `.MESSAGE`, beside `.PKGINFO` and
`.FILES`; a package without one is built exactly as before. The client stores
it at `/var/lib/sowa/db/<name>/message` and prints it once the transaction is
over, rather than in the middle of it, so a note is not buried under the
packages installed after it:

```text
==> installing guix
==> 1 package(s) done

guix:
  Guix is set up and its daemon is running, now and at every boot. ...
```

`sowa-pkg info <name>` prints it again for whoever comes back to the machine a
week later. Upgrading to a version whose package has no `.MESSAGE` clears the
note the version before it left.

## Steps a package declares

Some packages are not finished by being unpacked at all. `guix` carries
`/gnu/store` and deliberately none of the state Guix writes to, so until
`sowa-guix-setup` has run there is no `/var/guix` for `/usr/bin/guix` to point
into and the shell answers `guix: command not found` after a completely
successful install. And a removal has the mirror image of the problem: unlinking
`/usr/sbin/sshd` does not stop the sshd that is running, because a process keeps
the inode it started with - the same property that makes replacing a live binary
safe is what leaves a listener on port 22 serving a program that is no longer on
the disk.

So a package may declare *steps*, in `config/hooks/<name>.hooks`, carried in the
archive as `.HOOKS` and kept at `/var/lib/sowa/db/<name>/hooks`:

```text
post-install|setup|/usr/sbin/sowa-guix-setup
post-install|service-enable|guix-daemon
post-install|service-start|guix-daemon
post-upgrade|setup|/usr/sbin/sowa-guix-setup
post-upgrade|service-restart|guix-daemon
pre-remove|service-stop|guix-daemon
pre-remove|service-disable|guix-daemon
```

Three events, and the difference between the first two is the point of having
both:

| Event | When |
| --- | --- |
| `post-install` | after the files of a package that was **not** installed before |
| `post-upgrade` | after the files of one that was, including a `--reinstall` |
| `pre-remove` | before a single file of a removal is deleted |

"Make this machine a Guix host and start the daemon" is a thing to do once;
"the guix package has been replaced, so re-seed what it needs and move the
daemon onto it" is what every time after that means. Keeping them apart is also
what stops a package from re-enabling at every upgrade a service the
administrator turned off.

Six actions, and there will not be a seventh without a reason:

| Action | What `sowa-pkg` does |
| --- | --- |
| `service-start <name>` | runs its init script's `start` |
| `service-stop <name>` | `stop`, if it is running |
| `service-restart <name>` | `restart`, **only** if it is running |
| `service-enable <name>` | `chkconfig <name> on` |
| `service-disable <name>` | `chkconfig --del <name>` |
| `setup <path>` | runs a program **the package itself owns** |

`sowa-pkg` implements all six itself, in the environment an init script gets at
boot and with no standard input. It prints each one before it runs it, and
`sowa-pkg hooks` prints them all without installing anything - a removal prints
the steps it is about to take as part of the plan it asks you to confirm.

### The init script a package brings with it

A hook can only name a service that exists, so a package with a daemon has to
ship the init script for it. For the packages the image is made of that script
comes from the root filesystem overlay; for the optional ones it cannot, since
a path the image already carries is a conflict their manifest is refused for -
so Sowa Monitor, nginx, HAProxy, Docker and Guix each install their own into
`/etc/rc.d/init.d`.

They ship it **switched off**, with no runlevel links hidden in the package.
`pkg_check_services` holds every optional package to that at build time by
requiring the `# chkconfig:` header to name no runlevels, and
`image/10-rootfs.sh` refuses a package that ships runlevel links of its own. A
post-install hook can then make the policy explicit: Sowa Monitor, nginx and
HAProxy remain off because installing a telemetry or web server and publishing
it are different decisions.

Guix and Docker are deliberate exceptions. A store with no daemon to build
into it is a Guix package that does not work, while installing Docker is meant
to leave an engine ready to use. Each package enables and starts its service on
the **first install only**. An upgrade restarts it only if it is running and
never re-enables what somebody turned off.

`sowa-pkg install docker` therefore installs the engine, containerd, runc, the
client, and its Buildx and Compose CLI plugins, enables Docker at boot, and
starts it immediately. `docker buildx` and `docker compose` are available
without a separate package. Removal stops the engine and removes its runlevel
links, but deliberately leaves `/var/lib/docker` intact so that images and
volumes are not mistaken for package files.

### Why this is not a post-install script

It was written down here for a long time that there would never be a
post-install hook, because arbitrary code running as root at install time would
make the index signature the only thing between a mirror and the machine. The
first half of that is still true and is why a hook is not a shell script: a
package cannot ship code for `sowa-pkg` to run. It declares which of six things
it wants done.

`setup` is the one that runs a program, and what bounds it is that the path has
to be a regular file that this package's own `.FILES` claims - checked twice, by
`pkg_check_hooks` when the package is built and by the client before it runs
anything. A hook cannot name `/bin/sh`, cannot name a path another package
placed, and cannot name anything that was not in the archive whose SHA-256 the
signed index pinned:

```text
==> warning: demo: /bin/bash is not a file demo owns
```

So the set of programs a repository can run as root is exactly the set of files
it ships - which it could already run the first time anybody used one of them,
since shipping `/bin/bash` at all means shipping something that runs as root
eventually. What the hooks change is *when* that happens, not what can be
delivered. A machine that does not want the difference sets `SOWA_RUN_HOOKS=0`
in `/etc/sowa/pkg.conf` or passes `--no-hooks`, and gets the old behaviour
exactly: a transaction that is nothing but files.

### When a step fails

A failed step does not undo an installation, because there is nothing wrong with
the installation - the files are in place and their hashes match. It is
collected, reported after the transaction, and turned into an exit status of its
own so that a script cannot mistake it for success:

```text
==> warning: 1 step(s) did not succeed; the files are installed
==> warning:   guix: post-install|service-start|guix-daemon
```

`pre-remove` is the exception: it runs before anything has been destroyed, so a
step that fails there stops the removal rather than reporting it afterwards.
`--no-hooks` is the way past a service that cannot be stopped.

Hooks are skipped entirely under `--root`, which names a root filesystem that is
being assembled or repaired rather than the one that is running. Starting its
services and running its programs against this kernel is not what was asked for.

## Configuration files

Every path below `/etc` is treated as configuration. A file that differs from
what the package installed - or that was there before any package claimed it -
is kept, and the packaged version is written beside it as `<file>.tpknew` with a
warning. Nothing under `/etc` is ever silently overwritten, and `sowa-pkg
verify` reports such files as `modified config` rather than as damage.

An upgrade also takes off the files the old version owned and the new one does
not. A file whose contents are no longer the ones the package installed is not
one of them, wherever it lives: something wrote it after the package put its
copy there, and it is kept with a warning saying which package has stopped
shipping it.

## What the client assumes

`sowa-pkg` was written for a base far smaller than the one the image ships now,
and it has not been relaxed since: a package manager that depends on as little
as possible is a package manager that can still repair a system whose `/usr` is
half-installed.

The `|`-separated manifests and index are parsed with bash's own `read`, never
with `grep`, `sed`, or `awk`. That costs one process per file instead of one per
line, and it keeps the client independent of which regular-expression dialect
the base utilities implement - which was a live concern, not a hypothetical:
this ran for a while against a base whose `grep`, `sed` and `awk` matched with
Go regular expressions, in which `|` is alternation rather than a literal, so
`grep -v '^d|'` matched every line and `awk -F'|'` reported five fields for a
three-field line.

Installs go through a staging directory rather than extracting over `/`, because
unpacking in place could not protect `/etc`, detect a conflict with another
package, or prune the files a new version dropped.

The client uses `/usr/bin/curl` by name rather than resolving it on `PATH`,
so that fetching an index always goes through the build that trusts the system
CA bundle.

Outside bash it needs `curl`, `tar`, `xz`, `openssl`, `sha256sum`, `find` and
`readlink`. The last two are what the containment and archive checks are built
on: one `find` describes an unpacked tree the same way the manifest does, and
one `readlink -m` resolves a few hundred directories per process rather than one
per call.

## Files

| Path | What it is |
| --- | --- |
| `config/packages.conf` | the package table: name, source, release, dependencies, profile, description |
| `config/messages/<name>.txt` | what a package has to say once it is installed |
| `config/hooks/<name>.hooks` | the steps a package declares for install, upgrade and removal |
| `work/pkgstage/<name>/` | what a component stage installed, before it was merged into the sysroot - and, for an optional package, the tree it is packaged from |
| `work/pkgmeta/<name>.files` | the manifest of paths a package owns |
| `work/packages/` | the archives, the index, and its signature, as built |
| `dist/<arch>/` | the same files, staged exactly as a web server should expose them |
| `/var/lib/sowa/db/<name>/` | the installed package's metadata, manifest, note and steps |
| `/usr/share/licenses/<name>/` | the licence texts that package was given to you under |
| `/var/lib/sowa/repo/index` | the last index fetched, and its signature |
| `/var/lib/sowa/repo/serial` | the highest index serial this machine has accepted |
| `/var/cache/sowa/pkg/` | downloaded archives |
| `/etc/sowa/pkg.conf` | repository URL, architecture, key, and whether a signature is required — read as data, never sourced |

## Manifest format

`|`-separated, sorted by path, one line per entry:

```text
f|0755|<sha256>|<size>|usr/bin/nano
d|0755|-|0|usr/share/nano
l|0777|vim|0|usr/bin/vi
```

Directories carry no checksum and are deliberately **not** owned exclusively -
`/usr/bin` belongs to everything that installs a program. They are created on
install and removed on uninstall only if nothing else is left in them.
