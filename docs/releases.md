# Release authenticity

The files under `artifacts/` have adjacent `.sha256` files for convenient
copy/media checks. Those checksums are not provenance: a mirror that replaces
an ISO can replace the checksum beside it. A Sowa release is authenticated by
one signed manifest covering the exact filename, byte size and SHA-256 of every
artifact in the release set.

The release key is deliberately separate from the package-repository key. The
repository key signs short-lived update metadata on an online publishing path;
the release key is an offline trust root for boot media, installers, rootfs
tarballs, disk images and container archives that may remain mirrored for
years.

## Creating the key

Once, on the machine that will hold the offline private key:

```sh
make release-key
```

The defaults are:

| File | Purpose |
| --- | --- |
| `~/.config/sowa/release-ed25519.key` | private Ed25519 key; mode 0600, outside the checkout |
| `keys/sowa-release.pub` | public key to commit and distribute independently |

`RELEASE_KEY` and `RELEASE_PUBLIC_KEY` override those paths. The key command
refuses to put the private half anywhere below the checkout. Back the private
key up offline; publish the public key and its printed SHA-256 fingerprint
through a channel independent of the artifact mirror.

`make release-key` will not silently replace a key. `--force` is available on
`scripts/release-key.sh`, but rotating a release key is a trust-root change:
retain the old public key for as long as any old artifact is available, and
announce the new fingerprint using the old trusted channel.

## Signing artifacts

Build whichever forms belong to the release, then sign the set already present
in `artifacts/`:

```sh
make iso
make rootfs-tarball
make disk-image
make installer-bundle
make docker-image
make recovery-image
make release-manifest
```

The result is:

```text
artifacts/sowa-0.1-x86_64-release.manifest
artifacts/sowa-0.1-x86_64-release.manifest.sig
```

The manifest covers every current Sowa artifact in that directory, including
uncompressed disk images when they are retained. It also records the
distribution/version/architecture, the exact Git revision, whether the tree
was dirty, the reproducible creation time, and the public-key fingerprint.
Signing refuses a dirty checkout by default, an empty or symbolic-link
artifact, a group-readable private key, or a public key that does not match the
private half. `scripts/release-manifest.sh --allow-dirty` exists for development
tests; a manifest produced that way says `dirty|1` inside the signed bytes.

Copy artifacts first and the manifest/signature pair last when publishing a
static release directory. The pair is meaningful only after every file it
names is available.

## Verifying a download

Start with a public key whose fingerprint was obtained independently. From a
trusted source checkout, verify the complete downloaded release set:

```sh
./scripts/verify-release.sh \
    --key keys/sowa-release.pub \
    artifacts/sowa-0.1-x86_64-release.manifest
```

Most users download only one representation. Name those files after the
manifest to verify a subset without requiring every other artifact:

```sh
./scripts/verify-release.sh \
    --key keys/sowa-release.pub \
    artifacts/sowa-0.1-x86_64-release.manifest \
    artifacts/sowa-0.1-x86_64.iso
```

The verifier authenticates the manifest before parsing any filename from it,
checks the signed key fingerprint and metadata grammar, rejects duplicate or
non-basename artifact names, then checks both size and SHA-256. Artifacts must
be regular files beside the manifest; symbolic links and paths into another
directory are refused. `make verify-release` is the no-argument form when one
manifest and the public key are in their default checkout locations.

Before installing from another operating system, verify both executable/input
artifacts before running or extracting either one:

```sh
./scripts/verify-release.sh --key sowa-release.pub \
    sowa-0.1-x86_64-release.manifest \
    sowa-install sowa-0.1-x86_64-rootfs.tar.xz
./sowa-install bootstrap --from-tarball \
    sowa-0.1-x86_64-rootfs.tar.xz /mnt
```

OpenSSL can verify the detached signature directly when the helper is not
available:

```sh
openssl pkeyutl -verify -rawin -pubin -inkey sowa-release.pub \
    -in sowa-0.1-x86_64-release.manifest \
    -sigfile sowa-0.1-x86_64-release.manifest.sig
```

The manifest then supplies the expected SHA-256 and size for the downloaded
file. Do not treat a public key fetched from the same untrusted mirror in the
same session as independent authentication.

## Boot-time checking and its limit

The normal ISO entry asks `liveinit` to hash `root.sfs` before mounting it. That
detects a damaged USB stick or optical disc early; the explicit “skip medium
verification” entry is the slow-media escape hatch. The checksum stored inside
the same ISO cannot authenticate that ISO. Authenticity comes from verifying
the external signed release manifest before writing or booting it.

This is not Secure Boot. Firmware, GRUB, the kernel and initramfs still have no
machine-enforced authenticated chain, so someone able to modify an installed
disk offline can change its boot path. A signed UKI or verified
firmware-to-userspace GRUB chain, with enrollment/revocation/recovery design,
remains separate work.
