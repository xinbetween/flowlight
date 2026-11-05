#!/usr/bin/env python3
"""Require reviewed exact-commit CI evidence before a release consumes signing credentials."""

import argparse
import json
import pathlib
import sys


REQUIRED_CHECKS = (
    ("github-actions", "changes"),
    ("github-actions", "site"),
    ("github-actions", "unit (oldest Xcode)"),
    ("github-actions", "unit (newest Xcode)"),
    ("github-actions", "Review / gate"),
    ("github-actions", "CodeQL / gate"),
    ("github-advanced-security", "CodeQL"),
)


def load(path):
    return json.loads(pathlib.Path(path).read_text())


def check_runs(document):
    pages = document if isinstance(document, list) else [document]
    runs = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get("check_runs"), list):
            raise ValueError("check-run response has an unexpected shape")
        runs.extend(page["check_runs"])
    return runs


def pull_requests(document):
    pages = document if isinstance(document, list) else [document]
    pulls = []
    for page in pages:
        if isinstance(page, list):
            pulls.extend(page)
        elif isinstance(page, dict) and "number" in page:
            pulls.append(page)
        else:
            raise ValueError("pull-request response has an unexpected shape")
    return pulls


def verify(repo, sha, checks_document, pulls_document):
    errors = []
    eligible_pulls = []
    for pull in pull_requests(pulls_document):
        head_sha = pull.get("head", {}).get("sha")
        base_ref = pull.get("base", {}).get("ref")
        state = pull.get("state")
        merged = bool(pull.get("merged_at"))
        if head_sha == sha and base_ref == "main" and (state == "open" or merged):
            eligible_pulls.append(pull)
    if not eligible_pulls:
        errors.append(f"commit {sha} has no open or merged pull request targeting main at that exact head")

    latest = {}
    repo_prefix = f"https://github.com/{repo}/"
    for run in check_runs(checks_document):
        app = run.get("app", {}).get("slug")
        name = run.get("name")
        if (app, name) not in REQUIRED_CHECKS:
            continue
        details_url = run.get("details_url", "")
        if not details_url.startswith(repo_prefix):
            continue
        key = (app, name)
        if int(run.get("id", 0)) > int(latest.get(key, {}).get("id", 0)):
            latest[key] = run

    for key in REQUIRED_CHECKS:
        run = latest.get(key)
        label = f"{key[1]} ({key[0]})"
        if not run:
            errors.append(f"missing required check: {label}")
        elif run.get("status") != "completed" or run.get("conclusion") != "success":
            errors.append(
                f"required check is not successful: {label} "
                f"status={run.get('status')} conclusion={run.get('conclusion')}"
            )

    if errors:
        return errors, []
    return [], [int(pull["number"]) for pull in eligible_pulls]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--checks", type=pathlib.Path, required=True)
    parser.add_argument("--pulls", type=pathlib.Path, required=True)
    args = parser.parse_args()

    try:
        errors, pull_numbers = verify(args.repo, args.sha, load(args.checks), load(args.pulls))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"release check evidence could not be read: {error}", file=sys.stderr)
        return 1

    if errors:
        for error in errors:
            print(f"release check rejected: {error}", file=sys.stderr)
        return 1

    joined = ", ".join(f"#{number}" for number in pull_numbers)
    print(f"Exact commit {args.sha} has reviewed release evidence from {joined} and all required checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
