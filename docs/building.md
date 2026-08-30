# Building Sowa

Sowa builds on an x86_64 Linux host as an unprivileged user. The build creates
an out-of-tree sysroot and writes only below the configured work, download, and
artifact directories; it does not install target files into the host.

## Quick start

After installing the host prerequisites:

```sh
make check
make fetch
make all
```

`make check` validates the host, build metadata, stage graph, package ownership
rules, and self-tests. `make fetch` downloads every source named in
[`config/sources.lock`](../config/sources.lock), falls back through configured
mirrors when needed, and verifies its SHA-256. `make check-updates` compares the
pins with upstream release feeds without changing them.
`make all` builds the dependency graph through the live image.

The first build is substantial. Later runs use keyed stamps under
`work/stamps/` and rebuild only stages whose recipes, inputs, dependencies, or
toolchain identities changed. Use this to inspect a key:

```sh
make stage-key STAGE=packages/openssh
```

See [Bootstrap architecture](architecture.md) for the dependency model and
stamp inputs.

## Host requirements

The authoritative check is [`scripts/host-check.sh`](../scripts/host-check.sh).
It currently requires:

- an x86_64 Linux host and an unprivileged build account;
- GCC 10 or newer, G++, GNU Make, Bash, binutils, and common text utilities;
- Bison, Flex, Autoconf, Automake, Libtool, pkg-config, Meson, and Ninja;
- Perl, Python 3, Go 1.26.3 or newer, Texinfo, and gettext tools;
- curl, Git, OpenSSL, tar, cpio, gzip, bzip2, and XZ;
- squashfs, FAT, ext4, GRUB, partitioning, fakeroot, mtools, and QEMU image
  utilities used by the release artifacts; and
- zlib development headers.

Run `make check` after installing them; its missing-command output is more
precise than package names, which vary between host environments.

The ISO stage also needs `grub-mkrescue` and `xorriso`. UEFI ISO support needs
the GRUB `x86_64-efi` platform files and `mtools`. The QEMU run targets need an
x86_64 system emulator, and UEFI tests need OVMF firmware.

## Containerized build environment

The provided container packages the host-side prerequisites and maps the
checkout into an unprivileged builder account:

```sh
docker/sowa-env.sh run make check
docker/sowa-env.sh run make all
```

Artifacts remain in the host checkout. The wrapper supports Docker and Podman;
see [`docker/README.md`](../docker/README.md) for image pinning, UID mapping,
fresh-clone builds, and optional KVM access.

## Targets

`make help` lists every public target. The most useful groups are:

| Goal | Result |
| --- | --- |
| `make toolchain` | cross binutils, GCC, Linux headers, and glibc |
| `make rootfs` | assembled target root filesystem |
| `make image` | squashfs live root plus the `liveinit` initramfs |
| `make iso` | bootable live ISO |
| `make disk-image` | raw and QCOW2 preinstalled disk images, with compressed copies |
| `make rootfs-tarball` | bootable root filesystem archive |
| `make installer-bundle` | portable `sowa-install` script |
| `make recovery-image` | complete root filesystem in a recovery initramfs |
| `make docker-image` | loadable container image archive |
| `make packages` | package archives, signed index, and package metadata |
| `make publish-repo` | static repository tree under `dist/` |

Individual component targets, such as `make openssh` or `make gcc`, visit their
dependencies automatically. `make clean` removes builds, the sysroot, stamps,
and artifacts. `make distclean` also removes downloaded and extracted sources.

## Build settings

Common environment overrides include:

| Variable | Purpose |
| --- | --- |
| `JOBS` | parallel build jobs; `auto` by default |
| `WORK_DIR` | build trees, sysroot, package staging, and stamps |
| `DOWNLOAD_DIR` | verified source archives |
| `ARTIFACT_DIR` | release and boot artifacts |
| `SOURCE_DATE_EPOCH` | normalized build timestamp |
| `TERM_TITLE=0` | disable terminal-title progress updates |
| `SFS_COMPRESSOR` | live root compression, `xz` by default or `zstd` |
| `FETCH_CONNECT_TIMEOUT` | connection timeout for each primary or mirror, 20 seconds by default |
| `FETCH_LOW_SPEED_LIMIT` | minimum sustained fetch rate, 1,024 bytes/s by default |
| `FETCH_LOW_SPEED_TIME` | seconds below that rate before trying the next mirror, 30 by default |

Architecture and release defaults live in
[`config/build.conf`](../config/build.conf). Moving an existing checkout after
building invalidates absolute toolchain paths; clean and rebuild it at the new
location.

On an interactive terminal, the current stage is mirrored in the title, for
example `sowa all: toolchain/06-glibc`. A completed build ends with `done`; a
failure names the failed stage. Fetches display a similar item counter.
See [Upstream releases and source mirrors](upstream-releases.md) for the release
checker, detailed transfer output and mirror table.

## Running artifacts

The live, ISO, recovery, and installation targets build their declared image
prerequisites before starting QEMU. Build the preinstalled disk artifact before
using its run targets:

```sh
make run-qemu             # live payload, without GRUB
make run-iso              # release ISO
make run-recovery         # recovery initramfs
make run-install          # ISO plus a blank installation disk
make disk-image           # build the preinstalled disk artifacts
make run-disk-image       # prebuilt disk image on BIOS firmware
make run-disk-image-uefi  # prebuilt disk image on UEFI firmware
```

They are headless by default and exit with `Ctrl-a x`. Set
`SOWA_QEMU_DISPLAY=gtk` for a display window and `SOWA_QEMU_CPUS=4` to change
the virtual CPU count. Network forwarding is covered in [Networking](networking.md).

The recovery image contains the complete root filesystem in one initramfs and
therefore needs more memory than the live ISO. It boots with `rdinit=/init` and
does not depend on finding or mounting live media. Add `single` to the kernel
command line to stop in runlevel S; `telinit 3` continues to the normal
multi-user runlevel.

## Artifacts and next steps

Generated files are placed below `artifacts/` and include checksums where
applicable. Exact names incorporate `DISTRO_NAME`, `DISTRO_VERSION`, and
`ARTIFACT_ARCH`.

- Read [Live medium](iso.md) before writing or customizing an ISO.
- Read [Prebuilt disk image](disk-image.md) for raw and QCOW2 deployment.
- Read [Installing Sowa](install.md) for `sowa-setup`, bootstrap, and chroot.
- Read [Release authenticity](releases.md) before distributing artifacts.
- Read [Binary packages and updates](packages.md) before publishing `dist/`.
