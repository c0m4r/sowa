# GNU Guix

Sowa publishes GNU Guix 1.5.0 as an optional binary package. An installed
system adds it on demand:

```sh
sowa-pkg install guix     # /gnu/store, the Sowa glue, and the setup below

guix describe
guix install hello
```

The three steps that used to come between those two lines are declared by the
package and taken by `sowa-pkg`, which prints each one as it runs it:

```text
==> running /usr/sbin/sowa-guix-setup     build users, /var/guix, root's profile, keys
==> enabling guix-daemon at boot
==> starting guix-daemon
```

`sowa-pkg hooks guix` prints them again without installing anything, and
`sowa-pkg install --no-hooks guix` declines them and leaves the three commands
to be typed by hand - they are still exactly the commands above, and
`sowa-guix-setup` is still safe to run again at any time. See
[packages.md](packages.md#steps-a-package-declares) for what a hook can and
cannot be.

Nothing else on the system changes. Guix installs into `/gnu/store` and into
per-user profiles; the packages it builds are its own and know nothing about
Sowa's.

## The environment

`guix install` ends by printing a hint:

```text
hint: Consider setting the necessary environment variables by running:

     GUIX_PROFILE="/root/.guix-profile"
     . "$GUIX_PROFILE/etc/profile"
     unset GUIX_PROFILE
```

It says that because the profile it just created did not exist when the shell
started, so nothing put it in the shell's environment - and no child process can
change the environment of the shell that started it, which is why guix asks
instead of doing it.

`/etc/profile.d/guix.sh` answers the hint twice over. At login it applies both
profiles if they are there, so a shell that starts on a machine where Guix is
already in use needs nothing. And it defines `guix` as a shell function that
runs the real command and then applies them again, so a profile created by
`guix install`, `guix remove`, `guix upgrade`, `guix package` or `guix pull` is
in the environment of the shell that ran it by the time the hint is on the
screen:

```text
$ guix install hello
...
hint: Consider setting the necessary environment variables by running:
...
guix: this shell now has the profile in its environment
$ hello
Hello, world!
```

The function runs the real `/usr/bin/guix` through `command`, passes its exit
status on unchanged, and re-applies nothing for the subcommands that cannot
change a profile. Applying a profile twice is harmless: the search paths it
prepends to are folded afterwards, so the second application leaves `PATH` as
it was rather than with a second copy of every directory in it.

A script that runs `guix` gets `/usr/bin/guix` and none of this, because a
shell function is not inherited by a child process. That is the right answer for
a script - it should not have its environment rewritten under it - and it is why
the hint still exists for the case where a program, rather than a person, is
driving.

Installing it needs GNU tar, which is in the image as of the same release that
added this package. That is not incidental: the store is built out of absolute
symbolic links, and the tar the image carried before refused those on
extraction, so an earlier Sowa stopped at

```text
tar: unsafe absolute symbolic link "gnu/store/1hjkcmzrcb0d2sf9afkmyx1pcvln97ss-"
```

and installed nothing.

This is by far the largest thing Sowa publishes. The archive is around 220 MiB,
it unpacks to about 870 MiB, and sowa-pkg stages an install under
`/var/cache/sowa` before renaming it into place - so the installing system
wants something like 2 GiB free, and everything Guix goes on to build lands in
`/gnu/store` on top of that. It is not for the live ISO, which runs from RAM;
it is for a machine `sowa-setup` has installed to disk.

## Why this one is unpacked rather than built

Every other component in Sowa is compiled from a pinned source tarball. Guix is
not, and cannot reasonably be: it is a package manager written in Guile that
bootstraps its own world, so building it needs Guile, a dozen Guile libraries,
and a store to put them in - which is to say it needs Guix. Upstream's answer to
that circularity is the *binary installation* its manual documents: a tarball of
a working store, unpacked at `/gnu`.

So `scripts/stages/packages/guix.sh` unpacks rather than builds, and what it
unpacks is pinned in `config/sources.lock` by SHA-256 like every other source:

```text
guix|1.5.0|guix-binary-1.5.0.x86_64-linux.tar.xz|https://ftp.gnu.org/gnu/guix/...|aa41...|-
```

Upstream signs that tarball with OpenPGP and `guix-install.sh` verifies the
signature; Sowa has no GnuPG in the image or in its host requirements, and
pins the hash instead - the same trust decision it makes for GCC, glibc and the
kernel. Once the package is cut, the Sowa repository's own Ed25519 signature is
what an installed system checks, and `sowa-pkg verify` re-checks every file
against the SHA-256 the package recorded.

The tarball is x86_64-linux, and the stage refuses to run for any other
`PKG_ARCH`. A port to another architecture needs the pin for that architecture's
tarball, not a cross-build of this one: the binaries inside carry their own C
library and interpreter and refer to each other by absolute store path, which is
also why they can only ever be unpacked at `/gnu`.

`make all` therefore downloads 128 MiB and unpacks about 870 MiB into
`work/pkgstage/guix`. `make guix` on its own does the same and needs neither the
cross toolchain nor the sysroot, since nothing here is compiled.

## What the package owns, and what it does not

The package carries the store, the seeds, and the Sowa glue:

```text
/gnu/store/...              the 84 store items the tarball ships
/usr/share/guix/db.sqlite   the pristine store database, as a seed
/usr/share/guix/current-guix a link to the profile generation the tarball was built with
/usr/bin/guix               into root's pull profile, so guix is a command for everyone
/usr/sbin/sowa-guix-setup  what turns an unpacked store into a working Guix
/etc/rc.d/init.d/guix-daemon the service
/etc/profile.d/guix.sh      the environment an interactive shell needs
```

The split is the point. A store path names its own contents, so store items are
immutable by construction and two versions of Guix never claim the same path:
sowa-pkg can own, verify and upgrade them exactly as it owns any other set of
files, and an upgrade adds the new items and removes the old ones - which is
what a store upgrade *is*.

Everything Guix writes is state, and a package must not own state. The tarball's
`/var/guix` is therefore deliberately not packaged: `/var/guix/db/db.sqlite` is
the record of what this machine has installed, and the profile links record
which generation it is on. A package that owned them would throw all of that
away on the next `sowa-pkg upgrade`. They are seeded into place once, by
`sowa-guix-setup`, and belong to the machine from then on.

That split has one sharp edge: `/usr/bin/guix` points into `/var/guix`, so
between unpacking the store and creating that state it is a dangling symbolic
link, and the shell reports a dangling link in `PATH` as `guix: command not
found`. A completely successful install used to look like a broken one, which is
why the package carried a note saying what to run next.

It now carries the step instead. `config/hooks/guix.hooks` declares
`post-install|setup|/usr/sbin/sowa-guix-setup`, so the state exists before the
install is over and the note says what was done rather than what to do; see
[packages.md](packages.md#steps-a-package-declares). The note is still there and
`sowa-pkg info guix` still prints it, because `--no-hooks` and a failed step are
both possible and both leave a machine in exactly the state the old note
described.

## sowa-guix-setup

It performs the state initialization needed after unpacking upstream Guix,
without the systemd or GnuPG paths. It is safe to run again - anything already
in place is left alone - so it is also how a half-configured installation is
repaired, and it is what the package's `post-install` and `post-upgrade` hooks
run.

Installing or upgrading the package therefore runs it with no options, which is
the usual case. Run it by hand for the others, or after `--no-hooks`:

```sh
sowa-guix-setup                    # what the package does for you
sowa-guix-setup --no-authorize     # build everything locally, trust no substitutes
sowa-guix-setup --build-users 4    # fewer build users on a small machine
```

It creates:

- the `guixbuild` group and `guixbuilder01`..`guixbuilder10`, locked accounts
  with no home and `/usr/sbin/nologin` for a shell, at gid 980 and uids 981-990.

  The script also writes the group membership into `/etc/group` itself, on top
  of what `useradd -G` already did, and that is worth explaining. guix-daemon
  finds its build users by reading the *member list* of the group it was given -
  `getgrnam("guixbuild")->gr_mem` - not by looking for accounts whose primary
  group that is. shadow's `useradd` records that membership, so accounts this
  script creates are members already; what the extra step repairs is the ones an
  older Sowa created, back when its `useradd` dropped a supplementary group that
  matched the primary one. Those machines have ten
  build users and an empty member list, which the daemon reports as "all build
  users are currently in use". The list is merged rather than replaced, so an
  account added by hand stays a member.
- `/var/guix/db/db.sqlite` from the seed, if the machine has no database yet
- `/var/guix/gcroots/profiles`, the garbage collector root that makes what a
  profile refers to live
- `/var/guix/profiles/per-user/root/current-guix`, root's first generation, and
  `~root/.config/guix/current` pointing at it
- `/etc/guix/acl`, by running `guix archive --authorize` for the
  `bordeaux.guix.gnu.org` and `ci.guix.gnu.org` keys the package ships. This is
  what lets the daemon download pre-built binaries; without it every `guix
  install` builds from source, which on a machine like this means building a C
  compiler first. `--no-authorize` is the deliberate way to ask for that.

## The daemon

`/etc/rc.d/init.d/guix-daemon` has a `chkconfig` header of `-`, which is to say
it is off unless something turns it on, at start priority 70 - after the network
in every runlevel it is turned on for, since substitutes come over it.
Installing the package is what turns it on, through
`post-install|service-enable|guix-daemon`: a store with no daemon to build into
it is a package that does not work, and there is nothing for the daemon to do on
a machine where nobody uses Guix.

That decision is made on the *first* install and never again. An upgrade only
restarts the daemon, and only if it was running, so `chkconfig guix-daemon off`
on a machine that has changed its mind is not quietly undone the next time the
package is bumped.

```sh
service guix-daemon start
service guix-daemon status
tail -f /var/log/guix-daemon.log
```

It runs, as upstream's init script does:

```sh
guix-daemon --build-users-group=guixbuild --discover=no \
    --substitute-urls='https://bordeaux.guix.gnu.org https://ci.guix.gnu.org'
```

Builds run as the `guixbuild` accounts, in a chroot, in mount, IPC, UTS, PID and
network namespaces of their own; that isolation is the whole reason a store path
can be said to name its contents. The kernel fragment asks for all five by name,
and adds `CONFIG_USER_NS`, which x86_64 defconfig leaves off: the daemon itself
does not need it - it runs as root and drops to the build users - but `guix
shell --container`, relocatable `guix pack` output, and any unprivileged use of
the store do.

`--discover=no` keeps the daemon off the local network: substitutes come from
the servers named above, and discovering peers on a LAN is a decision for
whoever owns the LAN.

Two Sowa-specific details are worth knowing:

- The service is identified by the program behind `/proc/PID/exe`, and every
  path in a Guix profile is a symbolic link into the store, so the init script
  resolves `current-guix/bin/guix-daemon` to its store path once and uses that
  for start, stop and status alike. A consequence is that **`guix pull` should
  be followed by `service guix-daemon restart`**: the running daemon is the one
  from the generation it was started in.
- The daemon is kept in the foreground and its output is appended to
  `/var/log/guix-daemon.log`: a build daemon's output is build logs, which are
  its own to keep rather than something to put through syslog.

## Locales

Guix's binaries carry their own C library, which looks for locales in the store
rather than in `/usr/lib`, and Sowa's own locale data is not it. Until a
profile provides them, `guix` reports `failed to install locale` and falls back
to C:

```sh
guix install glibc-locales
```

`/etc/profile.d/guix.sh` then points `GUIX_LOCPATH` at
`~/.guix-profile/lib/locale`, and the init script does the same for the daemon
if root's profile has them.

## Upgrading

There are two upgrade paths, and only one of them is the one to use:

- **`guix pull`** is how Guix updates itself, and it is the answer. It fetches a
  newer Guix into a new generation of root's own profile and registers
  everything it builds in the store database as it goes. Sowa's pin has nothing
  to do with it, and the packaged version is only where the machine started.
  Restart the daemon afterwards.
- **`sowa-pkg upgrade`**, when Sowa bumps its pinned tarball, replaces the
  store the *package* owns: the new items are unpacked and the superseded ones
  are removed. The package's `post-upgrade` hooks run `sowa-guix-setup` and
  restart the daemon, since the one that is running is the one from the
  generation it was started from. Be aware of what neither of them can do,
  though: the new store items are on disk but are not registered in this
  machine's database, because that database is the machine's own state and the
  package will not overwrite it. Guix will refuse to use a path it does not
  consider valid.

  So on a machine that has already been set up, treat a pinned-version bump as a
  reinstallation rather than an upgrade:

  ```sh
  service guix-daemon stop
  sowa-pkg upgrade --no-hooks guix        # the state has to go before setup runs
  rm -rf /var/guix /root/.config/guix     # the state, deliberately not packaged
  sowa-guix-setup
  service guix-daemon start
  ```

  `--no-hooks` is there because the order matters: the package's own steps would
  run `sowa-guix-setup` against the old state, which it would find already in
  place and leave alone, before the `rm -rf` takes it away.

  That discards the record of what Guix had installed on this machine, which is
  why `guix pull` is the path to prefer once the machine is running. If the
  profile is all that broke - `guix: command not found`, or a dangling
  `current-guix` - `sowa-guix-setup` on its own re-seeds it and says so.

## Why Guix needs /etc/services

Nothing else in the image resolves a *service name*. `getaddrinfo(3)` will take
one where a port number would do, and looks it up through NSS `services`, which
is `files`, which is `/etc/services`; curl, Wget and OpenSSH all name a numeric
port and never ask. Guile does: `open-socket-for-uri` hands `getaddrinfo` the
URI **scheme** whenever the URI carries no explicit port, so
`https://bordeaux.guix.gnu.org` is resolved as host `bordeaux.guix.gnu.org`,
service `"https"`.

On an image without that file every Guix download fails identically, before a
packet is sent:

```text
Starting download of /gnu/store/...-hello-2.12.2.tar.gz
From https://ftpmirror.gnu.org/gnu/hello/hello-2.12.2.tar.gz...
In procedure getaddrinfo: Servname not supported for ai_socktype
```

and because the substitute servers are unreachable for the same reason, Guix
falls back to building from source - so the first visible symptom is a machine
compiling the bootstrap chain rather than a name-resolution error. Sowa ships
the file as the `netbase` package for this reason.

The build chroot needs it too, and gets it: `guix-daemon` copies exactly
`/etc/hosts`, `/etc/nsswitch.conf`, `/etc/resolv.conf` and `/etc/services` into
the chroot for fixed-output derivations, so the host having them is the whole
requirement.

`guix gc` is what reclaims the store, including items the Sowa package
installed. That is not a conflict: the package's manifest records what it put
there, and `sowa-pkg verify` will report the collected paths as missing, which
is exactly what they are. `sowa-pkg install --reinstall guix` puts them back.

## Removing it

```sh
sowa-pkg remove guix
rm -rf /var/guix /etc/guix /root/.config/guix
```

The first two of the four commands this used to take are the package's
`pre-remove` hooks, and they run before a single file is deleted: the daemon
runs *out of* the store the removal is about to take away, and a daemon whose
program has been unlinked goes on running from the inode it opened, holding the
build users and its socket. Stopping it afterwards would be too late for
`/sbin/chkconfig`, too - the rc links it removes are made from a header it reads
out of the init script the same removal deletes.

The last line is the state the package deliberately never owned, and removing it
is the one part that still has to be asked for by hand.
