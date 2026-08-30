# Bootstrap architecture

Sowa uses an out-of-tree, sysrooted cross build. Nothing is installed into the
host. The initial port is `x86_64-sowa-linux-gnu`; architecture-specific values
live in `config/build.conf` and `config/kernel-x86_64.fragment`.

The dependency chain is deliberately explicit:

```text
cross binutils
  -> bootstrap GCC (C only, no libc)
  -> Linux UAPI headers
  -> glibc bootstrap headers and start files
  -> target libgcc
  -> complete glibc
  -> final GCC (C and C++)
  -> libgcc_s.so.1 and libstdc++.so.6 into the sysroot
  -> Bash -> bash-completion
  -> ncurses -> nano, Vim, and htop
  -> OpenSSL -> Mozilla CA certificates
  -> zlib
  -> OpenSSL, Mozilla CA certificates, and zlib -> curl and libcurl
  -> ncurses, OpenSSL, and zlib -> CPython and pip
  -> e2fsprogs, dosfstools, and GRUB (i386-pc and x86_64-efi)
  -> zlib -> native binutils -> native GCC (C and C++)
  -> kernel and sowa-init
  -> root filesystem
  -> squashfs root image + liveinit initramfs
  -> bootable ISO
```

The live medium is two of those artifacts rather than one. `make image` writes
the root filesystem as a squashfs and, beside it, a one-megabyte initramfs
holding a single static program - `liveinit`, built from `src/liveinit` by the
same stage - whose whole job is to find the medium, mount that squashfs through
a loop device, overlay a tmpfs on it and `switch_root`. It is the only thing in
this repository linked statically, because there is nowhere in a one-megabyte
image for a dynamic loader to look. See [iso.md](iso.md).

The e2fsprogs, dosfstools, and GRUB stages exist to make an installed system
self-hosting: `sowa-setup` (see [install.md](install.md)) uses them to create
filesystems and install a bootloader onto a disk from the live ISO.

The native binutils and GCC stages are the same two tarballs as the first two
steps of the chain, built the other way round. A cross build names two machines,
`--build` and `--host`; these name three, and it is the relation between them
that decides what comes out:

```text
cross toolchain    --build=this host  --host=this host  --target=sowa
native toolchain   --build=this host  --host=sowa       --target=sowa
```

Host equal to target is what makes the second one a native compiler - `ld`
takes the system library directories only when it is configured native, and the
programs are installed under their plain names rather than behind a triplet
prefix. Build different from host is what makes it a *cross build of* a native
compiler, the "Canadian cross" the GNU build system is named for, and it is why
both stages verify their output by reading it - `readelf -h` for the
architecture, `readelf -d` for what it links - instead of running it. Nothing
in these two stages can be executed until the image boots.

GCC is configured with `--with-build-time-tools` pointing at the cross
binutils, so the assembler and linker it asks about at configure time are the
same 2.47 the native binutils package installs and it will drive on the target.
GMP, MPFR and MPC come from the in-tree copies both GCC stages link, so they
end up compiled statically into `cc1` and no version of them is installed
anywhere.

The `libgcc_s.so.1` and `libstdc++.so.6` steps are copies rather than builds:
the final GCC leaves both libraries in `work/tools`, and the two stages install
them into the sysroot as part of the runtime rather than of the toolchain.
Nothing built here links either one - GCC puts libgcc into a C program
statically - so their absence is invisible at build time and fatal at run time.
`libgcc_s.so.1` is what glibc `dlopen`s by name
whenever a thread calls `pthread_exit` or `pthread_cancel`, and both are what a
binary from outside the image links outright: a Rust program needs the unwinder,
a C++ program needs the pair, and neither can be rebuilt on a system with no
compiler. Both fall to `sowa-base`, which already owns the glibc runtime.

The GRUB stage builds its boot-time images with
`-fno-reorder-blocks-and-partition`, which is a correctness requirement rather
than a tuning choice. GCC 16 moves cold basic blocks into separate
`.text.unlikely` sections, and the default linker script emits those ahead of
`.text`; that put a cold stub at the base of `kernel.img` and pushed `_start`
0x2b bytes in. The i386-pc decompressor jumps to the image base unconditionally,
so the BIOS core image ran the stub instead of GRUB and the machine died before
printing "Welcome to GRUB!" - while UEFI, which takes its entry point from the
PE header, kept working and hid the breakage. The stage asserts after the build
that the i386-pc entry point still equals the image base.

The build tree is not relocatable. GCC and binutils are configured with absolute
`--prefix` and `--with-sysroot` paths derived from the project root, so moving
the checkout invalidates `work/tools`; run `make clean` and rebuild rather than
symlinking the old path into place.

Stages live under `scripts/stages` in four groups, and a stage's name is its
path there without the suffix: `toolchain/06-glibc`, `packages/openssh`,
`image/11-initramfs`. The name is the whole of a stage's identity — the file
that produces it, the stamp that records it, and the argument `make stage-key`
takes — so nothing has to be registered anywhere for a new stage to be found.

Only two groups number their stages, because only two have an order at all.
`toolchain/` is a bootstrap and `01` to `07` are its sequence; in `image/`,
`10-rootfs` assembles the tree that `11-initramfs` wraps. Everything under
`packages/` and `host/` is ordered by what it needs rather than by where it sits
in a list, and that order is written once, as the dependency functions in
`scripts/build.sh`. Adding a package therefore adds a file and a function, and
never a number that has to mean something.

