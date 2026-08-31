# sowa-init

Sowa's PID 1 is `sowa-init`, a System V style init written for this
distribution. It lives in [src/init](../src/init), is built by
`scripts/stages/packages/init.sh` into the `sowa-init` package, and installs:

| Path | What it is |
| --- | --- |
| `/sbin/init` | PID 1. Run as anything else, it forwards a runlevel request, the way System V's did |
| `/sbin/telinit` | change the runlevel, or reread the inittab |
| `/sbin/shutdown` | bring the system down at a stated time, with a warning and a cancel |
| `/sbin/halt`, `/sbin/poweroff`, `/sbin/reboot` | one binary under three names |
| `/sbin/runlevel` | the previous and current runlevel |
| `/sbin/service` | run an init script with a boot-like environment |
| `/sbin/chkconfig` | decide which runlevels start a service |
| `/etc/rc.d/rc` | the runlevel driver init runs |
| `/etc/rc.d/init.d/functions` | the shell library every init script sources |
| `/usr/share/man/man8/*.8`, `man5/inittab.5` | a manual page per command, and one for the file that configures all of them |
| `/usr/share/bash-completion/completions/*` | Tab completion for the commands anyone types by hand |

The pages are in [src/init/man](../src/init/man) and are `mdoc(7)`, which is
what mandoc - the image's `man` - parses natively. `poweroff.8` and `reboot.8`
are symlinks to `halt.8`, because they are one program. The completions are in
[src/init/completions](../src/init/completions) and answer from the machine
rather than from a list: the services are what is in `/etc/rc.d/init.d`, and
the actions a service takes are read out of that script's own usage line, so a
script that grows a `reload` is offered one without anything else changing.
`init` is a symlink to the `telinit` completion and `poweroff` and `reboot` are
symlinks to `halt`'s, since the loader looks for a file named after the command
that was typed. Sowa's `chkconfig` completion deliberately replaces the generic
one shipped by bash-completion, which describes a different implementation;
the loader reads `completions/` before its own `completions-core/`, which is what
makes ours the one that answers.

The policy those programs act on is the distribution's, and ships in the root
filesystem overlay as part of `sowa-release`: `/etc/inittab`,
`/etc/rc.d/rc.sysinit`, the init scripts in `/etc/rc.d/init.d`, and the
`/etc/rc.d/rc<N>.d` symlink farms. `/etc/init.d` is a symlink to
`/etc/rc.d/init.d`, because that is the path everyone types.

## Booting

1. `/sbin/init` is started - by `liveinit` on the live medium, which has
   already mounted the root filesystem and `switch_root`ed into it (see
   [iso.md](iso.md)), or by the kernel itself on a disk, where there is no
   initramfs at all. The recovery image is the third case: the kernel runs
   `/init`, a symlink to `sbin/init`, straight out of a cpio of the whole tree.
   Words on the kernel command line that init recognises - `single`, `S`,
   `1` … `5`, `emergency` - choose where it goes, and `liveinit` passes through
   the ones it does not claim itself.
2. init sets up its signal handling, creates `/run/initctl`, reads
   `/etc/inittab`, and runs the `sysinit` entry: `/etc/rc.d/rc.sysinit`. It
   waits for it.
3. `rc.sysinit` restores `/tmp` with its sticky `1777` mode, mounts `/proc`,
   `/sys`, the unified cgroup hierarchy on
   `/sys/fs/cgroup`, `/dev`, `/dev/pts`, `/dev/shm` and a
   tmpfs on `/run` - each only if it is not already mounted, which on the live
   medium most of them are, because `liveinit` moved them into the new root -
   makes the `/dev/fd` symlinks, mounts what `/etc/fstab`
   asks for, sets the hostname and brings the loopback interface up. Its last
   act on `/run` is `kill -USR1 1`, which asks init for a new control FIFO on
   the tmpfs that now covers the one it made in step 2. It also runs
   `swapon -a`, since `mount -a` walks past a `swap` line in `/etc/fstab`
   without doing anything with it.
4. The `bootwait` entry runs `/etc/rc.d/rc.setup`. It normally exits at once;
   when the ISO's Install entry supplied `sowa.setup=y`, it runs the interactive
   `sowa-setup` installer and waits for it. Returning from setup continues this
   boot normally.
5. init enters the default runlevel from `initdefault`, which is 3.
6. The runlevel entry `l3:3:wait:/etc/rc.d/rc 3` runs the K and S links in
   `/etc/rc.d/rc3.d`: zram, then the network, then chronyd, then sshd, then
   crond. zram is first because swap that appears after the memory ran out was
   not there when it mattered, and is stopped last for the mirror image of the
   same reason.
