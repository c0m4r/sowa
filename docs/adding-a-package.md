# Adding a package

Every stage follows [packages/less.sh](../scripts/stages/packages/less.sh),
[packages/whois.sh](../scripts/stages/packages/whois.sh) or
[packages/plocate.sh](../scripts/stages/packages/plocate.sh) as the template —
for autotools, a bare Makefile, and meson respectively — and touches the same
nine places:

1. `config/sources.lock` — one row per tarball.
2. `config/upstreams.conf` — one row per locked source, with a release/changelog
   page and an automated check where upstream exposes a dependable feed. See
   [upstream-releases.md](upstream-releases.md).
3. `config/packages.conf` — one row, before the `linux`/`sowa-release` rows.
4. `config/licenses.conf` — one row, in the same position: the copyright holder
   (`upstream`, unless you wrote it), an SPDX expression, and where in the
   tarball each licence text lives. The stage installs them into
   `/usr/share/licenses/<name>/` on its own; nothing goes in the stage script
   for this. `make check` rejects a package with no row, and the build rejects a
   row naming a file the tarball does not have. See
   [licensing.md](licensing.md).
5. `scripts/stages/packages/<name>.sh`, mode 0755 — `prepare_source`,
   `reset_build_dir`, `pkg_stage`, `target_configure_env`, configure with
   `--build` **and** `--host`, `make DESTDIR="${pkgdir}" install`,
   self-verification, then `pkg_merge`. There is no number to choose and no
   list to insert it into: a stage is named by its path, `packages/<name>` is
   the name, and when it runs is decided by the function in the next item
   rather than by where the file sorts.
6. `scripts/build.sh` — a `<name>_package()` function, a call in `rootfs()`, a
   `case` arm, the usage string. The function calls what the package needs and
   then `run_rootfs_package_stage packages/<name> <name>`; the stage script is
   found from that name, so it is not passed as well.
7. **`scripts/build.sh` again** — append `"${STAMP_DIR}/packages/<name>.done"`
   to the invalidation list of *every library stage the package links*, so a
   rebuilt library immediately invalidates what links it. Consumer keys also
   include the recorded keys of dependencies from `packages.conf`; the trailing
   list remains an explicit reverse edge and an independently linted check of
   the graph. This used to fail silently, and did:
   an audit once found 21 missing entries across `zlib`, `libxcrypt`, `ncurses`,
   `bzip2`, `xz` and `openssl`. `scripts/lint.sh` now derives the same audit from
   the staged trees' `NEEDED` entries, so `make check` catches a forgotten one —
   but only on a tree that has been built, since it needs those trees to read.
8. `Makefile` — `.PHONY`, help comment, recipe.
9. `scripts/stages/image/10-rootfs.sh` — a presence assertion for each new
   binary. A command anyone would expect a Unix to have goes in the loop as
   well; `/usr/bin` and `/usr/sbin` have one each. Nothing may be installed into
   `/bin`, which holds exactly `bash`, `bashbug`, `sh` and `vi` and is asserted
   to.

## If it has a daemon

A package whose program is meant to keep running needs an init script, or it
can be installed and still not survive a reboot. Where the script comes from
depends on which half of the distribution the package is in.

For a package the **image** ships, the script goes in the root filesystem
overlay at `rootfs-overlay/etc/rc.d/init.d/<service>` — that is where `sshd`,
`crond`, `chronyd`, `network` and `zram` come from — and its runlevel links go
in `rootfs-overlay/etc/rc.d/rc<N>.d` beside it, if it is one the image starts.

For an **optional** package the overlay is not available: the package is not in
the image, and a path the image already carries is a conflict
`pkg_optional_manifest` refuses the package for. Its script is Sowa's own source
under `src/<name>/`, installed by the stage into the staging tree:

```sh
install -D -m 0755 "${PROJECT_ROOT}/src/nginx/nginx" \
    "${pkgdir}/etc/rc.d/init.d/nginx"
```

That makes `src/<name>` an input to the stage, so `scripts/build.sh` needs an
`invalidate_stale_<name>` beside `invalidate_stale_nginx` — without it an edited
script is not repackaged and the build says nothing.

Three rules are enforced rather than remembered:

- `pkg_check_services` runs for every package and holds each init script it
  ships to being executable, parsing, sourcing
  `/etc/rc.d/init.d/functions`, and carrying `# chkconfig:` and `# description:`
  headers. For an optional package it also requires the header to say `-`, so
  the service is **off by default**: installing a program is not deciding to run
  it, and `chkconfig <name> on` is where that decision is made.
- `image/10-rootfs.sh` names every optional package and the daemon it runs, or
  `-` for none. A new optional package fails the build until it says which it
  is, so the question is answered rather than skipped.
