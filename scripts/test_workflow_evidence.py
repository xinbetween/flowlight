#!/usr/bin/env python3
"""Adversarial fixtures for CI reuse and trusted Pages provenance."""

from __future__ import annotations

import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
import pathlib
import stat
import sys
import tarfile
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("workflow_evidence.py")
SPEC = importlib.util.spec_from_file_location("workflow_evidence", SCRIPT)
assert SPEC and SPEC.loader
workflow_evidence = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = workflow_evidence
SPEC.loader.exec_module(workflow_evidence)

REPO = "xinbetween/flowlight"
SHA = "a" * 40
OTHER_SHA = "b" * 40
TREE = "c" * 40
OTHER_TREE = "d" * 40
FINGERPRINT = "e" * 64
ARCHIVE_DIGEST = "sha256:" + "f" * 64
NOW = dt.datetime(2026, 11, 4, tzinfo=dt.timezone.utc)


def run_fixture(**changes):
    run = {
        "id": 101,
        "run_attempt": 2,
        "repository": {"full_name": REPO},
        "head_repository": {"full_name": REPO},
        "path": ".github/workflows/ci.yml",
        "event": "pull_request",
        "head_sha": SHA,
        "status": "completed",
        "conclusion": "success",
        "pull_requests": [{
            "number": 17,
            "head": {"ref": "release/0.17.5", "sha": SHA, "repo": {"full_name": REPO}},
            "base": {"ref": "main", "sha": OTHER_SHA, "repo": {"full_name": REPO}},
        }],
    }
    run.update(changes)
    return run


def artifact_fixture(**changes):
    artifact = {
        "id": 501,
        "name": f"review-receipt-{SHA}-2",
        "expired": False,
        "expires_at": "2026-12-04T00:00:00Z",
        "workflow_run": {"id": 101},
        "digest": ARCHIVE_DIGEST,
        "size_in_bytes": 1234,
    }
    artifact.update(changes)
    return artifact


def receipt_fixture(**changes):
    receipt = {
        "schema": "flowlight-review-v3",
        "repository": REPO,
        "workflow": ".github/workflows/ci.yml",
        "event": "pull_request",
        "source_sha": SHA,
        "source_tree": TREE,
        "app_fingerprint": FINGERPRINT,
        "app_route": True,
        "conclusions": dict(workflow_evidence.REQUIRED_CONCLUSIONS),
        "run_id": 101,
        "run_attempt": 2,
        "app_evidence": {"mode": "executed", "source": None},
    }
    receipt.update(changes)
    return receipt


def expectation(**changes):
    values = {
        "repository": REPO,
        "source_sha": OTHER_SHA,
        "source_tree": TREE,
        "app_fingerprint": FINGERPRINT,
        "current_run_id": 999,
    }
    values.update(changes)
    return workflow_evidence.ReuseExpectation(**values)


