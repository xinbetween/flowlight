#!/usr/bin/env python3
"""Require reviewed exact-commit CI evidence before a release consumes signing credentials."""

import argparse
import json
import pathlib
import re
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
EXPECTED_ACTIONS_WORKFLOWS = {
    ("github-actions", "changes"): ".github/workflows/ci.yml",
    ("github-actions", "site"): ".github/workflows/ci.yml",
    ("github-actions", "unit (oldest Xcode)"): ".github/workflows/ci.yml",
    ("github-actions", "unit (newest Xcode)"): ".github/workflows/ci.yml",
    ("github-actions", "Review / gate"): ".github/workflows/ci.yml",
    ("github-actions", "CodeQL / gate"): ".github/workflows/codeql.yml",
}


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


def workflow_runs(document):
    pages = document if isinstance(document, list) else [document]
    runs = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get("workflow_runs"), list):
            raise ValueError("workflow-run response has an unexpected shape")
        runs.extend(page["workflow_runs"])
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


def issue_comments(document):
    pages = document if isinstance(document, list) else [document]
    comments = []
    for page in pages:
        if not isinstance(page, list):
            raise ValueError("issue-comment response has an unexpected shape")
        comments.extend(page)
    return comments


def select_checks(repo, sha, checks_document, runs_document, reviewed_pull_numbers=None):
    actions_runs = {int(run.get("id", 0)): run for run in workflow_runs(runs_document)}
    latest = {}
    provenance = {}
    repo_prefix = f"https://github.com/{repo}/"
    run_url = re.compile(rf"^https://github\.com/{re.escape(repo)}/actions/runs/([0-9]+)(?:/.*)?$")
    for check in check_runs(checks_document):
        key = (check.get("app", {}).get("slug"), check.get("name"))
        if key not in REQUIRED_CHECKS:
            continue
        details_url = check.get("details_url", "")
        if not details_url.startswith(repo_prefix):
            continue
        workflow = None
        if key in EXPECTED_ACTIONS_WORKFLOWS:
            match = run_url.fullmatch(details_url)
            if not match:
                continue
            workflow = actions_runs.get(int(match.group(1)))
            if not workflow:
                continue
            if workflow.get("path") != EXPECTED_ACTIONS_WORKFLOWS[key]:
                continue
            if workflow.get("head_sha") != sha or workflow.get("event") != "pull_request":
                continue
            if workflow.get("repository", {}).get("full_name") != repo:
                continue
            if reviewed_pull_numbers is not None:
                linked_pulls = workflow.get("pull_requests")
                linked_pull = next((
                    pull for pull in linked_pulls
                    if isinstance(pull, dict)
                    and pull.get("number") in reviewed_pull_numbers
                    and pull.get("head", {}).get("sha") == sha
                    and pull.get("base", {}).get("ref") == "main"
                ), None) if isinstance(linked_pulls, list) else None
                if linked_pull is None:
                    continue
                workflow = dict(workflow)
                workflow["_reviewed_pull_number"] = int(linked_pull["number"])
        if int(check.get("id", 0)) > int(latest.get(key, {}).get("id", 0)):
            latest[key] = check
            provenance[key] = workflow
    return latest, provenance


