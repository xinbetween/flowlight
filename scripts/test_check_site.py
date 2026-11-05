#!/usr/bin/env python3
"""Focused fixtures for navigation-derived site checks."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


SCRIPT = pathlib.Path(__file__).with_name("check_site.py")
SPEC = importlib.util.spec_from_file_location("check_site", SCRIPT)
assert SPEC and SPEC.loader
check_site = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = check_site
SPEC.loader.exec_module(check_site)


class SidebarOrderTests(unittest.TestCase):
    def test_grouped_visible_order_is_authoritative(self):
        source = """
        var items: [SidebarItem] {
            let order: [SidebarItem]
            switch self {
            case .traffic: order = [.live, .agents, .reports, .visualize, .alerts]
            case .investigate: order = [.ask, .inspect]
            case .control: order = [.rules]
            case .sources: order = [.sources]
            }
            return order.filter { SidebarItem.availableCases.contains($0) }
        }
        """

        self.assertEqual(
            check_site.sidebar_order(source),
            ["live", "agents", "reports", "visualize", "alerts", "ask", "inspect",
             "rules", "sources"],
        )

    def test_missing_grouped_order_fails_closed(self):
        with self.assertRaises(ValueError):
            check_site.sidebar_order("enum SidebarItem { case live, alerts }")

    def test_product_specific_shortcuts_account_for_missing_store_inspect(self):
        order = ["live", "agents", "reports", "visualize", "alerts", "ask", "inspect",
                 "rules", "sources"]
        requirements = check_site.shortcut_requirements(order)
        self.assertEqual(requirements["inspect"], ["⌘7 · Developer ID"])
        self.assertEqual(requirements["rules"], ["⌘8 · Developer ID", "⌘7 · App Store"])
        self.assertEqual(requirements["sources"], ["⌘9 · Developer ID", "⌘8 · App Store"])

    def test_universal_sources_shortcut_fails_store_requirement(self):
        required = ["⌘9 · Developer ID", "⌘8 · App Store"]
        self.assertEqual(check_site.missing_shortcuts("⌘9", required), required)
        self.assertEqual(check_site.missing_shortcuts(
            "⌘9 · Developer ID<br>⌘8 · App Store", required), [])


class ScreenshotProvenanceTests(unittest.TestCase):
    def test_truthful_prior_capture_version_is_allowed(self):
        entries = {
            "agents.png": {"version": "0.17.4"},
            "alerts.png": {"version": "0.17.4"},
        }
        self.assertEqual(check_site.capture_version_problems(entries, "0.17.5", "screenshots"), [])

    def test_mixed_capture_versions_fail(self):
        entries = {
            "agents.png": {"version": "0.17.4"},
            "alerts.png": {"version": "0.17.5"},
        }
        self.assertEqual(
            check_site.capture_version_problems(entries, "0.17.5", "screenshots"),
            ["screenshots: screenshots mix capture versions 0.17.4, 0.17.5"],
        )

    def test_future_and_missing_capture_versions_fail(self):
        self.assertEqual(
            check_site.capture_version_problems(
                {"agents.png": {"version": "0.18.0"}}, "0.17.5", "screenshots"
            ),
            ["screenshots: capture version is newer than app 0.17.5: 0.18.0"],
        )
        self.assertEqual(
            check_site.capture_version_problems(
                {"agents.png": {}}, "0.17.5", "screenshots"
            ),
            ["screenshots: agents.png has no capture version"],
        )


class PagesProvenanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = check_site.PAGES_WORKFLOW.read_text()

    def test_committed_workflow_uses_verified_ci_artifact(self):
        self.assertEqual(check_site.pages_workflow_problems(self.source), [])

    def test_source_bypassing_trigger_fails(self):
        unsafe = self.source.replace("  workflow_run:\n", "  workflow_dispatch:\n  workflow_run:\n", 1)
        self.assertIn("Pages has a source-bypassing trigger", check_site.pages_workflow_problems(unsafe))

    def test_checkout_or_rebuild_fails(self):
        unsafe = self.source.replace("    steps:\n", "    steps:\n      - uses: actions/checkout@v4\n", 1)
        self.assertIn("Pages checks out or rebuilds source", check_site.pages_workflow_problems(unsafe))

    def test_missing_exact_artifact_consumption_fails(self):
        unsafe = self.source.replace("consume-pages", "consume-unverified-pages", 1)
        self.assertIn(
            "Pages does not consume and upload the verified CI artifact",
            check_site.pages_workflow_problems(unsafe),
        )

    def test_extra_deploy_permission_fails(self):
        unsafe = self.source.replace("      pages: write\n", "      pages: write\n      contents: write\n", 1)
        self.assertIn(
            "Pages deploy permissions are not limited to pages and id-token write",
            check_site.pages_workflow_problems(unsafe),
        )


if __name__ == "__main__":
    unittest.main()