Every completed stage writes a stamp below `work/stamps`, in the directory its
group names, and the stamp holds a key over everything the stage's result
depends on: its own script, the shared build libraries and `config/build.conf`,
the `config/sources.lock` rows it was observed to use, any patch or local source
tree or configuration file it names, the package, licence, hook and message rows
it consumes, allowlisted environment/build flags, recorded dependency stage
keys, and — for everything outside `toolchain/` — the combined input and
recorded-output identity of the cross toolchain. Metadata scope is deliberate: a
component gets its own package, `image/10-rootfs` gets the complete catalogue,
`image/11-initramfs` gets Linux's metadata, and the cross toolchain, host tools
and payload-only artifacts get none. Thus a Docker packaging revision cannot
become a compiler input and fan out into a full rebuild. A stage is skipped only
when the key it would build under is the key recorded beside its result, so a
bumped source, edited recipe, new patch, rebuilt library or rebuilt compiler
reruns the affected closure without anybody deleting anything.
`make stage-key STAGE=packages/openssh` prints those inputs as text and says
whether the stage is current, which is how to find out why something rebuilt.

`make packages` refuses to run while any stamp is stale: a release is cut from
the assembled tree but labelled from the current tables, so a stage that has not
caught up would publish old bytes under a new version.

Use `make clean` when changing the target triple or libc ABI; nothing else
needs a stamp removed by hand. A merge interrupted while changing the cumulative
sysroot also requires a clean rebuild, because no later stage is allowed to
consume a mixture of the old and new package trees.

The build scripts intentionally disable optional binutils `gprofng` and GCC
sanitizer/runtime components during bootstrap. They are distribution packages,
not prerequisites of the compiler/libc trust chain, and can be added later as
normal recipes.

## Reproducibility and trust

`config/sources.lock` pins archive names, HTTPS upstream URLs, exact versions,
SHA-256 digests, and extraction directories. `config/upstreams.conf` keeps
release discovery and review links beside rather than inside that immutable
input, while `config/mirrors.conf` supplies transport fallbacks. Downloads are
first written to a temporary file, verified against the lock after every
primary or mirror attempt, and then atomically renamed. Builds set a stable
locale, timezone, umask, and `SOURCE_DATE_EPOCH`. nic, the one Go program here,
is built with `-trimpath`; the initramfs uses sorted input, normalized
ownership, and XZ's timestamp-free stream format without a preset override
(its integrity check is CRC32, which Linux's early decoder supports),
and the squashfs root image is built with `-all-root` and both of mksquashfs's
time options fixed to `SOURCE_DATE_EPOCH` - which matters beyond determinism
for its own sake, because the medium is identified by that image's SHA-256.
Bit-identical GNU toolchain output across different host systems is not yet a
release claim.

SHA-256 protects the lock against mirror corruption after review. A future
release process should additionally verify upstream OpenPGP/minisign signatures
and publish a signed lock file. Generated filesystems should eventually be
rebuilt twice on independent hosts.

One entry in the lock is not a source archive at all: GNU Guix is pinned as
upstream's binary tarball, because a package manager that bootstraps its own
world cannot be compiled without a copy of itself to compile it in. Nothing in
the image is built from it, nothing links against it, and it is not installed by
default - it is an optional package and stays outside the compiler/libc trust
chain - but it is worth naming plainly: those binaries were built by the Guix
project, and what Sowa checks is that they are the bytes upstream published.
See [guix.md](guix.md).

Released images now carry a per-package manifest of every path, with a SHA-256
for each regular file, at `/var/lib/sowa/db`. `sowa-pkg verify` checks an
installed system against it, and the published repository index - which pins
every archive by SHA-256 - is signed with Ed25519 so that the key, rather than
the hosting, is what an update trusts.

## Packaging

Each component stage installs into its own staging tree below `work/pkgstage`
and that tree is then merged into the sysroot, so the build still compiles and
links against a single sysroot. The staging trees exist so that file ownership
is knowable afterwards: the rootfs stage splits the assembled image between the
packages that produced it and writes the result both as manifests under
`work/pkgmeta` and as the image's own package database.

Packages are therefore cut out of the image rather than built beside it, and
`make packages` fails if any path in the image is unclaimed or claimed twice.
That constraint is the point: it makes "the packages" and "the image" the same
artifact described two ways, rather than two things that have to be kept in
agreement by hand.

A package marked `optional` in `config/packages.conf` is the deliberate way out
of that identity: it is built by an ordinary stage but never merged into the
sysroot, so it is packaged from its staging tree and reaches a system only
through `sowa-pkg install`. nginx is built that way, which is how the image
stays a base system while the repository offers more than the image contains.
See [packages.md](packages.md).

## Scope of milestone 0.1

This is a bootstrap and boot-image system. It establishes the
compiler/libc/kernel trust boundary and a small userspace. The Bash,
bash-completion, ncurses, nano, OpenSSL, CA-certificate, Vim, htop, zlib, curl,
and CPython stages are explicit recipes rather than a general dependency
resolver: `config/packages.conf` records the dependency graph for installation
and removal, but the build order is still written out in `scripts/build.sh`.
`make iso` wraps the release image in bootable live media, `sowa-setup`
installs it to a disk, and `sowa-pkg` keeps an installed system current from a
signed repository. Building a package from source on the target, and additional
architectures, belong in later milestones.