class ReuseEvidenceTests(unittest.TestCase):
    def validate(self, run=None, artifact=None, receipt=None, expected=None, digest=ARCHIVE_DIGEST):
        return workflow_evidence.validate_reuse_evidence(
            run or run_fixture(),
            artifact or artifact_fixture(),
            receipt or receipt_fixture(),
            expected or expectation(),
            digest,
            now=NOW,
        )

    def test_accepts_only_direct_exact_tree_evidence(self):
        self.assertEqual(self.validate(), {
            "run_id": 101,
            "run_attempt": 2,
            "artifact_id": 501,
            "artifact_name": f"review-receipt-{SHA}-2",
            "artifact_digest": ARCHIVE_DIGEST,
        })

    def test_rejects_wrong_run_trust_identity_and_state(self):
        cases = {
            "repository": run_fixture(repository={"full_name": "other/repo"}),
            "fork head": run_fixture(head_repository={"full_name": "contributor/flowlight"}),
            "workflow": run_fixture(path=".github/workflows/spoof.yml"),
            "event": run_fixture(event="push"),
            "status": run_fixture(status="in_progress"),
            "conclusion": run_fixture(conclusion="failure"),
            "source SHA": run_fixture(head_sha="not-a-sha"),
            "run ID": run_fixture(id=0),
            "run attempt": run_fixture(run_attempt=0),
            "no associated PR": run_fixture(pull_requests=[]),
            "ambiguous associated PRs": run_fixture(
                pull_requests=run_fixture()["pull_requests"] * 2
            ),
            "alternate base": run_fixture(pull_requests=[{
                "number": 17,
                "head": {"ref": "release/0.17.5", "sha": SHA, "repo": {"full_name": REPO}},
                "base": {"ref": "attacker-base", "sha": OTHER_SHA, "repo": {"full_name": REPO}},
            }]),
            "foreign base repository": run_fixture(pull_requests=[{
                "number": 17,
                "head": {"ref": "release/0.17.5", "sha": SHA, "repo": {"full_name": REPO}},
                "base": {"ref": "main", "sha": OTHER_SHA,
                         "repo": {"full_name": "collaborator/flowlight"}},
            }]),
            "mismatched PR head": run_fixture(pull_requests=[{
                "number": 17,
                "head": {"ref": "release/0.17.5", "sha": OTHER_SHA,
                         "repo": {"full_name": REPO}},
                "base": {"ref": "main", "sha": OTHER_SHA, "repo": {"full_name": REPO}},
            }]),
        }
        for label, run in cases.items():
            with self.subTest(label=label), self.assertRaises(workflow_evidence.EvidenceError):
                self.validate(run=run)

    def test_rejects_wrong_receipt_identity(self):
        cases = {
            "repository": receipt_fixture(repository="other/repo"),
            "workflow": receipt_fixture(workflow=".github/workflows/spoof.yml"),
            "event": receipt_fixture(event="push"),
            "SHA": receipt_fixture(source_sha=OTHER_SHA),
            "tree": receipt_fixture(source_tree=OTHER_TREE),
            "fingerprint": receipt_fixture(app_fingerprint="0" * 64),
            "schema": receipt_fixture(schema="flowlight-review-v2"),
            "run ID": receipt_fixture(run_id=102),
            "attempt": receipt_fixture(run_attempt=1),
            "route": receipt_fixture(app_route=False),
            "chained reuse": receipt_fixture(app_evidence={
                "mode": "reused",
                "source": {"run_id": 1},
            }),
        }
        for label, receipt in cases.items():
            with self.subTest(label=label), self.assertRaises(workflow_evidence.EvidenceError):
                self.validate(receipt=receipt)

    def test_rejects_any_required_job_conclusion(self):
        for name in workflow_evidence.REQUIRED_CONCLUSIONS:
            with self.subTest(name=name):
                conclusions = dict(workflow_evidence.REQUIRED_CONCLUSIONS)
                conclusions[name] = "failure"
                with self.assertRaises(workflow_evidence.EvidenceError):
                    self.validate(receipt=receipt_fixture(conclusions=conclusions))

    def test_rejects_artifact_id_digest_run_name_and_expiry_mismatch(self):
        cases = {
            "ID": (artifact_fixture(id=0), ARCHIVE_DIGEST),
            "metadata digest": (artifact_fixture(digest="sha256:" + "0" * 64), ARCHIVE_DIGEST),
            "download digest": (artifact_fixture(), "sha256:" + "0" * 64),
            "run": (artifact_fixture(workflow_run={"id": 999}), ARCHIVE_DIGEST),
            "name": (artifact_fixture(name="review-receipt-wrong"), ARCHIVE_DIGEST),
            "expired flag": (artifact_fixture(expired=True), ARCHIVE_DIGEST),
            "expired time": (artifact_fixture(expires_at="2026-11-03T00:00:00Z"), ARCHIVE_DIGEST),
        }
        for label, (artifact, digest) in cases.items():
            with self.subTest(label=label), self.assertRaises(workflow_evidence.EvidenceError):
                self.validate(artifact=artifact, digest=digest)

    def test_newer_failure_blocks_an_older_success(self):
        old = run_fixture(id=100, run_attempt=1, conclusion="success")
        newer = run_fixture(id=102, run_attempt=1, conclusion="failure")
        selected = workflow_evidence.select_exact_tree_run(
            [old, newer], {SHA: TREE}, expectation()
        )
        self.assertEqual(selected["id"], 102)
        with self.assertRaises(workflow_evidence.EvidenceError):
            self.validate(run=selected)

    def test_matching_fingerprint_cannot_reuse_a_different_full_tree(self):
        selected = workflow_evidence.select_exact_tree_run(
            [run_fixture()], {SHA: OTHER_TREE}, expectation()
        )
        self.assertIsNone(selected)
        with self.assertRaises(workflow_evidence.EvidenceError):
            self.validate(receipt=receipt_fixture(source_tree=OTHER_TREE))


