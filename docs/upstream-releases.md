# Upstream releases and source mirrors

The package catalogue points each third-party package at a row in
[`config/sources.lock`](../config/sources.lock). That lock is immutable build
input: it gives the exact version, archive name, primary URL, SHA-256 and
extraction directory. Two companion tables answer questions that should not
change a build's identity:

- [`config/upstreams.conf`](../config/upstreams.conf) gives every locked source
  a human-facing changelog, release page or canonical download index, plus the
  machine-readable release check where one is reliable.
- [`config/mirrors.conf`](../config/mirrors.conf) gives alternate transports for
  the same locked bytes.

Packages whose `source` field is `-` in `config/packages.conf` are Sowa-native
components versioned with the distribution. Auxiliary inputs such as Bash
patches and GnuPG libraries have their own upstream rows even though they are
not separate binary packages.

## Checking for updates

Run the networked check with:

```sh
make check-updates
```

The result shows the pinned version, newest stable version found, status and a
clickable release page. `OUTDATED` is informational by default, so an
interactive review can find several updates in one run without the command
being treated as broken. Operational errors return status 2. For CI that must
fail when anything is old, use:

```sh
./scripts/check-updates.py --fail-on-outdated
```

Useful narrower and machine-readable forms are:

```sh
./scripts/check-updates.py --source openssl --source curl
./scripts/check-updates.py --json
GITHUB_TOKEN=... ./scripts/check-updates.py --jobs 12
```

The token is optional and only raises GitHub API rate limits. Checks run in
parallel, default to a 20-second timeout per request, ignore GitHub drafts and
prereleases, and constrain projects such as Perl, GLib and BIND to their stable
release channels. An `ahead` result means the lock is newer than the
discoverable upstream feed and deserves review just as much as `OUTDATED`.

Some rows say `manual`: those upstreams publish no dependable structured feed,
or the row is one file in a set already covered by an aggregate check. Their
release-page link is still always present. `make check` validates that every
source has exactly one row and that automated coverage remains a majority; it
does not access the network.

The checker deliberately does not edit `sources.lock`. Updating a source also
requires reviewing release notes, downloading the intended archive, recording
its SHA-256, checking licence/recipe changes and building it. Discovery is safe
to automate; accepting new build input is a maintainer decision.

## Fetching and fallback

`make fetch` tries the primary URL from the lock and then every matching mirror
rule in table order. Each candidate has to produce the same locked SHA-256, so
a mirror cannot silently select a different release. A failed request or a
checksum mismatch moves to the next candidate; the script fails only when all
candidates are exhausted.

Fetch output identifies the attempted URL and, for a completed transfer, the
effective URL after redirects, HTTP status, content type, byte and human sizes,
elapsed time, average rate and full SHA-256. A previously downloaded archive
gets the same size and digest summary without another request.

GNU sources currently use ICM as their primary URL. The first fallback is
[`mirrors.kernel.org/gnu`](https://mirrors.kernel.org/gnu/), which is direct and
responded reliably during this change. GNU's official geo-aware
[`ftpmirror.gnu.org`](https://ftpmirror.gnu.org/) redirector and
[`ftp.gnu.org`](https://ftp.gnu.org/gnu/) follow it. Prefix rules also cover the
kernel.org CDN and Debian. Add another `prefix` rule when a server exposes the
same directory tree, or a `source` rule with a complete URL for one exceptional
archive. The primary and all mirrors must use HTTPS. A connection gets 20
seconds by default; a transfer below 1 KiB/s for 30 seconds is abandoned so a
server that accepts a connection and then stalls cannot prevent fallback.
