# Software in Sowa

Sowa is a source-built base system rather than a fixed list copied into the
root filesystem. Every component has a build stage, a package record, and a
file manifest.

The source of truth is split between two files:

- [`config/sources.lock`](../config/sources.lock) pins upstream versions,
  archive URLs, extraction directories, and SHA-256 digests.
- [`config/packages.conf`](../config/packages.conf) defines package names,
  release counters, dependencies, profiles, and descriptions.

Consult those files for the complete current inventory. Keeping the inventory
there avoids a second version list drifting out of date in prose.

## Foundation

The current bootstrap foundation is GNU binutils 2.47, GCC 16.2.0, glibc 2.44,
and Linux 6.18.44. The supported target is `x86_64-sowa-linux-gnu`.

The build first creates a cross toolchain and sysroot. It later builds binutils
and GCC again to run on Sowa itself, so the installed image can compile C and
C++ programs:

```sh
cc hello.c -o hello
g++ hello.cc -o hello
./configure && make && make install
```

The image includes development headers, static libraries, GNU Make, M4,
Autoconf, and pkg-config. The target compiler and runtime are separate packages:
`gcc` and `binutils` own the development tools, while `sowa-base` owns glibc,
`libgcc_s.so.1`, and `libstdc++.so.6`. Prebuilt C++ and Rust programs therefore
have their common runtime libraries even if the compiler packages are later
removed.

The details of the cross and native compiler stages are in
[Bootstrap architecture](architecture.md).

## Base system

The image contains a terminal-oriented administration and development system,
including:

- Bash, completion, nano, Vim, less, and mandoc;
- coreutils, grep, sed, gawk, findutils, diffutils, util-linux, procps-ng,
  shadow, sudo, and common archive tools;
- OpenSSL, a pinned CA bundle, curl, Wget, Git, GnuPG, Python, and Perl;
- ext filesystem, FAT, partitioning, and GRUB tools for installation;
- iproute2, iptables, OpenSSH, WireGuard, OpenVPN, BIND tools, tcpdump, and
  network diagnostics;
- chrony, Cronie, syslog-ng, logrotate, and the Sowa service framework; and
- the target-native C/C++ toolchain and common build utilities.

`/usr` holds packaged programs. `/bin` is intentionally restricted to `bash`,
`bashbug`, `sh`, and `vi`; the rootfs stage checks that no package introduces
another entry there. Bash supplies `/bin/sh`, Vim supplies `/bin/vi`, and
`cc`/`c++` select the installed GCC drivers.

Each component is packaged separately even when it ships in the base image.
The rootfs build rejects missing ownership and conflicting owners. See
[Binary packages and updates](packages.md) for the ownership model.

## Runtime defaults

- `LANG=C.UTF-8` is selected in `/etc/locale.conf`; `en_US.UTF-8` is also
  compiled in the image. See [Locales](locale.md).
- OpenSSL, curl, Python, Git, and Wget use the shared CA bundle at
  `/etc/ssl/certs/ca-certificates.crt`.
- Python is available as `python3.14`, `python3`, and `python`; pip is available
  through matching `pip` names.
- Bash completion is loaded for interactive login shells from `/etc/profile.d`.
- Bash command-history logging support is compiled in but disabled by default.
  See [GNU Bash integration](bash.md).
- The console keyboard layout is not changed by Sowa. Remote sessions use the
  client's keyboard layout.

## Image and optional packages

The profile column in `config/packages.conf` decides whether a package is in
the image:

- `image` packages form the installed root filesystem and its initial package
  database.
- `optional` packages are built and published with the same repository but are
  installed only on request.

The optional set currently includes 7-Zip, Nmap, Sowa Monitor, nginx, HAProxy,
GNU Guix, and Docker. List what a configured repository offers with:

```sh
sowa-pkg update
sowa-pkg list --available
```

Install an optional package by name, for example:

```sh
sowa-pkg install nginx
```

Services supplied by optional packages may remain disabled until explicitly
enabled. Usage is covered in [Optional packages](optional-packages.md), while
package hooks and repository behavior are documented in
[Binary packages and updates](packages.md).

## Licenses and installed documentation

Every package owns its license texts below `/usr/share/licenses/<package>/`.
Most packages also install manual pages below `/usr/share/man`; Sowa-specific
commands are required to have them before the rootfs can be assembled. See
[Licensing](licensing.md) and [Manual pages](manual-pages.md).