7. The getty entries start a login prompt on `tty1`, `tty2` and `ttyS0`, each
   on its own device, and init keeps them alive for the rest of the runlevel.

## The inittab

```
id:runlevels:action:process
```

* **id** - up to eight characters, unique in the file. init matches entries by
  id across a reread, so a stable id matters more than a meaningful one.
* **runlevels** - the runlevels the entry belongs to, with no separator
  (`12345`). Empty means every runlevel, which is what makes `sysinit`,
  `ctrlaltdel` and `powerfail` entries independent of one.
* **action** - see below.
* **process** - the command. init runs it directly, unless it contains one of
  ``~`!$^&*()=|\{}[];"'<>?`` in which case `/bin/sh -c` runs it. That is what
  lets an inittab line carry a redirection or a quoted argument. A leading `@`
  is not part of the command: it is the entry asking init for no terminal at
  all - see below.

| Action | When it runs |
| --- | --- |
| `initdefault` | not a command: the runlevel to enter when none was asked for |
| `sysinit` | once at boot, before any runlevel; init waits for it |
| `boot` | once at boot, after sysinit, without waiting |
| `bootwait` | once at boot, after sysinit, waited for |
| `wait` | on entering a matching runlevel; init waits for it before going on |
| `once` | on entering a matching runlevel, without waiting |
| `respawn` | whenever it is not running and the runlevel matches |
| `ondemand` | only when `telinit a`, `b` or `c` names it; the runlevel does not change |
| `off` | never; a line kept for later |
| `ctrlaltdel` | on SIGINT, which is what the kernel sends for Ctrl-Alt-Del |
| `powerfail`, `powerwait` | on SIGPWR, or an `INIT_CMD_POWERFAIL` request |
| `powerokwait` | on an `INIT_CMD_POWEROK` request |
| `kbrequest` | on SIGWINCH, the kernel's KeyboardSignal |

Every process init starts gets a session of its own, `/dev/console` as its
standard input, output and error, and `RUNLEVEL`, `PREVLEVEL`, `PATH`, `HOME`,
`CONSOLE` and `INIT_VERSION` in its environment. Only `respawn` and `ondemand`
entries claim the console as their **controlling** terminal: the single-user
shell needs one for job control and Ctrl-C, and an rc script taking it instead
would leave that shell without one.

An entry whose process begins with `@` opts out of all of that terminal
handling. It gets `/dev/null` on its three standard descriptors and no
controlling terminal - only the session of its own, which every entry gets.
That is what a getty needs: `agetty` is told which device it serves, opens it
itself, and makes it the controlling terminal of the session it hands to
`login`, which it could not do from a session already holding `/dev/console`.
Everything else in the file wants the console, so the marker is on the gettys
rather than on everything else:

```text
1:12345:respawn:@/usr/sbin/agetty --noclear -l /usr/bin/login tty1 38400 linux
```

The environment is unchanged by it, `@` and the command may be separated by
spaces, and a `telinit q` that only adds or removes the marker counts as a
changed entry, so the process is restarted with the terminal it now asks for.

## The login prompts

```text
1:12345:respawn:@/usr/sbin/agetty --noclear -l /usr/bin/login tty1 38400 linux
2:12345:respawn:@/usr/sbin/agetty -l /usr/bin/login tty2 38400 linux
s0:12345:respawn:@/usr/sbin/serial-getty ttyS0 115200
```

One getty per console rather than one `login` on `/dev/console`, which is what
the inittab had until every `console=` argument on the kernel command line was
load-bearing: the last one named `/dev/console`, `/dev/console` was the only
terminal with a prompt, and a machine told to use a serial port it did not have
printed its kernel log to the screen and then looked hung. Now the screen and
the serial line both have a prompt on the same boot.

`-l /usr/bin/login` is not optional. agetty's compiled-in default is
`/bin/login`, and the image deliberately has no such program - `/bin` holds
`bash`, `bashbug`, `sh` and `vi` and nothing else, so `login` resolves to
shadow's under `/usr`. A getty that does not name it shows a prompt no one can
log in on, which is why the rootfs stage checks for it.

`--noclear` keeps the kernel log on `tty1` instead of wiping the screen before
the prompt: on a boot that went wrong it is the first thing to read.

The serial line goes through
[`/usr/sbin/serial-getty`](../rootfs-overlay/usr/sbin/serial-getty) because it
is the one console that may not exist. `serial8250` registers `ttyS0` through
`ttyS3` for the legacy addresses whether or not a chip answers, so agetty opens
the device, blocks writing the prompt, gives up ten seconds later and exits -
and init respawns it, ten times in two minutes, which is the throttle above.
The entry is then disabled for five minutes and does it again for the life of
the machine, while init's complaint goes to `/dev/console`, which on such a
machine is that same absent port. `serial-getty` reads
`/proc/tty/driver/serial`, where the kernel reports `uart:16550A` for a port
with hardware behind it and `uart:unknown` for one without, and waits rather
than exits when there is nothing there. `/sys/class/tty/console/active` cannot
answer this: it lists `ttyS0` on both kinds of machine, because registering a
console does not probe for the chip.

Runlevel 1 has the gettys as well, since it is the runlevel that stops the
services and leaves a login prompt. Runlevel S does not: `su:S:respawn:/bin/sh
-l` is a console shell, so it is the one interactive entry that still takes
`/dev/console` and its controlling terminal.

A `respawn` entry that starts ten times in two minutes is not working. init
says so and stops trying for five minutes, then starts again from scratch.

After editing the file, `telinit q` rereads it. Entries that already ran in the
current runlevel are not run again; entries whose command changed are stopped
so they start with the new one; entries that are gone are stopped for good.

## Runlevels

| Runlevel | What it means here |
| --- | --- |
| 0 | halt or power off |
| 1 | single user with the rc scripts run: services stopped, console login |
| 2 | multi user |
| 3 | multi user, the default |
| 4, 5 | multi user, free for local use; nothing here manages a display |
| 6 | reboot |
| S | single user without the rc scripts: a root shell on the console. `single` on the kernel command line |

`runlevel` prints the previous and current one, `telinit N` changes it, and
`init N` does the same when init is not PID 1.

Runlevel S is deliberately not runlevel 1. S is what a machine boots into to be
repaired: rc.sysinit has run, so everything is mounted, and nothing else has.
Runlevel 1 runs `/etc/rc.d/rc 1`, which stops the services that were running,
and leaves a login prompt.

## Services

An init script is an ordinary shell script in `/etc/rc.d/init.d` that takes
`start`, `stop`, `restart` and `status`, sources
`/etc/rc.d/init.d/functions`, and carries a header:

```sh
# chkconfig: 2345 50 50
# description: OpenSSH server
```

The three fields are the runlevels the service belongs in (`-` for none) and
its two-digit start and stop priorities. `chkconfig` reads them to make the
links:

```sh
chkconfig --list             # what starts where
chkconfig network off        # K links everywhere; the network stays down
chkconfig --level 35 nfs on  # only those two runlevels
chkconfig sshd off           # K links everywhere
service sshd restart         # run the script with a boot-like environment
service --status-all
```

`/etc/rc.d/rc <N>` runs the `K*` links in `/etc/rc.d/rc<N>.d` and then the
`S*` links, in name order. Whether a service is already running is a lock file
in `/run/lock/subsys`, the System V convention: `daemon()` creates one,
`killproc()` removes it, and `rc` skips a K link with no lock and an S link
that has one. Entering a runlevel twice therefore starts nothing twice.

`functions` starts services **in the foreground under `setsid`**, with their
output appended to a log file in `/var/log`, and records the pid. A daemon that
puts itself in the background takes its diagnostics with it — including the ones
it produces before it is far enough along to log anywhere — so keeping it in the
foreground is what keeps them. This is separate from syslog: syslog-ng collects
what programs send to `/dev/log`, while this collects what a service writes on
its own descriptors, which is where the reason it would not start is. A service
that daemonises anyway is still handled: the pid is found again by looking
through `/proc` for the program.

Nothing in `functions` sleeps for a fixed length of time to let a process appear
or go. `daemon()` waits for `setsid` to have exec'd the service and then watches
it for a tenth of a second - long enough for a daemon that cannot parse its
configuration to have exited and said so, which is the whole point of watching -
and `killproc()` polls for the process to go rather than checking once every
half second. Both poll at 20ms, which is `poll_interval` at the top of the file.

This is worth stating because the alternative was measured. `daemon()` used to
sleep a flat `0.5` and `killproc()` used to notice an exit only at half-second
boundaries, so each of the three daemons cost half a second to start and another
half to stop whatever it actually did - a second and a half at each end of the
machine's life, spent on nothing. `chronyd`, `sshd` and `crond` now start in
0.24, 0.42 and 0.15 seconds and stop in about 0.03 each.

Which program, not which name. An init script is named after the service it
manages and the kernel names a process after the script it is running, so
`/etc/rc.d/init.d/sshd` and every subshell it forks is called `sshd` too;
sshd rewrites its own argv on top of that. `/proc/PID/exe` is what these
helpers compare, and a pid file is only believed when the process it names is
running the right program.

This is the one place where the old inittab did something this one does not: a
service is no longer respawned when it dies. That is System V's bargain, and
`service <name> start` or a `respawn` line in the inittab both get it back.

## What the boot spent its time on

Every action an init script announces is timed, and `sowa-boottime` prints the
result. There is nothing to turn on: `begin()` notes the time, `ok()`, `failed()`
and `skipped()` file a record, `/etc/rc.d/rc` files one for a whole runlevel
pass, and `rc.sysinit` files one for the mounting that happens before any
runlevel.

```
# sowa-boottime
Boot 222e8b0a, kernel 6.18.44, up 12s

        at      took  how     service      what
      1.01      0.20  ok      rc.sysinit   Mounting and setting up
      1.21      0.23  ok      zram         Starting zram
      1.45      3.21  ok      network      Configuring the network
      4.67      0.24  ok      chronyd      Starting chronyd
      4.91      0.42  ok      sshd         Starting sshd
      5.33      0.15  ok      crond        Starting crond

  6 actions, 4.45s of them spent working, last one done at 5.48s
  Runlevel 3 took 4.27s, starting at 1.21s
