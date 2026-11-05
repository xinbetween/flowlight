#!/usr/bin/env python3

import copy
import datetime as dt
import hashlib
import importlib.util
import json
import pathlib
import stat
import sys
import tempfile
import types
import unittest
import warnings
import zipfile

SCRIPT = pathlib.Path(__file__).with_name("release_artifact.py")
SPEC = importlib.util.spec_from_file_location("release_artifact", SCRIPT)
assert SPEC and SPEC.loader
release_artifact = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release_artifact
SPEC.loader.exec_module(release_artifact)
ReleaseArtifactError = release_artifact.ReleaseArtifactError
verify_bundle = release_artifact.verify_bundle
create_manifest = release_artifact.create_manifest
extract_archive = release_artifact.extract_archive
verify_run = release_artifact.verify_run
REQUIRED_REVIEW_CHECKS = release_artifact.REQUIRED_REVIEW_CHECKS

CHECKS_SCRIPT = pathlib.Path(__file__).with_name("check_release_checks.py")
CHECKS_SPEC = importlib.util.spec_from_file_location("release_check_contract", CHECKS_SCRIPT)
assert CHECKS_SPEC and CHECKS_SPEC.loader
release_check_contract = importlib.util.module_from_spec(CHECKS_SPEC)
sys.modules[CHECKS_SPEC.name] = release_check_contract
CHECKS_SPEC.loader.exec_module(release_check_contract)

REPOSITORY = "xinbetween/flowlight"
TAG = "v0.17.4"
SHA = "a" * 40
TREE = "b" * 40
VERSION = "0.17.4"
BUILD = "78"
WORKFLOW_ID = 123
RUN_ID = 456


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run_fixture():
    run = {
        "id": RUN_ID,
        "repository": {"full_name": REPOSITORY},
        "path": ".github/workflows/release.yml",
        "workflow_id": WORKFLOW_ID,
        "event": "push",
        "head_branch": TAG,
        "head_sha": SHA,
        "status": "completed",
        "conclusion": "success",
        "run_attempt": 1,
    }
    artifact = {
        "id": 789,
        "name": f"flowlight-release-{TAG}-{RUN_ID}-1",
        "expired": False,
        "expires_at": "2030-01-01T00:00:00Z",
        "workflow_run": {"id": RUN_ID},
        "digest": f"sha256:{'c' * 64}",
        "size_in_bytes": 1234,
    }
    return run, {"total_count": 1, "artifacts": [artifact]}


