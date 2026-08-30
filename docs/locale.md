# Locales on Sowa

glibc installs about 17 MB of locale definitions under `/usr/share/i18n` and
15 MB of character-set converters under `/usr/lib64/gconv`, and none of it
means anything until a locale has been *compiled*. Before `make locales`
existed the image compiled none, which is not a missing feature so much as a
system that is quietly wrong about text: `setlocale(3)` can only succeed for
`C` and `POSIX`, both of which are ASCII, so `ls` quotes every file name
outside it, `sort` collates by byte, and mandoc falls back to `-Tascii` — its
own configure says so in as many words, in
[packages/mandoc.sh](../scripts/stages/packages/mandoc.sh).

`make locales` compiles the set in [config/locales.conf](../config/locales.conf)
into `/usr/lib/locale/locale-archive`, ships glibc's whole catalogue as
`/etc/locale.gen`, and installs `locale-gen(8)` so the rest can be compiled on
a running machine.

| File | What it is |
| --- | --- |
| `/usr/lib/locale/locale-archive` | The compiled locales. This is what programs read. |
| `/etc/locale.gen` | Which locales this machine compiles, and the catalogue of every one it could — glibc's own `SUPPORTED` list, all but the enabled ones commented out. |
| `/etc/locale.conf` | The locale a login shell starts in. |
| `/etc/profile.d/locale.sh` | What exports it, since glibc reads no configuration file of its own. |
| `/usr/sbin/locale-gen` | Compiles the archive from `/etc/locale.gen`. |

The image ships `C.UTF-8` and `en_US.UTF-8`, and `/etc/locale.conf` sets
`LANG=C.UTF-8`. `C.UTF-8` is the C locale with the character set corrected, so
the image is right about text without deciding anybody's language.

## What it costs

Compiled locales share their character tables and pay separately for collation
and formats, so the first one is expensive and the rest are not:

| Set | Archive |
| --- | --- |
| `C.UTF-8` | 392 KB |
| `C.UTF-8` and `en_US.UTF-8` (shipped) | 2.9 MB |
| Sixteen locales covering most of the world's speakers | 17 MB |
| All 328 UTF-8 locales glibc supports | ~200 MB |

Adding one to `config/locales.conf` puts it in the image. Adding one on a
running machine costs nothing that is not already installed, because the
definitions, the character maps and `localedef` all ship:

```sh
locale-gen pl_PL.UTF-8
```

That is the reason the 17 MB of definitions are worth carrying: an offline
machine, with no repository configured and no network, can still be made to
speak the language of whoever is running it.

## Cross-compiling a locale archive

A locale archive is not portable. Its contents are laid out for one word size
and one byte order and its format belongs to the C library that reads it, so it
has to be written by the *target's* `localedef`. The usual answers are all bad
ones: run the build host's `localedef` and let a foreign glibc decide what this
image's locales look like; build a second, native glibc just to get a
`localedef`; or put `qemu-user` in the middle.

None is necessary here. The target is x86_64 and
[host-check.sh](../scripts/host-check.sh) refuses a host that is not, so the
`localedef` this build already produced is a program the build machine can
execute — provided it is not handed to the host's loader. Stage
[packages/locales.sh](../scripts/stages/packages/locales.sh) invokes it through
the sysroot's own `ld-linux` with the sysroot's libraries:

```sh
"${SYSROOT}/lib64/ld-linux-x86-64.so.2" \
    --library-path "${SYSROOT}/usr/lib64:${SYSROOT}/lib64" \
    "${SYSROOT}/usr/bin/localedef" ...
```

so the program that writes the archive is the pinned glibc's, exactly as it
will be on the target, and no part of the host's C library takes part. The
stage checks `localedef --version` against the pinned glibc version before it
compiles anything; that check is also what turns "a build host whose kernel is
older than `GLIBC_MIN_KERNEL`" into a message rather than a puzzle.

`I18NPATH` and `GCONV_PATH` are pointed into the sysroot for the same reason —
`--prefix` governs only what `localedef` writes, not what it reads.

## Changing the set the image ships

[config/locales.conf](../config/locales.conf) is the list, one `<name>
<charset>` per line, named as glibc's `localedata/SUPPORTED` names them. The
stage checks every entry against that catalogue, so a typo fails the build
rather than producing an image that quietly has no such locale, and it checks
that `/etc/locale.conf`'s `LANG` is one of the compiled ones — an image whose
default locale does not exist would open every command with a `setlocale`
warning.

`make locales` alone rebuilds it; `config/locales.conf` and `src/locales` are
inputs to the stamp, so an edit to either redoes the stage on the next build.

## On a running machine

`/etc/locale.gen` and `/etc/locale.conf` are under `/etc` and therefore
configuration: `sowa-pkg` keeps a locally modified copy across an upgrade. The
archive is not — it is a file the package carries — so
[config/hooks/locales.hooks](../config/hooks/locales.hooks) runs `locale-gen`
after an install or an upgrade. Without it, upgrading the package would replace
the machine's own archive with the shipped one and silently take away every
locale that had been added since.

The archive is rebuilt from nothing on each run rather than added to, so
commenting a line out of `/etc/locale.gen` and running `locale-gen` removes
that locale. It is written to a temporary file on the same filesystem and
renamed into place, so a run that fails part way through leaves the locales
that were working still working.

## Two things worth knowing

`sowa-setup` copies the live system as it stands, so a locale generated and
selected on the live medium before installing is the locale the installed
system boots with — there is no separate step for it in the installer.

Services started at boot run in the C locale. Nothing sets `LANG` before
`/etc/rc.d/rc` does its work — `/etc/profile.d/locale.sh` runs for login shells
and a daemon is not one — and `service` defaults it to `C` explicitly. That is
deliberate: a daemon's log timestamps and the output its init script parses
should not change because somebody changed the system's language. A service
that wants a locale sets it in its own init script.

## What is not here

The console keyboard is US and nothing in the image changes it: `loadkeys`,
`setfont` and the keymaps come from `kbd`, which Sowa does not build. It does
not arise over SSH, where the layout is the client's; on the local console a
non-US layout needs `kbd` added as a package.

Message translation is mostly moot: the image is built without gettext where
that was a choice — [packages/git.sh](../scripts/stages/packages/git.sh) sets
`NO_GETTEXT` in as many words — so `LC_MESSAGES` selects between message
catalogues that are not there, and programs speak English. What the locales do
decide is character handling, collation, and the formats for dates, numbers and
currency, which is the part that makes a system usable rather than merely
readable.

See also [/root/sowa-howto/locale.txt](../rootfs-overlay/root/sowa-howto/locale.txt)
for the same ground from the point of view of somebody logged in, and
`locale-gen(8)`, `locale.conf(5)` and `locale.gen(5)` on the machine itself.
