#!/usr/bin/env python3

import copy
import importlib.util
import pathlib
import sys
import unittest

SCRIPT = pathlib.Path(__file__).with_name("check_release_checks.py")
SPEC = importlib.util.spec_from_file_location("check_release_checks", SCRIPT)
assert SPEC and SPEC.loader
check_release_checks = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = check_release_checks
SPEC.loader.exec_module(check_release_checks)
EXPECTED_ACTIONS_WORKFLOWS = check_release_checks.EXPECTED_ACTIONS_WORKFLOWS
REQUIRED_CHECKS = check_release_checks.REQUIRED_CHECKS
verify = check_release_checks.verify

REPO = "xinbetween/flowlight"
SHA = "a" * 40
TRUSTED_REVIEWER = "release-reviewer"


def successful_evidence():
    checks = []
    workflow_runs = []
    for index, (app, name) in enumerate(REQUIRED_CHECKS, start=1):
        if app == "github-actions":
            run_id = 100 + index
            details = f"https://github.com/{REPO}/actions/runs/{run_id}/job/{1_000 + index}"
            workflow_runs.append({
                "id": run_id,
                "path": EXPECTED_ACTIONS_WORKFLOWS[(app, name)],
                "head_sha": SHA,
                "event": "pull_request",
                "status": "completed",
                "conclusion": "success",
                "repository": {"full_name": REPO},
                "pull_requests": [{
                    "number": 76,
                    "head": {"sha": SHA},
                    "base": {"ref": "main"},
                }],
            })
        else:
            details = f"https://github.com/{REPO}/runs/3"
        checks.append({
            "id": index,
            "name": name,
            "status": "completed",
            "conclusion": "success",
            "details_url": details,
            "app": {"slug": app},
        })
    return (
        [{"total_count": len(checks), "check_runs": checks}],
        [{"total_count": len(workflow_runs), "workflow_runs": workflow_runs}],
    )


def reviewed_pull(**changes):
    pull = {
        "number": 76,
        "state": "open",
        "merged_at": None,
        "base": {"ref": "main"},
        "head": {"sha": SHA},
        "body": f"A pull request author can write this and it is not evidence:\nReviewed-Commit: {SHA}\n",
    }
    pull.update(changes)
    return [[pull]]


def review_comment(**changes):
    comment = {
        "id": 9_001,
        "issue_url": f"https://api.github.com/repos/{REPO}/issues/76",
        "html_url": f"https://github.com/{REPO}/pull/76#issuecomment-9001",
        "author_association": "OWNER",
        "user": {"login": TRUSTED_REVIEWER},
        "body": f"Independent review complete.\n\nReviewed-Commit: {SHA}\n",
    }
    comment.update(changes)
    return [[comment]]


def run_verify(checks=None, pulls=None, runs=None, comments=None, reviewers=TRUSTED_REVIEWER):
    default_checks, default_runs = successful_evidence()
    return verify(
        REPO,
        SHA,
        checks or default_checks,
        pulls or reviewed_pull(),
        runs or default_runs,
        review_comment() if comments is None else comments,
        reviewers,
    )


