#!/usr/bin/env python3

import copy
import unittest

from check_release_checks import REQUIRED_CHECKS, verify


REPO = "xinbetween/flowlight"
SHA = "a" * 40


def successful_checks():
    runs = []
    for index, (app, name) in enumerate(REQUIRED_CHECKS, start=1):
        path = "actions/runs/1/job/2" if app == "github-actions" else "runs/3"
        runs.append({
            "id": index,
            "name": name,
            "status": "completed",
            "conclusion": "success",
            "details_url": f"https://github.com/{REPO}/{path}",
            "app": {"slug": app},
        })
    return [{"total_count": len(runs), "check_runs": runs}]


def reviewed_pull(**changes):
    pull = {
        "number": 76,
        "state": "open",
        "merged_at": None,
        "base": {"ref": "main"},
        "head": {"sha": SHA},
    }
    pull.update(changes)
    return [[pull]]


class ReleaseCheckTests(unittest.TestCase):
    def test_accepts_exact_reviewed_commit_with_all_checks(self):
        errors, pulls = verify(REPO, SHA, successful_checks(), reviewed_pull())
        self.assertEqual(errors, [])
        self.assertEqual(pulls, [76])

    def test_accepts_merged_pull(self):
        pulls = reviewed_pull(state="closed", merged_at="2026-11-04T00:00:00Z")
        errors, _ = verify(REPO, SHA, successful_checks(), pulls)
        self.assertEqual(errors, [])

    def test_rejects_missing_check(self):
        checks = successful_checks()
        checks[0]["check_runs"].pop()
        errors, _ = verify(REPO, SHA, checks, reviewed_pull())
        self.assertTrue(any("missing required check" in error for error in errors))

    def test_newer_failure_cannot_hide_behind_older_success(self):
        checks = successful_checks()
        failed = copy.deepcopy(checks[0]["check_runs"][0])
        failed.update(id=999, status="completed", conclusion="failure")
        checks[0]["check_runs"].append(failed)
        errors, _ = verify(REPO, SHA, checks, reviewed_pull())
        self.assertTrue(any("not successful" in error for error in errors))

    def test_rejects_check_from_untrusted_app(self):
        checks = successful_checks()
        checks[0]["check_runs"][0]["app"]["slug"] = "untrusted"
        errors, _ = verify(REPO, SHA, checks, reviewed_pull())
        self.assertTrue(any("missing required check" in error for error in errors))

    def test_rejects_check_linked_to_another_repository(self):
        checks = successful_checks()
        checks[0]["check_runs"][0]["details_url"] = "https://github.com/other/repo/actions/runs/1"
        errors, _ = verify(REPO, SHA, checks, reviewed_pull())
        self.assertTrue(any("missing required check" in error for error in errors))

    def test_rejects_wrong_pull_head(self):
        pulls = reviewed_pull(head={"sha": "b" * 40})
        errors, _ = verify(REPO, SHA, successful_checks(), pulls)
        self.assertTrue(any("no open or merged pull request" in error for error in errors))

    def test_rejects_closed_unmerged_pull(self):
        pulls = reviewed_pull(state="closed", merged_at=None)
        errors, _ = verify(REPO, SHA, successful_checks(), pulls)
        self.assertTrue(any("no open or merged pull request" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
