#!/usr/bin/env python3
"""Focused fixtures for the fail-closed review classifier."""

from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("classify_changes.py")
SPEC = importlib.util.spec_from_file_location("classify_changes", SCRIPT)
assert SPEC and SPEC.loader
classifier = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = classifier
SPEC.loader.exec_module(classifier)


class PathPolicyTests(unittest.TestCase):
    def test_explicit_website_inputs_are_site_only(self):
        paths = (
            "README.md",
            "site/site.css",
            "site/pages/docs.html",
            "site/i18n/de.json",
            "docs/index.html",
            "docs/assets/screenshots/live.png",
            "scripts/build_site.py",
        )
        self.assertTrue(all(classifier.is_site_only_path(path) for path in paths))

    def test_release_catalog_manifest_and_workflow_inputs_force_full(self):
        paths = (
            ".github/workflows/ci.yml",
            "Flowlight/UI/ContentView.swift",
            "FlowlightTests/HelpTests.swift",
            "Shared/RulePack.swift",
            "project.yml",
            "packaging/app-store/screenshots/macos/01-connections.png",
            "rule-packs/official-source.json",
            "site/packs/v1/official.json",
            "docs/packs/v1/official.json",
            "docs/assets/screenshots/manifest.json",
            "site/pages/releases.html",
            "scripts/screenshots.sh",
            "scripts/classify_changes.py",
        )
        self.assertTrue(all(not classifier.is_site_only_path(path) for path in paths))

    def test_unknown_and_malformed_paths_force_full(self):
        for path in ("new-area/file.txt", "../outside", "/absolute", "bad\\path"):
            self.assertFalse(classifier.is_site_only_path(path), path)

    def test_rename_and_copy_records_classify_both_paths(self):
        payload = b"R100\0docs/old.html\0Flowlight/New.swift\0C087\0README.md\0project.yml\0"
        self.assertEqual(
            classifier.parse_name_status(payload),
            ("docs/old.html", "Flowlight/New.swift", "README.md", "project.yml"),
        )

    def test_truncated_rename_is_rejected(self):
        with self.assertRaises(ValueError):
            classifier.parse_name_status(b"R100\0docs/old.html\0")


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "classifier@example.invalid")
        self.git("config", "user.name", "Classifier Test")
        (self.repo / "Flowlight").mkdir()
        (self.repo / "site").mkdir()
        (self.repo / "Flowlight/App.swift").write_text("one\n")
        (self.repo / "site/site.css").write_text("one\n")
        self.commit("initial")
        self.base = self.rev("HEAD")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", self.repo, *args], check=True, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).stdout.strip()

    def rev(self, name):
        return self.git("rev-parse", name)

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-q", "-m", message)

    def test_site_change_keeps_fingerprint_and_skips_app(self):
        before = classifier.app_fingerprint(self.repo, self.base)
        (self.repo / "site/site.css").write_text("two\n")
        self.commit("site")
        result = classifier.classify(self.repo, self.base, "HEAD")
        self.assertTrue(result.site_only)
        self.assertFalse(result.app)
        self.assertFalse(result.python)
        self.assertFalse(result.actions)
        self.assertEqual(result.schema, "flowlight-review-v2")
        self.assertEqual(result.app_fingerprint, before)

    def test_site_python_change_routes_python_without_app_or_actions(self):
        scripts = self.repo / "scripts"
        scripts.mkdir()
        (scripts / "build_site.py").write_text("print('one')\n")
        self.commit("site script")
        result = classifier.classify(self.repo, self.base, "HEAD")
        self.assertFalse(result.app)
        self.assertTrue(result.python)
        self.assertFalse(result.actions)

    def test_workflow_change_routes_app_and_actions(self):
        workflows = self.repo / ".github/workflows"
        workflows.mkdir(parents=True)
        (workflows / "ci.yml").write_text("name: CI\n")
        self.commit("workflow")
        result = classifier.classify(self.repo, self.base, "HEAD")
        self.assertTrue(result.app)
        self.assertFalse(result.python)
        self.assertTrue(result.actions)

    def test_app_change_updates_fingerprint_and_requires_app(self):
        before = classifier.app_fingerprint(self.repo, self.base)
        (self.repo / "Flowlight/App.swift").write_text("two\n")
        self.commit("app")
        result = classifier.classify(self.repo, self.base, "HEAD")
        self.assertTrue(result.app)
        self.assertFalse(result.site_only)
        self.assertNotEqual(result.app_fingerprint, before)

    def test_missing_base_fails_closed_to_every_codeql_route_and_emits_identity(self):
        result = classifier.classify(self.repo, None, "HEAD")
        self.assertTrue(result.app)
        self.assertTrue(result.python)
        self.assertTrue(result.actions)
        self.assertEqual(result.head_sha, self.rev("HEAD"))
        self.assertEqual(result.tree, self.rev("HEAD^{tree}"))
        self.assertEqual(len(result.app_fingerprint), 64)

    def test_invalid_base_fails_closed_to_every_codeql_route(self):
        result = classifier.classify(self.repo, "f" * 40, "HEAD")
        self.assertTrue(result.app)
        self.assertTrue(result.python)
        self.assertTrue(result.actions)


if __name__ == "__main__":
    unittest.main()