class ReleaseCheckTests(unittest.TestCase):
    def test_accepts_exact_reviewed_commit_with_all_checks(self):
        errors, pulls, receipts = run_verify()
        self.assertEqual(errors, [])
        self.assertEqual(pulls, [76])
        self.assertEqual(receipts, [{
            "pull_request": 76,
            "comment_id": 9_001,
            "reviewer": TRUSTED_REVIEWER,
            "author_association": "OWNER",
            "reviewed_commit": SHA,
            "url": f"https://github.com/{REPO}/pull/76#issuecomment-9001",
        }])

    def test_accepts_merged_pull(self):
        pulls = reviewed_pull(state="closed", merged_at="2026-11-04T00:00:00Z")
        errors, _, _ = run_verify(pulls=pulls)
        self.assertEqual(errors, [])

    def test_pr_author_body_marker_is_not_review_evidence(self):
        errors, _, _ = run_verify(comments=[])
        self.assertTrue(any("no authenticated exact-head review comment" in error for error in errors))
        self.assertFalse(any(TRUSTED_REVIEWER in error for error in errors),
                         "trusted reviewer configuration must not be written to logs")
        self.assertFalse(any(SHA in error for error in errors),
                         "the exact review marker must not be written to logs")

    def test_rejects_spoofed_or_malformed_review_comments(self):
        cases = {
            "untrusted commenter": review_comment(user={"login": "pull-author"}),
            "wrong SHA": review_comment(body=f"Reviewed-Commit: {'b' * 40}"),
            "wrong pull": review_comment(
                issue_url=f"https://api.github.com/repos/{REPO}/issues/77",
                html_url=f"https://github.com/{REPO}/pull/77#issuecomment-9001",
            ),
            "wrong repository": review_comment(
                issue_url="https://api.github.com/repos/other/repo/issues/76",
                html_url="https://github.com/other/repo/pull/76#issuecomment-9001",
            ),
            "invalid association": review_comment(author_association="NONE"),
            "marker not on its own line": review_comment(body=f"Approved Reviewed-Commit: {SHA}"),
            "comment URL wrong pull": review_comment(
                html_url=f"https://github.com/{REPO}/pull/77#issuecomment-9001"
            ),
            "comment URL wrong ID": review_comment(
                html_url=f"https://github.com/{REPO}/pull/76#issuecomment-9002"
            ),
            "missing comment ID": review_comment(id=None),
            "missing reviewer": review_comment(user=None),
        }
        for label, comments in cases.items():
            with self.subTest(label=label):
                errors, _, receipts = run_verify(comments=comments)
                self.assertEqual(receipts, [])
                self.assertTrue(any("no authenticated exact-head review comment" in error for error in errors))

    def test_requires_a_configured_trusted_reviewer(self):
        errors, _, receipts = run_verify(reviewers="")
        self.assertEqual(receipts, [])
        self.assertTrue(any("no trusted release reviewers" in error for error in errors))

    def test_rejects_duplicate_review_receipts(self):
        duplicate = review_comment()[0][0]
        errors, _, _ = run_verify(comments=[[duplicate, copy.deepcopy(duplicate)]])
        self.assertTrue(any("duplicate comment IDs" in error for error in errors))

    def test_rejects_missing_check(self):
        checks, runs = successful_evidence()
        checks[0]["check_runs"].pop()
        errors, _, _ = run_verify(checks=checks, runs=runs)
        self.assertTrue(any("missing required check" in error for error in errors))

    def test_requires_stable_codeql_gate_instead_of_optional_analyzers(self):
        self.assertIn(("github-actions", "CodeQL / gate"), REQUIRED_CHECKS)
        for language in ("swift", "python", "actions"):
            self.assertNotIn(("github-actions", f"analyze ({language})"), REQUIRED_CHECKS)

        checks, runs_document = successful_evidence()
        runs = checks[0]["check_runs"]
        runs[:] = [run for run in runs if run["name"] != "CodeQL / gate"]
        for language in ("swift", "python", "actions"):
            runs.append({
                "id": 200 + len(runs),
                "name": f"analyze ({language})",
                "status": "completed",
                "conclusion": "success",
                "details_url": f"https://github.com/{REPO}/actions/runs/1/job/{language}",
                "app": {"slug": "github-actions"},
            })
        errors, _, _ = run_verify(checks=checks, runs=runs_document)
        self.assertTrue(any("CodeQL / gate" in error for error in errors))

    def test_newer_failure_cannot_hide_behind_older_success(self):
        checks, runs = successful_evidence()
        failed = copy.deepcopy(checks[0]["check_runs"][0])
        failed.update(id=999, status="completed", conclusion="failure")
        checks[0]["check_runs"].append(failed)
        errors, _, _ = run_verify(checks=checks, runs=runs)
        self.assertTrue(any("not successful" in error for error in errors))

    def test_rejects_same_named_check_from_wrong_workflow(self):
        checks, runs = successful_evidence()
        first_url = checks[0]["check_runs"][0]["details_url"]
        run_id = int(first_url.split("/actions/runs/")[1].split("/")[0])
        target = next(run for run in runs[0]["workflow_runs"] if run["id"] == run_id)
        target["path"] = ".github/workflows/spoof.yml"
        errors, _, _ = run_verify(checks=checks, runs=runs)
        self.assertTrue(any("missing required check from its trusted workflow" in error for error in errors))

    def test_rejects_workflow_run_for_another_event_or_sha(self):
        for field, value in (("event", "workflow_dispatch"), ("head_sha", "b" * 40)):
            with self.subTest(field=field):
                checks, runs = successful_evidence()
                runs[0]["workflow_runs"][0][field] = value
                errors, _, _ = run_verify(checks=checks, runs=runs)
                self.assertTrue(any("missing required check from its trusted workflow" in error for error in errors))

    def test_rejects_checks_from_another_pr_at_the_same_commit(self):
        cases = {
            "another pull request": {"number": 77, "head": {"sha": SHA}, "base": {"ref": "main"}},
            "another base": {"number": 76, "head": {"sha": SHA}, "base": {"ref": "develop"}},
            "another head": {"number": 76, "head": {"sha": "b" * 40}, "base": {"ref": "main"}},
        }
        for label, linked_pull in cases.items():
            with self.subTest(label=label):
                checks, runs = successful_evidence()
                for run in runs[0]["workflow_runs"]:
                    run["pull_requests"] = [linked_pull]
                errors, _, _ = run_verify(checks=checks, runs=runs)
                self.assertTrue(any("missing required check from its trusted workflow" in error for error in errors))

    def test_rejects_check_from_untrusted_app(self):
        checks, runs = successful_evidence()
        checks[0]["check_runs"][0]["app"]["slug"] = "untrusted"
        errors, _, _ = run_verify(checks=checks, runs=runs)
        self.assertTrue(any("missing required check" in error for error in errors))

    def test_rejects_check_linked_to_another_repository(self):
        checks, runs = successful_evidence()
        checks[0]["check_runs"][0]["details_url"] = "https://github.com/other/repo/actions/runs/1"
        errors, _, _ = run_verify(checks=checks, runs=runs)
        self.assertTrue(any("missing required check" in error for error in errors))

    def test_rejects_wrong_pull_head(self):
        errors, _, _ = run_verify(pulls=reviewed_pull(head={"sha": "b" * 40}))
        self.assertTrue(any("no open or merged pull request" in error for error in errors))

    def test_rejects_closed_unmerged_pull(self):
        errors, _, _ = run_verify(pulls=reviewed_pull(state="closed", merged_at=None))
        self.assertTrue(any("no open or merged pull request" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
