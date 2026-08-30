# Release keys

`make release-key` writes the public release-signing key here as
`sowa-release.pub`. The private half is created outside the checkout at
`~/.config/sowa/release-ed25519.key` by default and must never be committed.

The release key is intentionally separate from the package-repository key.
Commit the public key, publish its SHA-256 fingerprint through an independent
channel, and retain old public keys for as long as artifacts signed by them are
available.
