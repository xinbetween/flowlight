#!/usr/bin/env python3
"""Classify a Git change without letting an unknown path skip app verification.

The website-only route is deliberately an allowlist. Every path Git reports for a
rename or copy is classified, and anything malformed or unfamiliar takes the full
application route. The same policy also produces the app-input fingerprint that a
later workflow can use to prove two commits have equivalent build inputs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
from dataclasses import asdict, dataclass


SCHEMA = "flowlight-review-v2"

SITE_ONLY_EXACT = frozenset(
    {
        "CNAME",
        "CONTRIBUTING.md",
        "LICENSE",
        "README.md",
        "SECURITY.md",
        "product.md",
        "scripts/build_site.py",
        "scripts/check_site.py",
        "site/site.css",
    }
)

SITE_ONLY_PREFIXES = (
    "docs/",
    "site/i18n/",
    "site/pages/",
    "site/partials/",
)

# Checked before the site allowlist. These files can sit inside a website-looking
# directory while still changing signed policy, release claims, or screenshot gates.
FULL_ROUTE_EXACT = frozenset(
    {
        "docs/assets/screenshots/manifest.json",
        "site/pages/releases.html",
    }
)

FULL_ROUTE_PREFIXES = (
    ".github/",
    "Flowlight/",
    "Flowlight.xcodeproj/",
    "FlowlightExtension/",
    "FlowlightResponseScriptHelper/",
    "FlowlightTests/",
    "Shared/",
    "ci_scripts/",
    "docs/packs/",
    "packaging/",
    "rule-packs/",
    "site/packs/",
)

FULL_ROUTE_SCRIPT_EXACT = frozenset(
    {
        "project.yml",
        "scripts/app-store-screenshots.sh",
        "scripts/build-dmg.sh",
        "scripts/build-pkg.sh",
        "scripts/build-signed.sh",
        "scripts/check_app_store_product.sh",
        "scripts/check_release_checks.py",
        "scripts/check_xcode_project.sh",
        "scripts/classify_changes.py",
        "scripts/notarize.sh",
        "scripts/normalize_xcode_project.py",
        "scripts/rule_pack_catalog.py",
        "scripts/screenshot_manifest.py",
        "scripts/screenshots.sh",
        "scripts/test_classify_changes.py",
        "scripts/test_release_checks.py",
        "scripts/update-cask.sh",
    }
)


@dataclass(frozen=True)
class Classification:
    app: bool
    site: bool
    python: bool
    actions: bool
    pages: bool
    site_only: bool
    reason: str
    paths: tuple[str, ...]
    head_sha: str
    tree: str
    app_fingerprint: str
    schema: str = SCHEMA


def git(repo: pathlib.Path, *arguments: str) -> bytes:
    return subprocess.run(
        ["git", "-C", os.fspath(repo), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout


def safe_relative_path(raw: str) -> str | None:
    if not raw or raw.startswith("/") or "\\" in raw:
        return None
    parts = pathlib.PurePosixPath(raw).parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        return None
    return "/".join(parts)


def is_site_only_path(raw: str) -> bool:
    path = safe_relative_path(raw)
    if path is None:
        return False
    if path in FULL_ROUTE_EXACT or path in FULL_ROUTE_SCRIPT_EXACT:
        return False
    if path.startswith(FULL_ROUTE_PREFIXES):
        return False
    if path in SITE_ONLY_EXACT:
        return True
    return path.startswith(SITE_ONLY_PREFIXES)


def parse_name_status(payload: bytes) -> tuple[str, ...]:
    fields = payload.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    paths: list[str] = []
    index = 0
    while index < len(fields):
        status = os.fsdecode(fields[index])
        index += 1
        if not status or status[0] not in "ACDMRTUXB":
            raise ValueError(f"unexpected Git diff status: {status!r}")
        count = 2 if status[0] in "RC" else 1
        if index + count > len(fields):
            raise ValueError(f"truncated Git diff record for {status!r}")
        for _ in range(count):
            path = os.fsdecode(fields[index])
            index += 1
            if safe_relative_path(path) is None:
                raise ValueError(f"unsafe or malformed Git path: {path!r}")
            paths.append(path)
    return tuple(dict.fromkeys(paths))


def changed_paths(repo: pathlib.Path, base: str, head: str) -> tuple[str, ...]:
    git(repo, "cat-file", "-e", f"{base}^{{commit}}")
    git(repo, "cat-file", "-e", f"{head}^{{commit}}")
    return parse_name_status(
        git(repo, "diff", "--name-status", "-z", "--find-renames", base, head, "--")
    )


def app_fingerprint(repo: pathlib.Path, head: str) -> str:
    digest = hashlib.sha256()
    digest.update(f"{SCHEMA}\0".encode())
    records = git(repo, "ls-tree", "-r", "-z", head).split(b"\0")
    for record in records:
        if not record:
            continue
        metadata, separator, raw_path = record.partition(b"\t")
        if not separator:
            raise ValueError("unexpected git ls-tree record")
        path = os.fsdecode(raw_path)
        if is_site_only_path(path):
            continue
        digest.update(raw_path)
        digest.update(b"\0")
        digest.update(metadata)
        digest.update(b"\0")
    return digest.hexdigest()


def classify(repo: pathlib.Path, base: str | None, head: str) -> Classification:
    resolved_head = git(repo, "rev-parse", f"{head}^{{commit}}").decode().strip()
    tree = git(repo, "rev-parse", f"{resolved_head}^{{tree}}").decode().strip()
    fingerprint = app_fingerprint(repo, resolved_head)

    fail_closed = False
    if not base or base == "0" * 40:
        paths: tuple[str, ...] = ()
        app = True
        fail_closed = True
        reason = "No trustworthy base commit was supplied; using every verification route."
    else:
        try:
            paths = changed_paths(repo, base, resolved_head)
        except (OSError, subprocess.CalledProcessError, ValueError) as error:
            paths = ()
            app = True
            fail_closed = True
            reason = f"Comparison failed closed to every verification route: {error}"
        else:
            app = not paths or any(not is_site_only_path(path) for path in paths)
            reason = (
                "Every changed path is explicitly approved for website-only verification."
                if not app
                else "At least one changed path requires full application verification."
            )

    return Classification(
        app=app,
        site=True,
        python=fail_closed or any(path.endswith(".py") for path in paths),
        actions=fail_closed or any(path.startswith(".github/") for path in paths),
        pages=any(path.startswith(("docs/", "site/")) for path in paths),
        site_only=not app,
        reason=reason,
        paths=paths,
        head_sha=resolved_head,
        tree=tree,
        app_fingerprint=fingerprint,
    )


def write_github_output(path: pathlib.Path, result: Classification) -> None:
    values = asdict(result)
    with path.open("a", encoding="utf-8") as output:
        for key in ("app", "site", "python", "actions", "pages", "site_only"):
            output.write(f"{key}={'true' if values[key] else 'false'}\n")
        output.write(f"head_sha={result.head_sha}\n")
        output.write(f"tree={result.tree}\n")
        output.write(f"fingerprint={result.app_fingerprint}\n")
        output.write(f"schema={result.schema}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--base")
    parser.add_argument("--head", required=True)
    parser.add_argument("--github-output", type=pathlib.Path)
    args = parser.parse_args()

    try:
        result = classify(args.repo.resolve(), args.base, args.head)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"change classification failed: {error}", file=sys.stderr)
        return 1

    if args.github_output:
        write_github_output(args.github_output, result)
    json.dump(asdict(result), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