- `config/hooks/<name>.hooks` should carry `post-upgrade|service-restart`, so an
  upgrade moves a running daemon onto the program that replaced it, and
  `pre-remove|service-stop` with `pre-remove|service-disable`, so a removal does
  not leave a daemon running from an unlinked binary and rc links naming a
  script that is gone. `pkg_check_hooks` rejects a hook naming a service no init
  script provides.

## Cross-compile notes

Every one of these cost a build. The repo's rule — *never leave an optional
feature to autodetection* — is what most of them amount to.

- **Build in-tree whenever the source quotes `__FILE__`.** An out-of-tree build
  spells `srcdir` absolutely, so the builder's home directory is compiled into
  the binary and `pkg_merge`'s build-path check rejects it. The fix is
  `cp -a "${source}/." "${build_tree}/"` and `./configure`, as
  [packages/wget.sh](../scripts/stages/packages/wget.sh) does.
- **libtool hardcodes `RUNPATH=/usr/lib64`** unless the package has
  `--disable-rpath`. When it has none, edit the generated libtool:
  `sed -i -e 's|^hardcode_libdir_flag_spec=.*|hardcode_libdir_flag_spec=""|'
  -e 's|^runpath_var=LD_RUN_PATH|runpath_var=|' libtool`.
- **Set modes in the stage, not from the install.** An install hook that wants
  `-o root` cannot work in an unprivileged build, and packages write those hooks
  with a leading `-` so make ignores the failure — inetutils left ping at mode
  0600 that way. Assign every mode explicitly after the strip that would have
  cleared it, then read it back.
- **A program is not always where its name suggests.** Check the staged tree
  rather than assuming `/usr/bin`. sudo's `visudo` goes to `--sbindir` and its
  stage asserted all three of its programs in `/usr/bin`, which is a stage that
  fails on a build that worked.
- **`config.guess` is not always at the top of the tarball.** `AC_CONFIG_AUX_DIR`
  moves it, and the two places it lands here are `config/` (userspace-rcu) and
  `scripts/` (sudo). The failure is immediate and clear, but it is the first
  thing a new stage hits, so look before writing the line.
- **A build path can be compiled in as data rather than as `__FILE__`.** BIND
  records its whole configure line in `config.h` so that `named -V` can print
  it, which drags in `PKG_CONFIG_LIBDIR`, `LDFLAGS` and `CC` — every one of them
  naming this machine. Building in-tree does not help, because the string is
  not a file name. The fix is to rewrite the `#define` after configure and
  before make, and then assert the rewrite took.
- **`-rpath-link`, not `-rpath`, for a package whose libraries need each
  other.** Clearing `hardcode_libdir_flag_spec` also removes what libtool used
  to resolve a library named by another library in the same build tree, and the
  build fails at the first command that links the third one. `-Wl,-rpath-link`
  answers the linker without recording anything in the output; packages/bind
  does it for all five of its libraries.
- **A RUNPATH is sometimes load-bearing.** The rule is not "no run-time path",
  it is "no run-time path this image did not intend": sudo has to carry
  `/usr/libexec/sudo` or it cannot find its own policy plugin. Assert the set of
  path elements against an allowlist rather than asserting the attribute is
  absent, which catches a build-tree path without failing on a real one.
- **Assert on strings with `grep -aqF`, never `grep -x`.** A binary's strings are
  NUL-separated, so `-x` never matches inside one.
- **`grep -q` on a long pipe fails under `pipefail`.** `grep -q` exits at the
  first match, the writer gets SIGPIPE, and the stage's `set -o pipefail` reports
  that as the assertion failing. Harmless for `readelf -d`, which fits in the
  pipe buffer; not for `readelf --dyn-syms`, where the match is one of hundreds
  of lines. Read the output into a variable first and grep that — packages/zstd
  does.
  Add `-W` when matching a symbol name: readelf abbreviates past 16 characters.
- **Assert a package did not leak `__FILE__`.** The `pkg_merge` build-path check
  catches it, but the cause is usually a third-party file that includes
  `<assert.h>` directly while the build system never defines `NDEBUG` — zstd's
  bundled divsufsort.c does exactly this, and only its cmake and meson builds
  define it. Look for the makefile's own hook for extra flags (`MOREFLAGS` in
  zstd) rather than setting `CPPFLAGS`, which would displace what it puts there.
- **Prefer the target that links the shared library.** A package that builds
  both a library and a command often compiles the library into the command by
  default; zstd needed the `zstd-dll` target to link `-lzstd` instead, which is
  worth ~800 KB when the image carries the library for something else anyway.
  Assert it afterwards — the undefined symbols in the command are the proof.
