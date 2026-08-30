# Accounts

Sowa packages the upstream **shadow** account suite. `useradd`, `usermod`,
`userdel`, `groupadd`,
`groupmod`, `groupdel`, `passwd`, `chage`, `gpasswd`, `newgrp`, `su`, `login`
and the rest are all from shadow 4.20.2, packaged as `shadow`.

```sh
useradd -m -s /bin/bash alice     # create an account with a home directory
passwd alice                      # give it a password
usermod -aG wheel alice           # add it to a group
groupadd project                  # and groups of its own
userdel -r alice                  # take it all away again
```

`wheel` is Sowa's administrative group: its members may use `sudo` after
entering their own password. The shipped `/etc/sudoers` contains only the
standard root rule, the enabled wheel rule, and an `@includedir
/etc/sudoers.d` for additional root-owned policy snippets. Use `visudo` to
edit the policy; it checks the syntax before installing a change.

## What this replaced

A base that could create an account and set a password, and no more: there was
no `usermod`, no `userdel`, no `groupmod`, no `gpasswd`, no way to move an
existing account between groups or to remove one. shadow is the whole layer,
installed under `/usr` like every other package, and `make rootfs` refuses to
assemble an image that is missing any of it.

`login` is the one that matters most, because it is what every getty in the
inittab runs:

```text
1:12345:respawn:@/usr/sbin/agetty --noclear -l /usr/bin/login tty1 38400 linux
```

That used to be `/bin/login`, the applet, started directly by init on
`/dev/console`. It is shadow's now, which is what makes password aging,
`/etc/login.defs`, and the `su`/`login` pair behave the way they are documented
to everywhere else. It is also why every getty names it with `-l`, whether on
the inittab line or inside `serial-getty`: agetty would otherwise look for
`/bin/login`, which this image does not have.

## Four deliberate settings

Everything else in `/etc/login.defs` is upstream's. Four lines are not, and each
is there because of something Sowa does not have:

- **`ENCRYPT_METHOD YESCRYPT`**. Upstream ships this commented out, and what
  shadow falls back to then is DES: 56 bits, and only the first eight characters
  of the password are significant. libxcrypt is built here with yescrypt as its
  gensalt default, so that is what `passwd` is told to write. The `$6$` SHA-512
  hashes an older Sowa wrote still verify - this decides what new passwords look
  like, not what can be read.
- **`MAIL_DIR` commented out**, and `CREATE_MAIL_SPOOL=no` in
  `/etc/default/useradd`. There is no mail transfer agent in the base system and
  no mail spool, so a mailbox per account would be a file nothing writes and
  nothing reads; with the setting left alone, `useradd` reports that it could not
  create one. Install an MTA, create its spool directory, put both settings back.
- **`MAIL_CHECK_ENAB no`**, for the same reason: without it every login greets
  you with "No mail."
- **`CONSOLE` commented out**. It names the file listing the terminals root may
  log in on, `/etc/securetty`, and shadow reads a missing file as "all of
  them" - which is what Sowa had been relying on without saying so, since it
  ships no such file. The line is gone rather than the file invented, because
  an incomplete list is not a warning but root being refused at the terminal
  someone is standing at, and the inittab now runs a getty on every console an
  installed machine might put its login on. To reverse it: ship a
  `/etc/securetty` naming every one of those devices, and put the line back in
  [scripts/stages/packages/shadow.sh](../scripts/stages/packages/shadow.sh).

## The root account

Root has an empty password, and `/etc/shadow` says so with an empty hash field.
The third field - the day the password was last changed - is also empty, which
means password aging is off. A zero there would mean something quite different:
"change this password at the next login", which shadow's `login` enforces by
running `passwd` before it gives you a shell. That is worth knowing because it
is what an early build of this got wrong, and the symptom was a machine that
showed a login prompt and refused every login.

Setting a root password is `passwd`, and it changes nothing else: SSH still
refuses password authentication until `PermitRootLogin yes` is set as well - see
[ssh.md](ssh.md).

## Where the tools live

`login`, `su`, `passwd`, `chage`, `chfn`, `chsh`, `gpasswd`, `newgrp` and the
subordinate-id helpers are in `/usr/bin`; `useradd`, `usermod`, `userdel`,
`groupadd`, `groupmod`, `groupdel`, `pwck`, `grpck`, `vipw` and `vigr` are in
`/usr/sbin`. `passwd` and `su` are setuid root, `login` is not - init starts it
as root and it drops privilege itself.

Two programs shadow builds are deliberately not installed: `groups`, because
coreutils already provides it, and `nologin`, because util-linux does and
`/etc/passwd` points the `sshd` and `nobody` accounts at that one.

## What is still missing

There is no PAM. shadow is built `--without-libpam` and authenticates against
`/etc/shadow` through `crypt(3)`, which is what libxcrypt is in the image for.
That means no pam_limits, no pam_faillock, and no per-service authentication
policy: `/etc/login.defs`, `/etc/limits` and `/etc/login.access` are the whole of
it. There is also no `lastlog` - shadow dropped it, and util-linux's replacement
needs the liblastlog2 the util-linux stage disables.