def verify(repo, sha, checks_document, pulls_document, runs_document, comments_document, trusted_reviewers):
    errors = []
    associated_pulls = []
    review_marker = f"Reviewed-Commit: {sha}"
    trusted_reviewers = {value.lower() for value in re.split(r"[\s,]+", trusted_reviewers) if value}
    if not trusted_reviewers:
        errors.append("no trusted release reviewers are configured")
    for pull in pull_requests(pulls_document):
        head_sha = pull.get("head", {}).get("sha")
        base_ref = pull.get("base", {}).get("ref")
        state = pull.get("state")
        merged = bool(pull.get("merged_at"))
        if head_sha == sha and base_ref == "main" and (state == "open" or merged):
            associated_pulls.append(pull)
    if not associated_pulls:
        errors.append("exact source commit has no open or merged pull request targeting main at that exact head")

    associated_numbers = {int(pull["number"]) for pull in associated_pulls}
    receipts = []
    issue_url = re.compile(rf"^https://api\.github\.com/repos/{re.escape(repo)}/issues/([0-9]+)$")
    for comment in issue_comments(comments_document):
        if not isinstance(comment, dict):
            continue
        match = issue_url.fullmatch(comment.get("issue_url", ""))
        if not match or int(match.group(1)) not in associated_numbers:
            continue
        pull_number = int(match.group(1))
        body = comment.get("body")
        body_lines = {line.strip() for line in body.splitlines()} if isinstance(body, str) else set()
        user = comment.get("user")
        reviewer = user.get("login") if isinstance(user, dict) else None
        if review_marker not in body_lines or not isinstance(reviewer, str) or reviewer.lower() not in trusted_reviewers:
            continue
        # `author_association` is viewer-dependent when organization membership is
        # private: the release GITHUB_TOKEN can report CONTRIBUTOR for the same
        # comment an organization member sees as MEMBER. The configured reviewer
        # allowlist is the authorization boundary; GitHub's comment identity, URL,
        # numeric ID, exact PR, and exact commit marker authenticate the receipt.
        association = comment.get("author_association")
        comment_id = comment.get("id")
        html_url = comment.get("html_url")
        if not isinstance(association, str) or not association:
            continue
        if not isinstance(comment_id, int) or isinstance(comment_id, bool) or comment_id <= 0:
            continue
        expected_url = f"https://github.com/{repo}/pull/{pull_number}#issuecomment-{comment_id}"
        if html_url != expected_url:
            continue
        receipts.append({
            "pull_request": pull_number,
            "comment_id": comment_id,
            "reviewer": reviewer,
            "author_association": association,
            "reviewed_commit": sha,
            "url": html_url,
        })
    receipts.sort(key=lambda receipt: receipt["comment_id"])
    if len({receipt["comment_id"] for receipt in receipts}) != len(receipts):
        errors.append("authenticated review comments contain duplicate comment IDs")
    if associated_pulls and not receipts:
        errors.append(
            "no authenticated exact-head review comment from a configured trusted reviewer"
        )

    reviewed_pull_numbers = {receipt["pull_request"] for receipt in receipts}
    latest, provenance = select_checks(
        repo, sha, checks_document, runs_document, reviewed_pull_numbers
    )
    for key in REQUIRED_CHECKS:
        check = latest.get(key)
        label = f"{key[1]} ({key[0]})"
        if not check:
            errors.append(f"missing required check from its trusted workflow: {label}")
            continue
        if check.get("status") != "completed" or check.get("conclusion") != "success":
            errors.append(
                f"required check is not successful: {label} "
                f"status={check.get('status')} conclusion={check.get('conclusion')}"
            )
        workflow = provenance.get(key)
        if workflow and (workflow.get("status") != "completed" or workflow.get("conclusion") != "success"):
            errors.append(
                f"trusted workflow run is not successful: {label} "
                f"status={workflow.get('status')} conclusion={workflow.get('conclusion')}"
            )

    if errors:
        return errors, [], []
    return [], sorted(associated_numbers), receipts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--checks", type=pathlib.Path, required=True)
    parser.add_argument("--pulls", type=pathlib.Path, required=True)
    parser.add_argument("--runs", type=pathlib.Path, required=True)
    parser.add_argument("--comments", type=pathlib.Path, required=True)
    parser.add_argument("--reviewers", required=True,
                        help="comma- or whitespace-separated trusted GitHub reviewer logins")
    parser.add_argument("--evidence-output", type=pathlib.Path)
    args = parser.parse_args()

    try:
        checks_document = load(args.checks)
        runs_document = load(args.runs)
        errors, pull_numbers, review_receipts = verify(
            args.repo,
            args.sha,
            checks_document,
            load(args.pulls),
            runs_document,
            load(args.comments),
            args.reviewers,
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"release check evidence could not be read: {error}", file=sys.stderr)
        return 1

    if errors:
        for error in errors:
            print(f"release check rejected: {error}", file=sys.stderr)
        return 1

    if args.evidence_output:
        latest, provenance = select_checks(
            args.repo,
            args.sha,
            checks_document,
            runs_document,
            {receipt["pull_request"] for receipt in review_receipts},
        )
        evidence = {
            "repository": args.repo,
            "source_sha": args.sha,
            "pull_requests": pull_numbers,
            "review_receipts": review_receipts,
            "checks": [
                {
                    "app": app,
                    "name": name,
                    "id": int(latest[(app, name)]["id"]),
                    "details_url": latest[(app, name)]["details_url"],
                    "workflow": provenance[(app, name)]["path"] if provenance.get((app, name)) else None,
                    "workflow_run_id": int(provenance[(app, name)]["id"]) if provenance.get((app, name)) else None,
                    "pull_request": provenance[(app, name)]["_reviewed_pull_number"] if provenance.get((app, name)) else None,
                }
                for app, name in REQUIRED_CHECKS
            ],
        }
        args.evidence_output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")

    joined = ", ".join(f"#{number}" for number in pull_numbers)
    reviewers = ", ".join(sorted({receipt["reviewer"] for receipt in review_receipts}))
    print(
        f"Exact commit {args.sha} has authenticated review evidence from {reviewers} "
        f"on {joined} and all required checks passed."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
