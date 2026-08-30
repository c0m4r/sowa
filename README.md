<img src="assets/logo.jpg" alt="" />

[ISO](https://sowa.wolfet.pl/sowa-0.1-x86_64.iso) | 
[RAW Image .xz](https://sowa.wolfet.pl/sowa-0.1-x86_64.img.xz) |
[QCOW2 Image .xz](https://sowa.wolfet.pl/sowa-0.1-x86_64.img.xz) | 
[Sowa Installer](https://sowa.wolfet.pl/sowa-install) & [rootfs.tar.xz](https://sowa.wolfet.pl/sowa-0.1-x86_64-rootfs.tar.xz)

# Sowa Linux

Sowa is a small, inspectable Linux® system built from source. It produces an
x86_64 toolchain, kernel, userspace, live ISO, installable disk images, and a
signed binary package repository without installing files into the host system.

The project currently provides:

- a checksum-pinned, sysrooted GNU toolchain and self-hosting C/C++ compiler;
- a compact live system with BIOS and UEFI boot support;
- `sowa-init`, a System V-style init and service framework;
- disk, rootfs, recovery, container, and installer artifacts;
- `sowa-pkg`, backed by a signed, self-hosted package repository; and
- reproducible build inputs and per-package file ownership.

The initial and currently supported target is x86_64. See the
[architecture](docs/architecture.md) and [software overview](docs/software.md)
for scope and implementation details.

## About

Sowa is a standalone, experimental Linux distro built for servers/headless environments, aimed at power users, 
and shipping with just a minimal set of core tools that you can expand as needed.

It comes with its own package manager (`sowa-pkg`), which lets you pull in extra tooling 
like Docker and the GNU Guix package manager, opening the door to plenty of pre-built software.

Sowa packs a few custom and old-school quirks:

* **Custom SysV-style init system**
* **Network configuration** driven by a custom utility called `nic` (configured in `/etc/nic.conf`), 
serving as a wrapper around `iproute2`. By default, it uses DHCP, drops incoming traffic via `iptables`, and only lets ICMP and SSH through
* **Time sync** enabled out of the box via `chrony`, hooked up to Cloudflare’s time servers
* **SSH enabled by default** with root login strictly key-based, as the root account has no password set by default
* **Hybrid package distribution**: some packages are available as binaries built from source via `sowa-pkg` (e.g., Nginx, HAProxy, Docker, Guix), 
while others use custom installers that pull directly from upstream vendors (e.g., Ollama, Node.js, Go, or Rust)

If you miss the good old days, hate `systemd`, and want to build your own system from the ground up, Sowa is for you. 
But you're on your own here—I don't guarantee regular updates or backward compatibility. 
Sowa has no fixed release cycle or update model, and patches will drop strictly on a "best effort or when I feel like it" basis.

## Build

On a prepared x86_64 Linux host:

```sh
make check
make fetch
make all
```

Build outputs are written to `artifacts/`. Set `JOBS=8` to control parallelism;
`WORK_DIR`, `DOWNLOAD_DIR`, and `ARTIFACT_DIR` can place large outputs on a
different filesystem.

A containerized build environment is also available:

```sh
docker/sowa-env.sh run make check
docker/sowa-env.sh run make all
```

Host prerequisites, individual targets, build variables, and artifact details
are documented in [Building Sowa](docs/building.md). The container workflow has
its own [guide](docker/README.md).

## Run and install

Boot the live ISO or prebuilt disk image in QEMU:

```sh
make run-iso
make disk-image run-disk-image
```

Exit a headless QEMU session with `Ctrl-a x`. To install from the live system,
log in as root and run:

```sh
sowa-setup
```

The live image starts with a passwordless root console account; remote root
login remains unavailable until an SSH key is installed. Read the
[installation](docs/install.md) and [account](docs/accounts.md) guides before
deploying a machine.

## Documentation

The [documentation index](docs/README.md) covers the complete build and system.
Common starting points are:

- [Live ISO](docs/iso.md), [disk image](docs/disk-image.md), and
  [installation](docs/install.md)
- [Packages and updates](docs/packages.md) and
  [adding a package](docs/adding-a-package.md)
- [Init and services](docs/init.md), [networking](docs/networking.md), and
  [SSH](docs/ssh.md)
- [Release authenticity](docs/releases.md) and [licensing](docs/licensing.md)

Run `make help` for the available build and run targets. A booted system also
includes manual pages and short guides under `/root/sowa-howto/`.

## License

Sowa's own code is licensed under GPL-3.0-or-later. Included third-party
components retain their respective licenses; see [Licensing](docs/licensing.md)
for the package-level records and installed license locations.

Linux® is the registered trademark of Linus Torvalds in the U.S. and other countries.
