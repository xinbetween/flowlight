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

    def test_shared_sidebar_shortcuts_include_store_inspect(self):
        order = ["live", "agents", "reports", "visualize", "alerts", "ask", "inspect",
                 "rules", "sources"]
        requirements = check_site.shortcut_requirements(order)
        self.assertEqual(requirements["inspect"], ["⌘7"])
        self.assertEqual(requirements["rules"], ["⌘8"])
        self.assertEqual(requirements["sources"], ["⌘9"])

    def test_stale_product_specific_sources_shortcut_fails_shared_requirement(self):
        required = ["⌘9"]
        self.assertEqual(check_site.missing_shortcuts("⌘8 · App Store", required), required)
        self.assertEqual(check_site.missing_shortcuts("⌘9", required), [])


class ScreenshotProvenanceTests(unittest.TestCase):
    def test_truthful_prior_capture_version_is_allowed(self):
        entries = {
            "agents.png": {"version": "0.17.4"},
            "alerts.png": {"version": "0.17.4"},
        }
        self.assertEqual(check_site.capture_version_problems(entries, "0.17.5", "screenshots"), [])

    def test_mixed_truthful_capture_versions_are_allowed(self):
        entries = {
            "agents.png": {"version": "0.17.4"},
            "alerts.png": {"version": "0.17.5"},
        }
        self.assertEqual(check_site.capture_version_problems(entries, "0.17.5", "screenshots"), [])

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


class HomepageInstallationTests(unittest.TestCase):
    clean_home = """
    <main>
      <div class="install-choices">
        <a class="btn install-choice direct-download" href="{{dmg}}">Download</a>
      </div>
      <div class="install-utility">
        <a class="github-link" href="https://github.com/xinbetween/flowlight">GitHub</a>
        <p><code>brew install --cask xinbetween/tap/flowlight</code>
          <button data-copy="brew install --cask xinbetween/tap/flowlight">Copy</button></p>
      </div>
    </main>
    """

    def problems(self, source):
        return check_site.homepage_installation_problems(source, "fixture")

    def test_clean_developer_installation_without_store_promotion_passes(self):
        self.assertEqual(self.problems(self.clean_home), [])

    def test_mobile_homebrew_control_must_span_both_installation_columns(self):
        clean = """
        @media (max-width: 640px) {
          .cta .brew { grid-column: 1 / -1; width: 100%; }
        }
        @media (max-width: 520px) {}
        """
        broken = clean.replace("grid-column: 1 / -1", "grid-column: auto")

        self.assertEqual(check_site.installation_css_problems(clean), [])
        self.assertIn(
            "site/site.css: mobile Homebrew control does not span the installation grid",
            check_site.installation_css_problems(broken),
        )

    def test_app_store_url_or_badge_fails(self):
        for promotion in (
            '<a href="https://apps.apple.com/app/flowlight">Store</a>',
            '<a href="https://www.apple.com/app-store/">Download from Apple</a>',
            '<a href="https://example.com/store">Download on the Mac App Store</a>',
            '<img class="app-store-badge" alt="Download on the Mac App Store">',
            "<a href='https://APPS.APPLE.COM/app/flowlight'><img alt='Download on the Mac App Store'></a>",
        ):
            with self.subTest(promotion=promotion):
                self.assertTrue(self.problems(self.clean_home + promotion))

    def test_bottom_final_section_fails(self):
        for section in (
            '<section class="final"></section>',
            "<section id='cta' class='band final highlighted'></section>",
        ):
            with self.subTest(section=section):
                self.assertTrue(self.problems(self.clean_home + section))

    def test_missing_direct_developer_download_fails(self):
        source = self.clean_home.replace("install-choice direct-download", "install-choice")
        self.assertIn("fixture: direct Developer DMG download is missing", self.problems(source))

    def test_direct_download_class_does_not_borrow_a_dmg_url_elsewhere(self):
        source = self.clean_home.replace('href="{{dmg}}"', 'href="#"') + '<a href="{{dmg}}">Footer</a>'
        self.assertIn("fixture: direct Developer DMG download is missing", self.problems(source))

    def test_direct_download_rejects_an_untrusted_origin_with_the_same_asset_path(self):
        source = self.clean_home.replace(
            'href="{{dmg}}"',
            'href="https://untrusted.example/releases/latest/download/Flowlight.dmg"',
        )
        self.assertIn("fixture: direct Developer DMG download is missing", self.problems(source))


if __name__ == "__main__":
    unittest.main()
