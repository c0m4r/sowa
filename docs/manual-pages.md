# Manual pages

Sowa uses mandoc to read manual pages under `/usr/share/man`. The commands
`man`, `apropos`, `whatis`, and `makewhatis` are provided by the same toolset,
with GNU less as the default pager.

```sh
man wg
man 5 crontab
man -w openvpn
mandoc ./command.1
```

Sowa's own administrative programs include reference pages, among them
`sowa-pkg(8)`, `sowa-pkg.conf(5)`, `sowa-setup(8)`, `sowa-bootstrap(8)`,
`sowa-chroot(8)`, `init(8)`, `inittab(5)`, `service(8)`, and `chkconfig(8)`.
The rootfs stage rejects an overlay-installed command without its required page.

## Search index

The image does not ship a `mandoc.db`, because installing or removing packages
would immediately make it incomplete. `man name` works without the database by
walking the manual tree, but `apropos` and `whatis` need an index:

```sh
makewhatis /usr/share/man
apropos tunnel
whatis wg
```

Rebuild it after changing the installed package set.

## Rendering and paging

mandoc formats `mdoc(7)` and `man(7)` sources directly. It emits UTF-8 when the
`C.UTF-8` locale is available and falls back to ASCII otherwise. GNU less
interprets the overstriking used for bold and underline. Set `MANPAGER` or
`PAGER` to select a different pager.

The matching Bash completions live below
`/usr/share/bash-completion/completions` and derive candidates from the running
machine where appropriate. For example, package completion reads the verified
repository index and service completion reads installed init scripts.

Short task-oriented guides are installed under `/root/sowa-howto/`; manual
pages remain the command reference. See [Locales](locale.md) if UTF-8 rendering
is unavailable.
