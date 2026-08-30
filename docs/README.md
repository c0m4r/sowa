# Sowa documentation

This directory contains the detailed documentation kept out of the project
README. Start with [Building Sowa](building.md) for a local build or
[Installing Sowa](install.md) for deployment.

## Build and design

- [Building Sowa](building.md) — prerequisites, targets, artifacts, and QEMU
- [Bootstrap architecture](architecture.md) — toolchain, stages, trust, and reproducibility
- [Software in Sowa](software.md) — package profiles, core capabilities, and defaults
- [Adding a package](adding-a-package.md) — recipes, metadata, services, and verification
- [Building in a container](../docker/README.md) — isolated host-side build environment

## Images and installation

- [Live medium](iso.md) — ISO layout, boot process, memory use, and kernel parameters
- [Prebuilt disk image](disk-image.md) — image formats, first-boot growth, and customization
- [Installing to disk](install.md) — guided, bootstrap, chroot, and container workflows
- [Resizing a disk](resize.md) — growing partitions and ext4 after deployment

## System administration

- [Init and services](init.md)
- [Accounts](accounts.md)
- [Networking](networking.md)
- [OpenSSH](ssh.md)
- [VPNs](vpn.md)
- [Swap and zram](swap.md)
- [Landlock sandboxing](sandboxing.md)
- [Locales](locale.md)
- [Time synchronization](time.md)
- [Cron](cron.md)
- [Logging](logging.md)
- [Manual pages](manual-pages.md)
- [GNU Bash integration](bash.md)

## Packages and releases

- [Binary packages and updates](packages.md)
- [Optional packages](optional-packages.md)
- [Release authenticity](releases.md)
- [Licensing](licensing.md)
- [GNU Guix](guix.md)
- [Sowa Monitor](sowa-monitor.md)