class PagesSourceTests(unittest.TestCase):
    def source(self, **changes):
        run = {
            "id": 301,
            "run_attempt": 1,
            "repository": {"full_name": REPO},
            "head_repository": {"full_name": REPO},
            "path": ".github/workflows/ci.yml",
            "event": "push",
            "head_branch": "main",
            "head_sha": SHA,
            "status": "completed",
            "conclusion": "success",
        }
        run.update(changes)
        return run

    def test_accepts_current_canonical_main_ci_push(self):
        self.assertEqual(
            workflow_evidence.validate_pages_source(self.source(), repository=REPO, current_main_sha=SHA)["id"],
            301,
        )

    def test_rejects_wrong_branch_event_run_status_source_workflow_and_repository(self):
        cases = {
            "branch": self.source(head_branch="release/0.17.5"),
            "PR artifact": self.source(event="pull_request"),
            "run": self.source(id=0),
            "status": self.source(status="in_progress"),
            "conclusion": self.source(conclusion="failure"),
            "source": self.source(head_sha="bad"),
            "workflow": self.source(path=".github/workflows/pages.yml"),
            "repository": self.source(repository={"full_name": "other/repo"}),
            "fork": self.source(head_repository={"full_name": "fork/flowlight"}),
        }
        for label, run in cases.items():
            with self.subTest(label=label), self.assertRaises(workflow_evidence.EvidenceError):
                workflow_evidence.validate_pages_source(run, repository=REPO, current_main_sha=SHA)

    def test_rejects_stale_source_when_main_advanced(self):
        with self.assertRaisesRegex(workflow_evidence.EvidenceError, "stale"):
            workflow_evidence.validate_pages_source(self.source(), repository=REPO, current_main_sha=OTHER_SHA)


class PagesBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temp.name)
        self.docs = self.base / "docs"
        self.docs.mkdir()
        (self.docs / "index.html").write_text("home\n")
        assets = self.docs / "assets"
        assets.mkdir()
        (assets / "site.css").write_text("body{}\n")
        self.bundle = self.base / "pages.tar"
        workflow_evidence.create_pages_bundle(self.docs, self.bundle, REPO, SHA, TREE)

    def tearDown(self):
        self.temp.cleanup()

    def verify(self, bundle=None):
        return workflow_evidence.verify_pages_bundle(
            bundle or self.bundle,
            self.base / f"out-{len(list(self.base.glob('out-*')))}",
            repository=REPO,
            source_sha=SHA,
            source_tree=TREE,
        )

    def rewrite(self, mutate):
        manifest, payload = workflow_evidence._tar_members(self.bundle)
        entries = [("manifest.json", (json.dumps(manifest, sort_keys=True) + "\n").encode(), 0o644)]
        entries += [(f"site/{path}", data, mode) for path, (data, mode) in payload.items()]
        entries = mutate(entries)
        target = self.base / f"tampered-{len(list(self.base.glob('tampered-*')))}.tar"
        with tarfile.open(target, "w") as archive:
            for name, data, mode in entries:
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = mode
                archive.addfile(info, io.BytesIO(data))
        return target

    def test_round_trip_is_deterministic_and_exact(self):
        second = self.base / "second.tar"
        workflow_evidence.create_pages_bundle(self.docs, second, REPO, SHA, TREE)
        self.assertEqual(self.bundle.read_bytes(), second.read_bytes())
        manifest = self.verify()
        self.assertEqual([record["path"] for record in manifest["files"]], ["assets/site.css", "index.html"])

    def test_rejects_manifest_bound_to_another_source_tree(self):
        with self.assertRaises(workflow_evidence.EvidenceError):
            workflow_evidence.verify_pages_bundle(
                self.bundle,
                self.base / "wrong-tree-output",
                repository=REPO,
                source_sha=SHA,
                source_tree=OTHER_TREE,
            )

    def test_rejects_missing_extra_and_changed_payload(self):
        variants = {
            "missing": lambda entries: [entry for entry in entries if entry[0] != "site/index.html"],
            "extra": lambda entries: entries + [("site/extra.txt", b"extra", 0o644)],
            "changed": lambda entries: [
                (name, b"changed" if name == "site/index.html" else data, mode)
                for name, data, mode in entries
            ],
        }
        for label, mutate in variants.items():
            with self.subTest(label=label), self.assertRaises(workflow_evidence.EvidenceError):
                self.verify(self.rewrite(mutate))

    def test_rejects_symlink_and_path_traversal_entries(self):
        for label, name, kind in (
            ("traversal", "site/../outside", "file"),
            ("symlink", "site/link", "symlink"),
        ):
            with self.subTest(label=label):
                target = self.base / f"{label}.tar"
                with tarfile.open(target, "w") as archive:
                    info = tarfile.TarInfo(name)
                    if kind == "symlink":
                        info.type = tarfile.SYMTYPE
                        info.linkname = "index.html"
                        archive.addfile(info)
                    else:
                        info.size = 1
                        archive.addfile(info, io.BytesIO(b"x"))
                with self.assertRaises(workflow_evidence.EvidenceError):
                    self.verify(target)

    def test_bundle_creation_rejects_source_symlink(self):
        link = self.docs / "link"
        try:
            link.symlink_to("index.html")
        except OSError:
            self.skipTest("symlinks are unavailable")
        with self.assertRaises(workflow_evidence.EvidenceError):
            workflow_evidence.create_pages_bundle(self.docs, self.base / "bad.tar", REPO, SHA, TREE)

    def test_pages_artifact_metadata_is_bound_to_source_run_and_archive(self):
        artifact = artifact_fixture(
            id=777,
            name=f"pages-site-{SHA}-1",
            workflow_run={"id": 301},
        )
        self.assertEqual(
            workflow_evidence.validate_artifact(
                artifact,
                run_id=301,
                expected_name=f"pages-site-{SHA}-1",
                archive_digest=ARCHIVE_DIGEST,
                now=NOW,
            )["id"],
            777,
        )
        for changed in (
            {"name": "pages-site-wrong"},
            {"workflow_run": {"id": 302}},
            {"digest": "sha256:" + "0" * 64},
            {"id": 0},
        ):
            tampered = copy.deepcopy(artifact)
            tampered.update(changed)
            with self.assertRaises(workflow_evidence.EvidenceError):
                workflow_evidence.validate_artifact(
                    tampered,
                    run_id=301,
                    expected_name=f"pages-site-{SHA}-1",
                    archive_digest=ARCHIVE_DIGEST,
                    now=NOW,
                )


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = pathlib.Path(__file__).resolve().parents[1]
        cls.ci = (root / ".github/workflows/ci.yml").read_text()
        cls.pages = (root / ".github/workflows/pages.yml").read_text()

    def test_ci_registers_evidence_tests_and_preserves_required_names(self):
        self.assertIn("python3 -I scripts/test_workflow_evidence.py", self.ci)
        for name in ("unit (oldest Xcode)", "unit (newest Xcode)", "Review / gate"):
            self.assertIn(f"name: {name}", self.ci)
        self.assertIn("flowlight-review-v3", self.ci)
        self.assertIn("ACTUAL_TREE=$(git rev-parse 'HEAD^{tree}')", self.ci)

    def test_change_policy_comes_from_the_trusted_base_commit(self):
        start = self.ci.index("  changes:\n")
        end = self.ci.index("  evidence:\n", start)
        block = self.ci[start:end]
        self.assertIn('TRUSTED_POLICY_SHA: ${{ github.event.pull_request.base.sha || github.sha }}', block)
        self.assertIn('git show "$TRUSTED_POLICY_SHA:scripts/classify_changes.py"', block)
        self.assertIn('python3 -I "$RUNNER_TEMP/classify_changes.py"', block)
        self.assertNotIn("python3 -I scripts/classify_changes.py", block)
        self.assertIn('"schema=flowlight-review-v3"', block)

    def test_reuse_policy_comes_from_base_and_forks_cannot_reuse(self):
        start = self.ci.index("  evidence:\n")
        end = self.ci.index("  site:\n", start)
        block = self.ci[start:end]
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", block)
        self.assertIn('TRUSTED_VERIFIER_SHA: ${{ github.event.pull_request.base.sha }}', block)
        self.assertIn('git show "$TRUSTED_VERIFIER_SHA:scripts/workflow_evidence.py"', block)
        self.assertIn('python3 -I "$RUNNER_TEMP/workflow_evidence.py" find-reuse', block)
        self.assertNotIn("python3 -I scripts/workflow_evidence.py find-reuse", block)
        self.assertIn('echo "reuse=false" >> "$GITHUB_OUTPUT"', block)

    def test_trust_contract_rejects_deliberate_pr_controlled_helpers(self):
        unsafe_changes = self.ci.replace(
            'python3 -I "$RUNNER_TEMP/classify_changes.py"',
            "python3 -I scripts/classify_changes.py",
            1,
        )
        changes = unsafe_changes[unsafe_changes.index("  changes:\n"):unsafe_changes.index("  evidence:\n")]
        self.assertIn("python3 -I scripts/classify_changes.py", changes)
        self.assertNotIn('python3 -I "$RUNNER_TEMP/classify_changes.py"', changes)

        unsafe_evidence = self.ci.replace(
            'python3 -I "$RUNNER_TEMP/workflow_evidence.py" find-reuse',
            "python3 -I scripts/workflow_evidence.py find-reuse",
            1,
        )
        evidence = unsafe_evidence[unsafe_evidence.index("  evidence:\n"):unsafe_evidence.index("  site:\n")]
        self.assertIn("python3 -I scripts/workflow_evidence.py find-reuse", evidence)
        self.assertNotIn('python3 -I "$RUNNER_TEMP/workflow_evidence.py" find-reuse', evidence)

    def test_merge_compatibility_keeps_default_pull_request_checkout(self):
        start = self.ci.index("  merge-compatibility:\n")
        end = self.ci.index("  gate:\n", start)
        block = self.ci[start:end]
        self.assertIn("actions/checkout@", block)
        self.assertNotIn("refs/pull/", block)
        self.assertNotRegex(block, r"(?m)^          ref:")

    def test_pages_is_workflow_run_only_without_checkout_or_rebuild(self):
        self.assertIn("workflow_run:", self.pages)
        self.assertIn("workflows: [CI]", self.pages)
        self.assertNotIn("workflow_dispatch:", self.pages)
        self.assertNotIn("actions/checkout@", self.pages)
        self.assertNotIn("build_site.py", self.pages)
        self.assertIn("consume-pages", self.pages)
        self.assertGreaterEqual(self.pages.count("git/ref/heads/main"), 2)

    def test_pages_deploy_job_has_only_deployment_permissions(self):
        start = self.pages.index("  deploy:\n")
        block = self.pages[start:]
        self.assertIn("      pages: write\n      id-token: write\n", block)
        self.assertNotIn("      contents:", block)
        self.assertNotIn("      actions:", block)


if __name__ == "__main__":
    unittest.main()
