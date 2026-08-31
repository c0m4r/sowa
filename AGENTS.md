# AGENTS.md

This file applies to the entire repository.

## Project overview

Sowa is an experimental x86_64 Linux distribution built from pinned upstream
sources. The Bash build system creates a cross toolchain, target sysroot, root
filesystem, boot media, installable images, and a signed package repository.
Builds must remain unprivileged and out of tree: never install target files on
the host or use host libraries accidentally.

Read the relevant guide before changing a subsystem. `docs/README.md` is the
categorized documentation index. Start with `docs/architecture.md` and
`docs/building.md`; package work is specified in `docs/adding-a-package.md`.

## Repository map

- `Makefile` is the public entry point for checks, component builds, images,
  package publication, release operations, and QEMU runs.
- `scripts/build.sh` owns the dependency graph and build dispatch.
- `scripts/lib/common.sh` establishes the build environment and common helper
  surface; the rest of `scripts/lib/` implements stage identity, packaging,
  archives, and licences.
- `scripts/stages/` contains toolchain, host-tool, package, and image recipes.
- Top-level `scripts/` contains fetch, packaging, image, and run utilities.
  Release-sensitive entry points include `release-key.sh`, `repo-key.sh`,
  `release-manifest.sh`, `verify-release.sh`, `publish-repo.sh`, and
  `push-docker-image.sh`.
- `config/sources.lock` pins source identities and SHA-256 digests.
- `config/packages.conf`, `config/licenses.conf`, and `config/hooks/` describe
  package metadata, dependencies, licences, and lifecycle hooks.
- `patches/` contains tracked upstream fixes; `keys/` contains committed public
  verification keys only.
- `rootfs-overlay/` is source material copied into the target filesystem.
- `src/init/` and `src/liveinit/` are Sowa's C programs; other `src/`
  directories contain Sowa-owned package payloads.
- `docs/` is the operator and contributor documentation. Installed manual
  pages and guides also live under `src/` and `rootfs-overlay/`.
- `docker/` defines the containerized build environment and container image
  workflow.
- `website/` holds static site variants, `assets/` holds project imagery, and
  `todo/` holds future-work notes.
- `work/`, `downloads/`, `artifacts/`, and `dist/` are generated or fetched and
  ignored by Git. Never edit them as the source of a fix.

## Working rules

- Preserve the explicit cross-build boundary. Use `${TARGET}` tools and the
  target sysroot in package recipes; do not let configure or pkg-config discover
  optional features from the host.
- Keep builds deterministic. Sources must be pinned in `config/sources.lock`,
  verified by SHA-256, and unpacked through the existing helpers. Put necessary
  upstream changes in `patches/`, not in extracted trees below `work/`.
- Stage scripts use `#!/usr/bin/env bash`, `set -Eeuo pipefail`, quoted
  expansions, and existing helpers from `scripts/lib/common.sh`. Keep stage
  scripts executable (mode 0755). Add narrow, explained ShellCheck suppressions
  only when required.
- Treat a stage's keyed stamp as part of correctness. If dependency or output
  behavior changes, update the dependency graph and reverse invalidation edges
  in `scripts/build.sh`; do not work around stale output by deleting arbitrary
  files from `work/`. Inspect identity with
  `make stage-key STAGE=packages/<name>`.
- Package into a private staging tree with `pkg_stage`, verify the staged
  binaries, paths, modes, links, ELF dependencies, and absence of build-path
  leaks, then call `pkg_merge`. Follow nearby recipes rather than bypassing
  package ownership helpers.
- Keep code style local. C sources use C11 and warning flags from their local
  Makefiles; build them with those Makefiles. Python code should remain
  dependency-free unless the package design explicitly changes.
- Update documentation, manual pages, completions, examples, and installed
  `/root/sowa-howto/` text when user-visible behavior or interfaces change.
  Manual pages use mdoc(7).
- Preserve existing user changes and file modes. Do not run destructive cleanup
  merely to obtain a clean build.

## Package changes

Adding or renaming a package is a coordinated change. Follow the complete
checklist in `docs/adding-a-package.md`; at minimum update all applicable parts:

1. `config/sources.lock` and `config/upstreams.conf`.
2. `config/packages.conf` and `config/licenses.conf` in matching order.
3. An executable `scripts/stages/packages/<name>.sh` recipe.
4. The dependency helper, rootfs reachability, dispatch, and usage text in
   `scripts/build.sh`, including reverse invalidation for every linked library.
5. The `.PHONY` entry, help text, and recipe in `Makefile`.
6. Presence/profile assertions in `scripts/stages/image/10-rootfs.sh`.

For a daemon, also provide the appropriate init script and lifecycle hooks.
Optional-package services must be disabled by default. Keep ordinary commands
under `/usr/bin` or `/usr/sbin`; `/bin` has a deliberately enforced minimal
allowlist in `scripts/stages/image/10-rootfs.sh`.

Never rely on optional-feature autodetection. Explicitly disable integrations
the image does not ship, and inspect target binaries with `${TARGET}-readelf`.
Package recipes should fail early when an expected file, mode, link, symbol,
interpreter, or `NEEDED` library differs from the intended result.

## Validation

Use the narrowest relevant checks while iterating, then run the repository
check before handing off:

```sh
make check
```

This runs the host prerequisite check, Bash syntax checks, metadata/graph
validators, and the self-tests. ShellCheck runs only when it is installed;
confirm `command -v shellcheck` before treating a green `make check` as
ShellCheck coverage. The ELF dependency/invalidation audit uses existing
package staging trees when available, so a fresh checkout cannot exercise that
part.

Useful focused checks are:

```sh
./scripts/lint.sh
make selftest
python3 scripts/check-updates.py --validate
python3 src/sowa-monitor/test_sowa_monitor.py
make -C src/init
make -C src/liveinit
```

For a package or image change, validate progressively as appropriate:

```sh
make <package>
make rootfs
make packages
make image
make iso
make run-qemu
```

Full toolchain, image, and QEMU checks can be expensive. Run what the change
justifies and state clearly which expensive or environment-dependent checks
were not run. Use `docker/sowa-env.sh run <command>` when the documented host
environment is unavailable.

`make fetch` and the networked `make check-updates` require network access. The
offline `python3 scripts/check-updates.py --validate` checks upstream metadata
and is already part of `make check`. The networked update check is
informational and must not silently change pinned inputs.

## Sensitive and destructive operations

- Never commit private release or repository keys. Only public keys belong in
  `keys/`; `keys/*.key` is intentionally ignored.
- Release signing, repository publication, image pushing, and disk installation
  affect external state and require explicit user intent.
- `release-key.sh` and `repo-key.sh` mint signing keys. Both refuse to replace
  an existing key without `--force`; never pass it unprompted, because a
  replaced repository key invalidates every image already built.
- `make clean` removes build state and artifacts; `make distclean` also removes
  downloaded and extracted sources. Do not run either unless cleanup is part of
  the task or is explicitly approved.
