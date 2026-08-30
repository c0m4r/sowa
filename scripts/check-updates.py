#!/usr/bin/env python3
"""Compare pinned source versions with upstream release data."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
LOCK_FILE = Path(os.environ.get("LOCK_FILE", ROOT / "config/sources.lock"))
UPSTREAMS_FILE = Path(
    os.environ.get("UPSTREAMS_FILE", ROOT / "config/upstreams.conf")
)
USER_AGENT = "sowa-update-check/1 (+https://github.com/c0m4r/sowa)"


@dataclass(frozen=True)
class Upstream:
    name: str
    release_page: str
    method: str
    location: str
    pattern: str


@dataclass
class Result:
    name: str
    current: str
    latest: str
    status: str
    release_page: str
    detail: str = ""


def read_table(path: Path, fields: int) -> list[list[str]]:
    rows: list[list[str]] = []
    with path.open(encoding="utf-8") as table:
        for line_number, raw in enumerate(table, 1):
            line = raw.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            row = line.split("|")
            if len(row) != fields:
                raise ValueError(
                    f"{path}:{line_number}: expected {fields} fields, got {len(row)}"
                )
            rows.append(row)
    return rows


def version_key(version: str) -> tuple[tuple[int, Any], ...]:
    """A predictable natural ordering for the version styles in sources.lock."""
    parts: list[tuple[int, Any]] = []
    for token in re.findall(r"[0-9]+|[A-Za-z]+", version):
        if token.isdigit():
            parts.append((1, int(token)))
        else:
            parts.append((0, token.casefold()))
    return tuple(parts)


def extract_version(match: re.Match[str]) -> str:
    try:
        return match.group("version")
    except IndexError:
        if match.lastindex:
            return match.group(1)
        return match.group(0)


def request(url: str, timeout: float, github_token: str | None = None) -> bytes:
    headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
    if github_token:
        headers["Authorization"] = f"Bearer {github_token}"
        headers["X-GitHub-Api-Version"] = "2022-11-28"
    with urllib.request.urlopen(  # noqa: S310 - locations are repository data
        urllib.request.Request(url, headers=headers), timeout=timeout
    ) as response:
        return response.read()


def newest(values: list[str], name: str) -> str:
    versions = sorted(set(values), key=version_key)
    if not versions:
        raise ValueError(f"upstream data contained no stable version matching {name}")
    return versions[-1]


def check_one(
    upstream: Upstream,
    current: str,
    timeout: float,
    github_token: str | None,
) -> str:
    if upstream.method == "bash":
        body = request(upstream.location, timeout).decode("utf-8", "replace")
        series = newest(
            re.findall(r"bash-([0-9]+[.][0-9]+)[.]tar[.]gz", body), upstream.name
        )
        patch_url = f"{upstream.location.rstrip('/')}/bash-{series}-patches/"
        patch_body = request(patch_url, timeout).decode("utf-8", "replace")
        compact_series = series.replace(".", "")
        patches = re.findall(rf"bash{re.escape(compact_series)}-([0-9]{{3}})", patch_body)
        return f"{series}.{max((int(patch) for patch in patches), default=0)}"

    matcher = re.compile(upstream.pattern)
    if upstream.method == "html":
        body = request(upstream.location, timeout).decode("utf-8", "replace")
        return newest([extract_version(match) for match in matcher.finditer(body)], upstream.name)

    if upstream.method in {"github-release", "github-tag"}:
        if upstream.method == "github-release":
            endpoint = f"https://api.github.com/repos/{upstream.location}/releases?per_page=100"
            records = json.loads(request(endpoint, timeout, github_token))
            tags = [
                record["tag_name"]
                for record in records
                if not record.get("draft") and not record.get("prerelease")
            ]
        else:
            endpoint = f"https://api.github.com/repos/{upstream.location}/tags?per_page=100"
            records = json.loads(request(endpoint, timeout, github_token))
            tags = [record["name"] for record in records]
        return newest(
            [extract_version(match) for tag in tags if (match := matcher.fullmatch(tag))],
            upstream.name,
        )

    raise ValueError(f"unsupported check method {upstream.method!r}")


def classify(current: str, latest: str) -> str:
    if current == latest:
        return "current"
    if version_key(current) < version_key(latest):
        return "OUTDATED"
    return "ahead"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="compare config/sources.lock with authoritative upstream releases"
    )
    parser.add_argument(
        "--source",
        action="append",
        default=[],
        metavar="NAME",
        help="check only this source (repeatable)",
    )
    parser.add_argument("--jobs", type=int, default=8, help="parallel requests (default: 8)")
    parser.add_argument(
        "--timeout", type=float, default=20.0, help="timeout for each request in seconds"
    )
    parser.add_argument("--json", action="store_true", help="write machine-readable JSON")
    parser.add_argument(
        "--validate",
        action="store_true",
        help="validate metadata without making network requests",
    )
    parser.add_argument(
        "--fail-on-outdated",
        action="store_true",
        help="exit with status 1 if a newer release is found",
    )
    return parser.parse_args()


def validate_metadata(locked: dict[str, str], upstreams: dict[str, Upstream]) -> None:
    methods = {"alias", "bash", "github-release", "github-tag", "html", "manual"}
    missing = sorted(set(locked) - set(upstreams))
    extra = sorted(set(upstreams) - set(locked))
    if missing:
        raise ValueError(f"sources without upstream metadata: {', '.join(missing)}")
    if extra:
        raise ValueError(f"upstream metadata for unknown sources: {', '.join(extra)}")

    automated = 0
    for upstream in upstreams.values():
        if upstream.method not in methods:
            raise ValueError(f"{upstream.name}: unknown method {upstream.method!r}")
        if not upstream.release_page.startswith("https://"):
            raise ValueError(f"{upstream.name}: release page must use HTTPS")
        if upstream.method == "alias":
            if upstream.location not in upstreams:
                raise ValueError(
                    f"{upstream.name}: alias target {upstream.location!r} does not exist"
                )
            if upstream.location == upstream.name:
                raise ValueError(f"{upstream.name}: alias points to itself")
            automated += 1
        elif upstream.method == "manual":
            if upstream.pattern != "-":
                raise ValueError(f"{upstream.name}: manual record must use '-' pattern")
        elif upstream.method == "bash":
            if not upstream.location.startswith("https://") or upstream.pattern != "-":
                raise ValueError(f"{upstream.name}: invalid bash release check")
            automated += 1
        else:
            if upstream.method.startswith("github-"):
                if not re.fullmatch(r"[^/]+/[^/]+", upstream.location):
                    raise ValueError(f"{upstream.name}: invalid GitHub repository")
            elif not upstream.location.startswith("https://"):
                raise ValueError(f"{upstream.name}: check location must use HTTPS")
            try:
                matcher = re.compile(upstream.pattern)
            except re.error as error:
                raise ValueError(f"{upstream.name}: invalid version pattern: {error}") from error
            if "version" not in matcher.groupindex and matcher.groups != 1:
                raise ValueError(
                    f"{upstream.name}: pattern needs one capture or a named version group"
                )
            automated += 1

    # This is a policy promise, not merely a statistic in the documentation:
    # metadata additions cannot quietly turn automated coverage into a minority.
    if automated * 2 <= len(upstreams):
        raise ValueError(
            f"only {automated}/{len(upstreams)} sources have automated release checks"
        )


def main() -> int:
    args = parse_arguments()
    if args.jobs < 1:
        raise ValueError("--jobs must be at least 1")
    if args.timeout <= 0:
        raise ValueError("--timeout must be greater than zero")

    locked = {row[0]: row[1] for row in read_table(LOCK_FILE, 6)}
    metadata_rows = read_table(UPSTREAMS_FILE, 5)
    all_upstreams: dict[str, Upstream] = {}
    for row in metadata_rows:
        if row[0] in all_upstreams:
            raise ValueError(f"duplicate upstream metadata for {row[0]}")
        all_upstreams[row[0]] = Upstream(*row)
    validate_metadata(locked, all_upstreams)
    if args.validate:
        print(f"validated {len(all_upstreams)} upstream records")
        return 0

    unknown = sorted(set(args.source) - set(locked))
    if unknown:
        raise ValueError(f"unknown source(s): {', '.join(unknown)}")
    selected = set(args.source) if args.source else set(all_upstreams)
    required = set(selected)
    while True:
        aliases = {
            all_upstreams[name].location
            for name in required
            if all_upstreams[name].method == "alias"
        }
        expanded = required | aliases
        if expanded == required:
            break
        required = expanded
    upstreams = {
        name: upstream
        for name, upstream in all_upstreams.items()
        if name in required
    }

    results: dict[str, Result] = {}
    pending: dict[concurrent.futures.Future[str], Upstream] = {}
    github_token = os.environ.get("GITHUB_TOKEN")
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        for upstream in upstreams.values():
            current = locked[upstream.name]
            if upstream.method == "manual":
                results[upstream.name] = Result(
                    upstream.name,
                    current,
                    "-",
                    "manual",
                    upstream.release_page,
                    upstream.location if upstream.location != "-" else "",
                )
            elif upstream.method != "alias":
                future = executor.submit(
                    check_one, upstream, current, args.timeout, github_token
                )
                pending[future] = upstream

        for future in concurrent.futures.as_completed(pending):
            upstream = pending[future]
            current = locked[upstream.name]
            try:
                latest = future.result()
                results[upstream.name] = Result(
                    upstream.name,
                    current,
                    latest,
                    classify(current, latest),
                    upstream.release_page,
                )
            except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
                results[upstream.name] = Result(
                    upstream.name,
                    current,
                    "-",
                    "ERROR",
                    upstream.release_page,
                    str(error),
                )

    # Aliases are sources released in lockstep with another row (for example,
    # Git's source and manpage archives). Resolve them after network checks so
    # they share both the discovered version and any error honestly.
    unresolved = {name for name, item in upstreams.items() if item.method == "alias"}
    while unresolved:
        progress = False
        for name in sorted(unresolved):
            upstream = upstreams[name]
            target = upstream.location
            if target not in results:
                continue
            target_result = results[target]
            latest = target_result.latest
            status = (
                classify(locked[name], latest)
                if target_result.status not in {"ERROR", "manual"}
                else target_result.status
            )
            results[name] = Result(
                name,
                locked[name],
                latest,
                status,
                upstream.release_page,
                f"released with {target}" if not target_result.detail else target_result.detail,
            )
            unresolved.remove(name)
            progress = True
        if not progress:
            for name in unresolved:
                upstream = upstreams[name]
                results[name] = Result(
                    name,
                    locked[name],
                    "-",
                    "ERROR",
                    upstream.release_page,
                    f"unresolved alias {upstream.location}",
                )
            break

    ordered = [results[name] for name in all_upstreams if name in selected]
    if args.json:
        json.dump([asdict(result) for result in ordered], sys.stdout, indent=2)
        print()
    else:
        widths = {
            "name": max([len("SOURCE"), *(len(result.name) for result in ordered)]),
            "current": max([len("CURRENT"), *(len(result.current) for result in ordered)]),
            "latest": max([len("LATEST"), *(len(result.latest) for result in ordered)]),
            "status": max([len("STATUS"), *(len(result.status) for result in ordered)]),
        }
        print(
            f"{'SOURCE':<{widths['name']}}  {'CURRENT':<{widths['current']}}  "
            f"{'LATEST':<{widths['latest']}}  {'STATUS':<{widths['status']}}  RELEASES"
        )
        for result in ordered:
            print(
                f"{result.name:<{widths['name']}}  {result.current:<{widths['current']}}  "
                f"{result.latest:<{widths['latest']}}  {result.status:<{widths['status']}}  "
                f"{result.release_page}"
            )
            if result.detail and result.status == "ERROR":
                print(f"  {result.name}: {result.detail}", file=sys.stderr)

    errors = any(result.status == "ERROR" for result in ordered)
    outdated = any(result.status == "OUTDATED" for result in ordered)
    if errors:
        return 2
    if args.fail_on_outdated and outdated:
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"check-updates: {error}", file=sys.stderr)
        raise SystemExit(2) from error