def write_bundle(root):
    root = pathlib.Path(root)
    files = {
        "Flowlight.dmg": b"signed dmg fixture",
        f"Flowlight-{VERSION}.pkg": b"signed pkg fixture",
    }
    for name, data in files.items():
        (root / name).write_bytes(data)
    sums = "".join(f"{digest(data)}  {name}\n" for name, data in files.items()).encode()
    (root / "SHA256SUMS.txt").write_bytes(sums)
    notes = b"Flowlight 0.17.4 release notes\n\n### Checksums\n"
    (root / "RELEASE-NOTES.md").write_bytes(notes)
    asset_names = ["Flowlight.dmg", f"Flowlight-{VERSION}.pkg", "SHA256SUMS.txt"]
    manifest = {
        "schema": "flowlight-release-v1",
        "repository": REPOSITORY,
        "tag": TAG,
        "source_sha": SHA,
        "source_tree": TREE,
        "version": VERSION,
        "build": BUILD,
        "preparation": {
            "workflow": ".github/workflows/release.yml",
            "workflow_id": WORKFLOW_ID,
            "run_id": RUN_ID,
            "run_attempt": 1,
        },
        "review_evidence": {
            "repository": REPOSITORY,
            "source_sha": SHA,
            "pull_requests": [82],
            "review_receipts": [{
                "pull_request": 82,
                "comment_id": 9_001,
                "reviewer": "release-reviewer",
                "author_association": "OWNER",
                "reviewed_commit": SHA,
                "url": f"https://github.com/{REPOSITORY}/pull/82#issuecomment-9001",
            }],
            "checks": [
                {
                    "app": app,
                    "name": name,
                    "id": index,
                    "details_url": f"https://github.com/{REPOSITORY}/actions/runs/{index}",
                    "workflow": release_artifact.REVIEW_WORKFLOWS.get((app, name)),
                    "workflow_run_id": index if (app, name) in release_artifact.REVIEW_WORKFLOWS else None,
                    "pull_request": 82 if (app, name) in release_artifact.REVIEW_WORKFLOWS else None,
                }
                for index, (app, name) in enumerate(sorted(REQUIRED_REVIEW_CHECKS), start=1)
            ],
        },
        "assets": [
            {"name": name, "size": (root / name).stat().st_size, "sha256": digest((root / name).read_bytes())}
            for name in asset_names
        ],
        "release_notes": {"name": "RELEASE-NOTES.md", "size": len(notes), "sha256": digest(notes)},
    }
    (root / "RELEASE-MANIFEST.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def verify(root, public=False):
    return verify_bundle(
        root,
        repository=REPOSITORY,
        tag=TAG,
        source_sha=SHA,
        version=VERSION,
        build=BUILD,
        workflow_id=WORKFLOW_ID,
        run_id=RUN_ID,
        run_attempt=1,
        public=public,
    )


class PreparationRunTests(unittest.TestCase):
    def test_accepts_exact_successful_tag_push(self):
        run, artifacts = run_fixture()
        result = verify_run(
            run, artifacts, repository=REPOSITORY, workflow_id=WORKFLOW_ID,
            run_id=str(RUN_ID), tag=TAG, source_sha=SHA,
            now=dt.datetime(2029, 1, 1, tzinfo=dt.timezone.utc),
        )
        self.assertEqual(result["artifact_id"], 789)

    def test_accepts_current_attempt_alongside_failed_previous_attempt_artifact(self):
        run, artifacts = run_fixture()
        run["run_attempt"] = 2
        previous = dict(artifacts["artifacts"][0])
        current = dict(previous, id=790, name=f"flowlight-release-{TAG}-{RUN_ID}-2")
        artifacts = {"total_count": 2, "artifacts": [previous, current]}

        result = verify_run(
            run, artifacts, repository=REPOSITORY, workflow_id=WORKFLOW_ID,
            run_id=str(RUN_ID), tag=TAG, source_sha=SHA,
            now=dt.datetime(2029, 1, 1, tzinfo=dt.timezone.utc),
        )

        self.assertEqual(result["artifact_id"], 790)
        self.assertEqual(result["run_attempt"], 2)

    def test_rejects_wrong_run_metadata_and_artifacts(self):
        mutations = {
            "nonnumeric run ID": lambda run, artifacts: (run, artifacts, "not-a-run"),
            "another repository": lambda run, artifacts: (self._set(run, "repository", {"full_name": "other/repo"}), artifacts, str(RUN_ID)),
            "another workflow": lambda run, artifacts: (self._set(run, "path", ".github/workflows/ci.yml"), artifacts, str(RUN_ID)),
            "another workflow ID": lambda run, artifacts: (self._set(run, "workflow_id", 999), artifacts, str(RUN_ID)),
            "dispatch run": lambda run, artifacts: (self._set(run, "event", "workflow_dispatch"), artifacts, str(RUN_ID)),
            "another tag": lambda run, artifacts: (self._set(run, "head_branch", "v9.9.9"), artifacts, str(RUN_ID)),
            "another SHA": lambda run, artifacts: (self._set(run, "head_sha", "d" * 40), artifacts, str(RUN_ID)),
            "in progress": lambda run, artifacts: (self._set(run, "status", "in_progress"), artifacts, str(RUN_ID)),
            "failed": lambda run, artifacts: (self._set(run, "conclusion", "failure"), artifacts, str(RUN_ID)),
            "missing artifact": lambda run, artifacts: (run, {"total_count": 0, "artifacts": []}, str(RUN_ID)),
            "duplicate artifacts": lambda run, artifacts: (run, {"total_count": 2, "artifacts": artifacts["artifacts"] * 2}, str(RUN_ID)),
            "expired artifact": lambda run, artifacts: (run, self._artifact(artifacts, expired=True), str(RUN_ID)),
            "wrong artifact name": lambda run, artifacts: (run, self._artifact(artifacts, name="other"), str(RUN_ID)),
            "wrong attached run": lambda run, artifacts: (run, self._artifact(artifacts, workflow_run={"id": 999}), str(RUN_ID)),
            "malformed digest": lambda run, artifacts: (run, self._artifact(artifacts, digest="sha256:BAD"), str(RUN_ID)),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                run, artifacts = run_fixture()
                run, artifacts, run_id = mutate(run, artifacts)
                with self.assertRaises(ReleaseArtifactError):
                    verify_run(
                        run, artifacts, repository=REPOSITORY, workflow_id=WORKFLOW_ID,
                        run_id=run_id, tag=TAG, source_sha=SHA,
                        now=dt.datetime(2029, 1, 1, tzinfo=dt.timezone.utc),
                    )

    @staticmethod
    def _set(document, key, value):
        document[key] = value
        return document

    @staticmethod
    def _artifact(document, **changes):
        document["artifacts"][0].update(changes)
        return document


class PreparedArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        write_bundle(self.bundle)
        self.archive = self.root / "prepared.zip"
        self.destination = self.root / "extracted"

    def tearDown(self):
        self.temporary.cleanup()

    def _entries(self):
        return {path.name: path.read_bytes() for path in self.bundle.iterdir()}

    def _write_custom(self, entries, *, duplicate=None, special_mode=None):
        special_mode = special_mode or {}
        with zipfile.ZipFile(self.archive, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data in entries.items():
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = special_mode.get(name, stat.S_IFREG | 0o644) << 16
                archive.writestr(info, data)
            if duplicate:
                info = zipfile.ZipInfo(duplicate)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr(info, entries[duplicate])

    def test_extracts_exact_archive_and_round_trips_bundle(self):
        with zipfile.ZipFile(self.archive, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in self.bundle.iterdir():
                archive.write(path, path.name)
        extract_archive(self.archive, self.destination, version=VERSION)
        verify(self.destination)

    def test_rejects_unsafe_or_substituted_archive_entries(self):
        def extra(entries):
            entries["extra"] = b"extra"
            return entries, {}

        def traversal(entries):
            entries["../Flowlight.dmg"] = entries.pop("Flowlight.dmg")
            return entries, {}

        def wrong_package(entries):
            entries["Flowlight-9.9.9.pkg"] = entries.pop(f"Flowlight-{VERSION}.pkg")
            return entries, {}

        def symlink(entries):
            return entries, {"Flowlight.dmg": stat.S_IFLNK | 0o777}

        def directory(entries):
            return entries, {"Flowlight.dmg": stat.S_IFDIR | 0o755}

        cases = {
            "extra path": extra,
            "traversal path": traversal,
            "wrong package": wrong_package,
            "symlink entry": symlink,
            "directory entry": directory,
        }
        for label, mutate in cases.items():
            with self.subTest(label=label):
                entries, modes = mutate(self._entries())
                self._write_custom(entries, special_mode=modes)
                with self.assertRaises(ReleaseArtifactError):
                    extract_archive(self.archive, self.destination, version=VERSION)
                if self.destination.exists():
                    for path in self.destination.iterdir():
                        path.unlink()

    def test_rejects_duplicate_corrupt_and_oversized_archives(self):
        self._write_custom(self._entries(), duplicate="Flowlight.dmg")
        with self.assertRaises(ReleaseArtifactError):
            extract_archive(self.archive, self.destination, version=VERSION)

        self.destination.rmdir()
        self.archive.write_bytes(b"not a zip")
        with self.assertRaises(ReleaseArtifactError):
            extract_archive(self.archive, self.destination, version=VERSION)

        self.archive.unlink()
        self._write_custom(self._entries())
        with self.assertRaises(ReleaseArtifactError):
            extract_archive(self.archive, self.destination, version=VERSION, max_expanded_size=1)


class PreparedBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        write_bundle(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def test_create_manifest_round_trip(self):
        manifest = json.loads((self.root / "RELEASE-MANIFEST.json").read_text())
        evidence = self.root / "review-evidence.json"
        evidence.write_text(json.dumps(manifest["review_evidence"]))
        (self.root / "RELEASE-MANIFEST.json").unlink()
        create_manifest(types.SimpleNamespace(
            bundle=str(self.root), repository=REPOSITORY, tag=TAG, source_sha=SHA,
            source_tree=TREE, version=VERSION, build=BUILD, workflow_id=WORKFLOW_ID,
            run_id=RUN_ID, run_attempt=1, evidence=str(evidence),
        ))
        evidence.unlink()
        verify(self.root)

    def test_accepts_exact_prepared_and_public_bundles(self):
        verify(self.root)
        (self.root / "RELEASE-NOTES.md").unlink()
        verify(self.root, public=True)

    def test_accepts_github_association_metadata(self):
        for association in sorted(release_artifact.GITHUB_AUTHOR_ASSOCIATIONS):
            with self.subTest(association=association):
                manifest = self._load_manifest()
                manifest["review_evidence"]["review_receipts"][0]["author_association"] = association
                self._save_manifest(manifest)
                verify(self.root)

    def test_author_association_enum_matches_evidence_collector(self):
        self.assertEqual(
            release_artifact.GITHUB_AUTHOR_ASSOCIATIONS,
            release_check_contract.GITHUB_AUTHOR_ASSOCIATIONS,
        )

    def test_rejects_changed_or_malformed_bundles(self):
        cases = {
            "changed DMG": lambda: (self.root / "Flowlight.dmg").write_bytes(b"tampered"),
            "changed PKG": lambda: (self.root / f"Flowlight-{VERSION}.pkg").write_bytes(b"tampered"),
            "changed notes": lambda: (self.root / "RELEASE-NOTES.md").write_bytes(b"tampered"),
            "changed checksums": lambda: (self.root / "SHA256SUMS.txt").write_text("0" * 64 + "  Flowlight.dmg\n"),
            "missing file": lambda: (self.root / "Flowlight.dmg").unlink(),
            "extra file": lambda: (self.root / "extra").write_text("extra"),
            "nested directory": lambda: (self.root / "nested").mkdir(),
            "symlink": lambda: (self.root / "extra").symlink_to(self.root / "Flowlight.dmg"),
            "duplicate checksum": self._duplicate_checksum,
            "uppercase checksum": self._uppercase_checksum,
            "manifest wrong repository": lambda: self._manifest_field("repository", "other/repo"),
            "manifest wrong tag": lambda: self._manifest_field("tag", "v9.9.9"),
            "manifest wrong SHA": lambda: self._manifest_field("source_sha", "d" * 40),
            "manifest wrong version": lambda: self._manifest_field("version", "9.9.9"),
            "manifest wrong build": lambda: self._manifest_field("build", "999"),
            "manifest wrong workflow": lambda: self._preparation_field("workflow", ".github/workflows/ci.yml"),
            "manifest wrong run": lambda: self._preparation_field("run_id", 999),
            "manifest wrong attempt": lambda: self._preparation_field("run_attempt", 2),
            "manifest incomplete evidence": self._incomplete_evidence,
            "manifest evidence wrong repository": lambda: self._evidence_field("repository", "other/repo"),
            "manifest evidence wrong SHA": lambda: self._evidence_field("source_sha", "d" * 40),
            "manifest evidence missing PR": lambda: self._evidence_field("pull_requests", []),
            "manifest evidence missing receipt": lambda: self._evidence_field("review_receipts", []),
            "manifest receipt wrong PR": lambda: self._review_receipt_field(0, "pull_request", 999),
            "manifest receipt invalid ID": lambda: self._review_receipt_field(0, "comment_id", 0),
            "manifest receipt missing reviewer": lambda: self._review_receipt_field(0, "reviewer", ""),
            "manifest receipt missing association": lambda: self._review_receipt_field(0, "author_association", ""),
            "manifest receipt whitespace association": lambda: self._review_receipt_field(0, "author_association", "  "),
            "manifest receipt unknown association": lambda: self._review_receipt_field(0, "author_association", "FORGED"),
            "manifest receipt non-string association": lambda: self._review_receipt_field(0, "author_association", 1),
            "manifest receipt wrong SHA": lambda: self._review_receipt_field(0, "reviewed_commit", "d" * 40),
            "manifest receipt wrong URL": lambda: self._review_receipt_field(
                0, "url", f"https://github.com/{REPOSITORY}/pull/82#issuecomment-9002"
            ),
            "manifest duplicate receipt": self._duplicate_review_receipt,
            "manifest evidence wrong workflow": lambda: self._review_check_field(0, "workflow", ".github/workflows/release.yml"),
            "manifest evidence wrong workflow run": lambda: self._review_check_field(0, "workflow_run_id", 999),
            "manifest evidence wrong check PR": lambda: self._review_check_field(0, "pull_request", 999),
            "manifest evidence wrong check URL": lambda: self._review_check_field(0, "details_url", f"https://github.com/{REPOSITORY}/actions/runs/999"),
            "manifest size mismatch": self._size_mismatch,
            "manifest checksum disagreement": self._manifest_checksum_disagreement,
        }
        for label, mutation in cases.items():
            with self.subTest(label=label):
                with tempfile.TemporaryDirectory() as temporary:
                    root = pathlib.Path(temporary)
                    write_bundle(root)
                    old_root, self.root = self.root, root
                    try:
                        mutation()
                        with self.assertRaises(ReleaseArtifactError):
                            verify(self.root)
                    finally:
                        self.root = old_root

    def _load_manifest(self):
        return json.loads((self.root / "RELEASE-MANIFEST.json").read_text())

    def _save_manifest(self, value):
        (self.root / "RELEASE-MANIFEST.json").write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def _manifest_field(self, key, value):
        manifest = self._load_manifest()
        manifest[key] = value
        self._save_manifest(manifest)

    def _preparation_field(self, key, value):
        manifest = self._load_manifest()
        manifest["preparation"][key] = value
        self._save_manifest(manifest)

    def _incomplete_evidence(self):
        manifest = self._load_manifest()
        manifest["review_evidence"]["checks"].pop()
        self._save_manifest(manifest)

    def _evidence_field(self, key, value):
        manifest = self._load_manifest()
        manifest["review_evidence"][key] = value
        self._save_manifest(manifest)

    def _review_check_field(self, index, key, value):
        manifest = self._load_manifest()
        manifest["review_evidence"]["checks"][index][key] = value
        self._save_manifest(manifest)

    def _review_receipt_field(self, index, key, value):
        manifest = self._load_manifest()
        manifest["review_evidence"]["review_receipts"][index][key] = value
        self._save_manifest(manifest)

    def _duplicate_review_receipt(self):
        manifest = self._load_manifest()
        manifest["review_evidence"]["review_receipts"].append(
            copy.deepcopy(manifest["review_evidence"]["review_receipts"][0])
        )
        self._save_manifest(manifest)

    def _size_mismatch(self):
        manifest = self._load_manifest()
        manifest["assets"][0]["size"] += 1
        self._save_manifest(manifest)

    def _manifest_checksum_disagreement(self):
        manifest = self._load_manifest()
        manifest["assets"][0]["sha256"] = "e" * 64
        self._save_manifest(manifest)

    def _duplicate_checksum(self):
        line = (self.root / "SHA256SUMS.txt").read_text().splitlines()[0]
        (self.root / "SHA256SUMS.txt").write_text(f"{line}\n{line}\n")

    def _uppercase_checksum(self):
        path = self.root / "SHA256SUMS.txt"
        path.write_text(path.read_text().upper())


if __name__ == "__main__":
    unittest.main()