- **meson does not cross-compile from the environment.** `CC`, `CXX` and the
  rest describe the *build* machine to meson and nothing else; everything about
  the target comes from a `--cross-file`, which the stage writes itself.
  packages/plocate is the one that does it. Two things belong in `[properties]`
  and are easy to leave out: `sys_root`, without which meson's pkg-config
  answers point at the build host's `/usr`, and `pkg_config_libdir`, without
  which an optional dependency the host happens to have — liburing, for plocate
  — is found and linked against a library the image does not ship. Assert the
  resulting `NEEDED` set afterwards; that is what catches it. meson also needs
  adding to `scripts/host-check.sh`, with ninja.
- **A pkg-config dependency needs the three cross variables.** `PKG_CONFIG`,
  `PKG_CONFIG_LIBDIR` pointed at `${SYSROOT}/usr/lib64/pkgconfig` and
  `PKG_CONFIG_SYSROOT_DIR` pointed at `${SYSROOT}`, as
  [packages/chrony.sh:16-18](../scripts/stages/packages/chrony.sh#L16-L18) sets
  them. Without `PKG_CONFIG_LIBDIR` the configure reads the *build host's*
  `.pc` files and produces flags for the host's libraries; batch D is the first
  work here where three separate dependencies are all found that way.

## Verifying a new stage

```
make check                      # bash -n, shellcheck, the validators, and the
                                # NEEDED-vs-invalidation audit from item 5
make <newpkg>                   # the stage alone
make rootfs                     # the presence assertions
make packages                   # the only place path collisions surface
make image && make run-qemu     # boot, then exercise the new binaries by name
```

**The sysroot reconciles itself.** `pkg_merge` records the paths it merged
under `work/pkgmerged/<name>.paths`, and the next merge of the same package
removes the recorded paths its new staging tree does not supply — restoring the
preferred remaining claimant for a shared path, and removing a directory only
if `rmdir` can. Non-directory overlaps always follow package-table order rather
than whichever stage happened to rebuild last. So a stage that renames a
library or drops a file no longer needs a clean sysroot or a hand-written `rm`,
and an incremental build cannot ship a file that a clean build of the same
revision would not contain. An interrupted merge marks the sysroot dirty and
requires `make clean` rather than letting another stage consume mixed output.

**A stage reruns when its inputs change.** Its stamp holds a key over its
script, the shared build libraries, `config/build.conf`, the lock rows it was
observed to use, any `${PROJECT_ROOT}/...` path it names, its package and
licence rows, its own line in the driver, dependency stage keys, selected
environment/build flags, and the cross toolchain. Package metadata is scoped to
its consumer: component stages get their own row, rootfs assembly and the ISO
version list get the complete catalogue, and toolchain, host-tool, and
payload-only artifact stages get none. Nothing has to be declared for source and
repository inputs: the lock rows are recorded as the stage asks for them, so a
loop over patch names works, and the repository paths are found by scanning the
script, so a literal path cannot be forgotten. Runtime/build relationships still
live in the package table and the reverse lists in item 6, and `make check`
cross-checks them against ELF dependencies.
`make stage-key STAGE=packages/<name>` shows the whole input list and says
whether the stage is current.

**Adding your package does not rebuild the others.** Everything you touched
above — a row in `config/packages.conf`, a licence row, a recipe under
`scripts/stages/packages/`, a function and a dispatch line in
`scripts/build.sh` — reaches your new stage and the one that assembles the
image, and nothing else:

```text
$ ./scripts/build.sh <name>       # builds your stage
$ ./scripts/build.sh image        # reassembles the rootfs around it
```

That is worth stating because it was not always true. `scripts/build.sh` used to
be hashed whole into every stage key, so adding one package rebuilt all
eighty-eight of the others, and so did a comment. What is an input now is the
one line of the driver that is about your stage — which package it produces —
while the rest of what the driver decides is already in the key by name: your
dependencies appear as `dependency <stage> <key>` lines, and `image/10-rootfs`
carries every component stage as a dependency, which is why it is the one stage
a new package does reach. The same reasoning keeps `scripts/lib/stage.sh` out of
the key: it is the machinery that computes keys, and everything it does is
already visible in the key it computes.

What still rebuilds everything, correctly, is a change to the code that builds:
`scripts/lib/common.sh`, `scripts/lib/package.sh`, `scripts/lib/license.sh` or
`config/build.conf`. A compiler flag or a change to how sources are prepared
really can change every binary in the distribution.

**Path precedence is fixed.** The rootfs overlay wins first, then image packages
in `packages.conf` order. Incremental merges reassert the same order for shared
non-directory paths, and `make packages` verifies that the resulting manifests
cover the image without duplicate ownership. An optional package that conflicts
with an image file fails at the rootfs boundary.