```

That is a live medium in QEMU, captured before nic 0.1.6, and it shows what the
boot used to wait for: the network, at three and a fifth seconds against a
quarter of a second for everything else in the runlevel put together. Almost
none of that was the DHCP lease - a configuration that brought the link up and
asked for no lease at all took the same three seconds - it was `nic`'s wait for
IPv6 duplicate address detection, which ran unconditionally and gave up after
three seconds regardless of whether anything was actually worth waiting for.
Fixed upstream in nic 0.1.6: the wait now only runs when a DHCPv6 lease was
optional and failed to resolve, and is capped at a second and a half, so a
clean lease or a configuration with no lease at all now costs nothing here. See
the comment at the top of `/etc/rc.d/init.d/network`.

The clock is `/proc/uptime`, deliberately. A wall clock would be useless here:
`chronyd` starts in the middle of the boot being measured and may step the clock
by years, and a service that straddled the step would come out having taken less
than no time. Two decimals is what `/proc/uptime` offers, so it is what every
number here has.

Records go to two files:

| Path | What it holds |
| --- | --- |
| `/run/sowa/timing` | This boot. `/run` is the tmpfs `rc.sysinit` mounts, so it cannot outlive the boot it describes |
| `/var/log/service-timing.log` | Every boot on record. The one with the shutdowns in it, since a shutdown's records are written seconds before `/run` stops existing |

Each line is `<boot> <at> <took> <outcome> <service> <label...>`, where `<boot>`
is the first field of `/proc/sys/kernel/random/boot_id` - what tells one boot's
records from the next. Nothing rotates the log; it grows by about a hundred bytes
per boot, the same bargain `/var/log/wtmp` is already on in this image.

Three other views:

```sh
sowa-boottime --history      # one line per boot: startup, shutdown, failures
sowa-boottime --slowest 5    # the worst actions on record, any boot
sowa-boottime --boot c477f014
```

`--history` is the one to reach for when a boot has got slower, because it puts
the same two numbers for every boot in a column. `--slowest` then says which
action to blame.

What is measured is what the init script did, not what the daemon it started went
on to do. `chronyd` is recorded at a quarter of a second because that is what
starting it costs; stepping the clock to match a server happens afterwards and is
not in the table.

## Shutdown

`shutdown -r now`, `reboot`, `poweroff` and `halt` all end in the same place:
a request for runlevel 6 or 0.

```
shutdown -r +5 "rebooting for a kernel upgrade"   # warns, then reboots
shutdown -c                                       # cancels a waiting one
telinit 0                                         # the same thing, unannounced
reboot -f                                         # no rc scripts at all
```

`shutdown` waits out the delay in the foreground, announcing on the console as
the time approaches, and leaves its pid in `/run/shutdown.pid` so `-c` can find
it. `halt`, `poweroff` and `reboot` are one binary that runs `shutdown` for you
unless the system is already in runlevel 0 or 6, or `-f` says not to.

What init does once the runlevel 0 or 6 scripts have stopped the services:

1. `SIGTERM` to every process, then `SIGKILL` three seconds later
   (`shutdown -t SECONDS` changes that). The wait ends early the moment init has
   no children left, so the three seconds are a limit rather than a cost - but
   they are spent in full whenever something ignores `SIGTERM`, and an
   interactive shell does. Shutting the machine down from a console login is
   therefore the case where this is paid, and since the rc scripts have already
   stopped every service properly by this point, it is the login shell rather
   than a daemon that the grace is being given to. It is now the largest part of
   a Sowa shutdown: the services take about a fifth of a second between them and
   this takes three.
2. `sync`, then unmount everything that is not `/`, `/proc`, `/sys`, `/dev` or
   `/run`, lazily if it has to.
3. Remount `/` read-only, which is what leaves an on-disk filesystem clean, and
   call `reboot(2)`.

System V left this last phase to `/etc/init.d/halt` and `killall5`. Sowa's
init does it itself: it is the one process guaranteed to still be there, and
the one process the sweep cannot kill.

## The control channel

`/run/initctl` is a FIFO carrying System V's 384-byte `struct init_request`,
declared in [src/init/initreq.h](../src/init/initreq.h): the same magic number,
the same field order. `/dev/initctl` is a symlink to it, made by rc.sysinit.

One extension is Sowa's. A request for runlevel 0 may carry `halt` or
`poweroff` in its data area, because init performs the last phase of shutdown
itself and has to be told which of the two was meant. Empty means power off.

Signals init acts on:

| Signal | Effect |
| --- | --- |
| `SIGINT` | run the `ctrlaltdel` entries; the kernel sends this for Ctrl-Alt-Del |
| `SIGPWR` | run the `powerfail` entries |
| `SIGWINCH` | run the `kbrequest` entries |
| `SIGHUP` | reread the inittab, as `telinit q` does |
| `SIGUSR1` | create the control FIFO again, and rewrite the runlevel file |
| `SIGTERM` | logged and ignored; use `telinit` or `shutdown` |

## Where the runlevel is kept

`/run/initrunlevel`, as `<previous> <current>`, written by init.

System V kept it in the `RUN_LVL` record in utmp. glibc 2.42 removed the
functions that wrote utmp, so nothing on a Sowa system produces that record
and `runlevel` would have nothing to read. The file is the substitute; its
format is one line, and `runlevel`, `halt` and `chkconfig` are what read it.

The utmp files themselves do exist, and rc.sysinit is what creates them:
`/run/utmp` for this boot and `/var/log/wtmp` for the history. `login` records
a session in both - neither call creates the file it writes to, which is why
they have to be there - and `who` and `w` are what read them. init writes to
neither.

## Differences from System V init

Written down because they are decisions, not omissions:

* The last phase of shutdown belongs to init, not to a halt script and
  `killall5` (see above).
* The runlevel lives in a file rather than in utmp (see above).
* The `@` marker on a process is Sowa's. System V's init never took the
  console as a controlling terminal at all, so it needed no way to say "not
  this one"; this one does it for the single-user shell, which is what makes
  the marker necessary for the gettys. The `+` prefix System V does have is
  unrelated - it suppresses utmp accounting, which this init does not do - and
  is not recognised here.
* `telinit u` - re-execute init, keeping its state - is not implemented.
  Upgrading the `sowa-init` package replaces the binary; PID 1 keeps running
  the old one until the next boot.
* Runlevels `a`, `b` and `c` run `ondemand` entries but nothing tracks them
  beyond that.
* There is no `/etc/inittab` fallback prompt: with no usable inittab, init
  starts a respawning root shell on the console and says why.

## Building it

`make init` builds the package on its own; the rootfs stage refuses to
assemble an image without `/sbin/init`, the lifecycle commands, `/etc/rc.d/rc`
and a `/etc/inittab` that has an `initdefault`, a `sysinit` line, an entry per
runlevel and a getty on both `tty1` and `ttyS0`, each naming shadow's `login`. Editing anything under `src/init` invalidates the
stage, so `make image` rebuilds it.

The stage checks the documentation as well as the programs: that every command
has a page, that each page declares the name and section it is filed under -
mandoc finds a page by its directory and file name, so one whose `.Dt` says
something else is a page `apropos` files under another title - and that every
completion registers the command name it was installed as, which is the one
thing about a completion that can be wrong without anything failing.

The programs are C99 against glibc, dynamically linked like every other C
program in the image. Running `make` inside `src/init` builds them for the host
- useful for reading the warnings - and the build stage always runs
`make clean` first so a host binary can never reach an image.
