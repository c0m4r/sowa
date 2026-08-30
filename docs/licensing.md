# Licensing

Sowa ships other people's work. Almost every licence that work carries requires
the licence itself to travel with it — the GPL and LGPL say so outright, the
BSD and MIT families require the notice to be reproduced — so a package without
its licence is not merely undocumented, it is distributed on terms it does not
meet.

Sowa therefore treats a licence as part of the package rather than as
documentation about it. Every package installs its texts into

```text
/usr/share/licenses/<package>/
```

which is a real directory the package owns: it is in the package's `.FILES`
manifest, `sowa-pkg owns` resolves paths inside it, `sowa-pkg verify` checks
them against their recorded SHA-256, and removing the package removes them.

## Who wrote what

Four packages are Sowa's own work and are GPL-3.0-or-later, as is the build
system in this repository:

- **`sowa-init`** — PID 1 and the commands that drive it, from `src/init`
- **`sowa-release`** — `/etc`, the system installers, `sowa-pkg`,
  `sowa-license`, from `rootfs-overlay`
- **`custom-installers`** — the pinned installers placed in `/opt`, from
  `src/custom-installers`
- **`sowa-monitor`** — the optional monitoring backend and dashboard, from
  `src/sowa-monitor`

`liveinit`, in `src/liveinit`, is Sowa's on the same terms; it is inside the
live medium's initramfs rather than in a package.

Everything else is an upstream project, built from the unmodified tarball
pinned in `config/sources.lock` and shipped under the terms that tarball
carries. That distinction is recorded per package rather than inferred, in the
`copyright` field: `sowa` or `upstream`. It travels into the package's
`.PKGINFO`, into the installed database, and into the repository index, which
is what lets `sowa-license` print the two groups apart on a machine that has
never seen this repository.

## The table

`config/licenses.conf` is one row per package:

```text
name|copyright|license|files
```

```text
bash|upstream|GPL-3.0-or-later|bash:COPYING
sowa-init|sowa|GPL-3.0-or-later|sowa:LICENSE
zstd|upstream|BSD-3-Clause OR GPL-2.0-only|zstd:LICENSE,zstd:COPYING
linux|upstream|GPL-2.0-only WITH Linux-syscall-note|linux:COPYING,linux:LICENSES/preferred/GPL-2.0=GPL-2.0,linux:LICENSES/exceptions/Linux-syscall-note=Linux-syscall-note
```

- **`copyright`** — `sowa` or `upstream`, as above.
- **`license`** — an SPDX expression covering everything the package installs.
  An `AND` means every one of those licences applies, to different files, which
  is what a distribution has to honour; an `OR` is a genuine choice the licensor
  offers; `WITH` attaches an exception to the licence it modifies.
- **`files`** — comma-separated `origin:path[=name]` references. `origin` is a
  `config/sources.lock` entry, or the literal `sowa` for a path relative to this
  repository. `=name` renames the installed copy, which is what two sources that
  both ship a `COPYING.LIB` need in order to sit in one directory; without it
  the installed name is the file's own basename.

Nothing copies licence *texts* into this repository. They are read out of the
same pinned tarballs the code is built from, so the licence that ships is the
licence that came with the version that was built and cannot drift from it. The
one exception is `config/licenses/`, for a distribution that carries no text at
all: the Mozilla CA bundle is a file of certificates and nothing else, so
`config/licenses/MPL-2.0.txt` supplies its terms.

A package built from several upstream projects lists all of them. GnuPG is
eight tarballs installed into one staging tree; Git and nginx each link a
static PCRE2. Each of those carries every constituent licence, named for the
project it came from — `COPYING.LIB.libgcrypt`, `LICENCE.pcre2.md`.

## Where it happens in the build

`scripts/lib/license.sh` reads the table and installs the texts. It happens
twice, in two places, for two different reasons.

**At `pkg_merge` and `pkg_keep_staged`** — the one point every component stage
passes through. The texts go into the staging tree before it is merged, so the
same files reach the sysroot, the image and the published package, and a stage
needs no licence code of its own. This is what makes a freshly built staging
tree complete.

**At `scripts/stages/image/10-rootfs.sh`, for every package, unconditionally.**
A stage is skipped when its stamp and its staging tree are both already there,
so on a build cache older than `config/licenses.conf` not one stage would run
and not one licence would be installed — which is exactly how this was first
found: eighty packages already built, none carrying a licence, and nothing that
would rebuild them. Licence texts are copied rather than compiled, so repeating
the work at assembly time costs a few file copies and no compiler, and it makes
correcting the table a `make rootfs` instead of a rebuild of the whole system.
`pkg_install_licenses` rebuilds each directory from the table rather than adding
to it, so it is idempotent and a text that has been renamed or dropped leaves
the image with it.

That pass is the authoritative one. It installs into the staging tree *and* the
image for a package that has a tree, into the image alone for the two that do
not — `sowa-base` is by definition whatever is left over once the others have
claimed their files, and `sowa-release` is the overlay — and into the staging
tree alone for the optional packages, which never enter the image and are cut
from their trees. `pkg_assign_ownership` claims `usr/share/licenses/<name>/` for
`<name>` whatever put it there, which is what keeps `sowa-release`'s licence out
of `sowa-base`.

The kernel is the exception at both ends: it is staged after the root filesystem
has been assembled, so `image/11-initramfs.sh` installs its licence into the
staging tree its manifest is cut from and into the image its archive is cut
from, and asserts both. That stage rebuilds `linux.files` from scratch, which is
why `rootfs()` in `scripts/build.sh` drops the initramfs stamp whenever the
rootfs stage is going to run: a tree assembled again without it would carry a
kernel package with no kernel in it.

Four checks stand between a package and the repository:

1. `make check` — every package has exactly one row, every row names a package,
   every origin is a source the lock pins, no two texts would be installed under
   one name.
2. `pkg_install_licenses` — the file the row names is really in that tarball, or
   the build stops.
3. `pkg_check_licenses` — the licence directory exists and is not empty, checked
   at every point a package is finished, and again across the whole image in the
   rootfs stage.
4. `make packages` — `verify_licenses` refuses to publish an archive whose
   manifest claims no file below its licence directory.

## What ships in the metadata

`pkg_write_info` writes two extra fields into every `.PKGINFO`, and therefore
into `/var/lib/sowa/db/<package>/desc` on an installed system:

```text
license=GPL-3.0-or-later
copyright=upstream
```

The repository index carries them too:

```text
# name|version|arch|archive|sha256|size|depends|license|copyright|pkgbuild|description
```

so the licence of a package can be read before it is installed. The description
stays the last field, because it is the only free-text one.

## On the machine

`sowa-license` is the interface. It reads the installed database, the verified
index and `/usr/share/licenses`; it contacts nothing and needs no privilege.

```sh
sowa-license                    # summary: ours, theirs, licence and classification counts
sowa-license sowa               # just the parts Sowa wrote
sowa-license list               # every installed package, its licence and classification
sowa-license list --available   # what the repository offers and this lacks
sowa-license list --all         # both
sowa-license show openssl       # the full text, through a pager
sowa-license openssl            # the same thing
sowa-license files openssl      # just the paths
sowa-license --root /mnt list   # about a disk mounted elsewhere
```

`man sowa-license` is the reference, `/root/sowa-howto/licensing.txt` the tour,
and `sowa-pkg info <package>` prints the same two fields for one package.

`sowa-license` also classifies each package's complete SPDX expression without
using the network. `osi-approved` means every applicable licence is on the
[OSI Approved Licences](https://opensource.org/licenses) list. `foss` means the
terms are free and open source but not OSI-approved; `foss-mixed` means a
package has both OSI-approved and other FOSS terms; and
`source-available-non-free` means it is source-available but carries non-free
terms. That last label is deliberately conservative: a new, unreviewed
identifier receives it until the local policy table in `sowa-license` is
updated.

## Licensing a package you are adding

`docs/adding-a-package.md` lists this as one of the places a new package
touches. Concretely:

1. Find the licence text in the unpacked source under `work/sources/<dir>`.
   `COPYING`, `LICENSE`, `LICENCE`, `COPYRIGHT` and `NOTICE` cover nearly
   everything; take all of them where a project ships several, because it ships
   several for a reason.
2. Read enough of them to write the SPDX expression. Prefer what the project
   states about itself — an `SPDX-License-Identifier` header, a `README`
   licensing section — over what the file name suggests. `COPYING` being the
   GPL does not mean the whole tarball is.
3. Add the row to `config/licenses.conf`, in the same position the package has
   in `config/packages.conf`.
4. `make check`, then build the package. If the path is wrong the stage stops
   with `the <source> sources carry no licence text at <path>`.

Where a source ships no text at all, add one to `config/licenses/` and reference
it as `sowa:config/licenses/<name>.txt` — but look hard first, because a
project that publishes no licence is a fact worth noticing before it is
packaged.
