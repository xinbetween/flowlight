#!/usr/bin/env python3
"""Focused fixtures for navigation-derived site checks."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("check_site.py")
SPEC = importlib.util.spec_from_file_location("check_site", SCRIPT)
assert SPEC and SPEC.loader
check_site = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = check_site
SPEC.loader.exec_module(check_site)

BUILD_SCRIPT = pathlib.Path(__file__).with_name("build_site.py")
BUILD_SPEC = importlib.util.spec_from_file_location("build_site", BUILD_SCRIPT)
assert BUILD_SPEC and BUILD_SPEC.loader
build_site = importlib.util.module_from_spec(BUILD_SPEC)
BUILD_SPEC.loader.exec_module(build_site)


class SiteBuildProvenanceTests(unittest.TestCase):
    provenance = b'{"fixture":"reviewed"}\n'

    def fixture(self, source_content=provenance):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = pathlib.Path(temporary.name)
        source_catalog = root / "site/packs/v1/official.json"
        source_provenance = root / "site/packs/v1/provenance"
        output_catalog = root / "docs/packs/v1/official.json"
        output_provenance = root / "docs/packs/v1/provenance"
        source_provenance.mkdir(parents=True)
        output_provenance.mkdir(parents=True)

        name = f"{hashlib.sha256(self.provenance).hexdigest()}.json"
        source_url = build_site.OFFICIAL_PACK_PROVENANCE_URL + name
        catalog = (
            json.dumps({"payload": {"packs": [
                {"manifest": {"id": "official.advertising", "source": source_url}},
                {"manifest": {"id": "official.advertising-aggressive", "source": source_url}},
            ]}}) + "\n"
        ).encode()
        source_catalog.parent.mkdir(parents=True, exist_ok=True)
        source_catalog.write_bytes(catalog)
        output_catalog.parent.mkdir(parents=True, exist_ok=True)
        output_catalog.write_bytes(b"prior catalog\n")
        (output_provenance / name).write_bytes(b"prior provenance\n")
        if source_content is not None:
            (source_provenance / name).write_bytes(source_content)
        return root, source_catalog, source_provenance, output_catalog, output_provenance, name, catalog

    @staticmethod
    def snapshot(output_catalog, output_provenance):
        return output_catalog.read_bytes(), {
            path.relative_to(output_provenance).as_posix(): path.read_bytes()
            for path in output_provenance.rglob("*")
            if path.is_file()
        }

    def publish(self, fixture):
        root, source_catalog, source_provenance, output_catalog, output_provenance, _, _ = fixture
        return build_site.publish_official_pack_outputs(
            source_catalog, output_catalog, source_provenance, output_provenance, root
        )

    def test_missing_provenance_leaves_prior_publication_unchanged(self):
        fixture = self.fixture(source_content=None)
        before = self.snapshot(fixture[3], fixture[4])
        with self.assertRaises(SystemExit):
            self.publish(fixture)
        self.assertEqual(self.snapshot(fixture[3], fixture[4]), before)

    def test_digest_mismatch_leaves_prior_publication_unchanged(self):
        fixture = self.fixture(source_content=b'{"fixture":"different"}\n')
        before = self.snapshot(fixture[3], fixture[4])
        with self.assertRaises(SystemExit):
            self.publish(fixture)
        self.assertEqual(self.snapshot(fixture[3], fixture[4]), before)

    def test_advertising_pack_without_content_addressed_provenance_is_rejected(self):
        fixture = self.fixture()
        catalog = json.loads(fixture[1].read_bytes())
        catalog["payload"]["packs"][1]["manifest"]["source"] = "manual notes"
        fixture[1].write_text(json.dumps(catalog) + "\n", encoding="utf-8")
        before = self.snapshot(fixture[3], fixture[4])
        with self.assertRaisesRegex(SystemExit, "without content-addressed provenance"):
            self.publish(fixture)
        self.assertEqual(self.snapshot(fixture[3], fixture[4]), before)

    def test_stale_provenance_leaves_prior_publication_unchanged(self):
        fixture = self.fixture()
        (fixture[4] / "stale.json").write_bytes(b"stale\n")
        before = self.snapshot(fixture[3], fixture[4])
        with self.assertRaises(SystemExit):
            self.publish(fixture)
        self.assertEqual(self.snapshot(fixture[3], fixture[4]), before)

    def test_catalog_swap_failure_keeps_previous_catalog_provenance_usable(self):
        fixture = self.fixture()
        old_provenance = b'{"fixture":"previous"}\n'
        old_name = f"{hashlib.sha256(old_provenance).hexdigest()}.json"
        old_url = build_site.OFFICIAL_PACK_PROVENANCE_URL + old_name
        old_catalog = (
            json.dumps({"payload": {"packs": [
                {"manifest": {"id": "official.advertising", "source": old_url}},
                {"manifest": {"id": "official.advertising-aggressive", "source": old_url}},
            ]}}) + "\n"
        ).encode()
        (fixture[2] / old_name).write_bytes(old_provenance)
        (fixture[4] / fixture[5]).unlink()
        (fixture[4] / old_name).write_bytes(old_provenance)
        fixture[3].write_bytes(old_catalog)

        def fail_catalog_swap(source, target):
            if pathlib.Path(target) == fixture[3]:
                raise OSError("injected catalog swap failure")
            os.replace(source, target)

        with self.assertRaisesRegex(OSError, "injected catalog swap failure"):
            build_site.publish_official_pack_outputs(
                fixture[1], fixture[3], fixture[2], fixture[4], fixture[0],
                replace=fail_catalog_swap,
            )
        self.assertEqual(fixture[3].read_bytes(), old_catalog)
        self.assertEqual((fixture[4] / old_name).read_bytes(), old_provenance)

    def test_success_publishes_exact_catalog_and_provenance_bytes(self):
        fixture = self.fixture()
        self.publish(fixture)
        self.assertEqual(
            self.snapshot(fixture[3], fixture[4]),
            (fixture[6], {fixture[5]: self.provenance}),
        )

    def test_success_retains_immutable_historical_provenance_after_catalog_swap(self):
        fixture = self.fixture()
        old_provenance = b'{"fixture":"previous"}\n'
        old_name = f"{hashlib.sha256(old_provenance).hexdigest()}.json"
        (fixture[2] / old_name).write_bytes(old_provenance)
        (fixture[4] / fixture[5]).unlink()
        (fixture[4] / old_name).write_bytes(old_provenance)
        self.publish(fixture)
        self.assertEqual(
            self.snapshot(fixture[3], fixture[4]),
            (fixture[6], {
                fixture[5]: self.provenance,
                old_name: old_provenance,
            }),
        )

    def test_stale_paths_include_nested_publication_extras(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            (directory / "current.json").write_bytes(b"current")
            (directory / "nested").mkdir()
            (directory / "nested" / "extra.bin").write_bytes(b"extra")
            self.assertEqual(
                build_site.stale_provenance_paths(directory, {"current.json"}),
                [directory / "nested" / "extra.bin"],
            )


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


class OfficialPackProvenanceTests(unittest.TestCase):
    @staticmethod
    def catalog(source, aggressive_source=None):
        if aggressive_source is None:
            aggressive_source = source
        return json.dumps({"payload": {"packs": [
            {"manifest": {"id": "official.advertising", "source": source}},
            {"manifest": {
                "id": "official.advertising-aggressive", "source": aggressive_source
            }},
        ]}}).encode()

    def test_exact_content_addressed_provenance_passes(self):
        content = b'{"fixture":"reviewed"}\n'
        name = f"{hashlib.sha256(content).hexdigest()}.json"
        source_url = check_site.OFFICIAL_PACK_PROVENANCE_URL + name
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source_dir = root / "site"
            output_dir = root / "docs"
            source_dir.mkdir()
            output_dir.mkdir()
            (source_dir / name).write_bytes(content)
            (output_dir / name).write_bytes(content)
            self.assertEqual(
                check_site.official_pack_provenance_problems(
                    self.catalog(source_url), source_dir, output_dir
                ),
                [],
            )

    def test_valid_historical_content_addressed_provenance_remains_public(self):
        current = b'{"fixture":"current"}\n'
        historical = b'{"fixture":"historical"}\n'
        current_name = f"{hashlib.sha256(current).hexdigest()}.json"
        historical_name = f"{hashlib.sha256(historical).hexdigest()}.json"
        source_url = check_site.OFFICIAL_PACK_PROVENANCE_URL + current_name
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source_dir = root / "site"
            output_dir = root / "docs"
            source_dir.mkdir()
            output_dir.mkdir()
            for directory in (source_dir, output_dir):
                (directory / current_name).write_bytes(current)
                (directory / historical_name).write_bytes(historical)
            self.assertEqual(
                check_site.official_pack_provenance_problems(
                    self.catalog(source_url), source_dir, output_dir
                ),
                [],
            )

    def test_missing_generated_provenance_fails(self):
        content = b'{"fixture":"reviewed"}\n'
        name = f"{hashlib.sha256(content).hexdigest()}.json"
        source_url = check_site.OFFICIAL_PACK_PROVENANCE_URL + name
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source_dir = root / "site"
            output_dir = root / "docs"
            source_dir.mkdir()
            output_dir.mkdir()
            (source_dir / name).write_bytes(content)
            self.assertIn(
                "docs/packs/v1/provenance: archive does not exactly match the site provenance archive",
                check_site.official_pack_provenance_problems(
                    self.catalog(source_url), source_dir, output_dir
                ),
            )

    def test_nested_extra_provenance_fails_exact_set(self):
        content = b'{"fixture":"reviewed"}\n'
        name = f"{hashlib.sha256(content).hexdigest()}.json"
        source_url = check_site.OFFICIAL_PACK_PROVENANCE_URL + name
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source_dir = root / "site"
            output_dir = root / "docs"
            source_dir.mkdir()
            output_dir.mkdir()
            (source_dir / name).write_bytes(content)
            (output_dir / name).write_bytes(content)
            (source_dir / "nested").mkdir()
            (output_dir / "nested").mkdir()
            (source_dir / "nested" / "extra.bin").write_bytes(b"extra")
            (output_dir / "nested" / "extra.json").write_bytes(b"extra")

            problems = check_site.official_pack_provenance_problems(
                self.catalog(source_url), source_dir, output_dir
            )
            self.assertIn(
                "site/packs/v1/provenance/nested/extra.bin: is not a flat content-addressed JSON path",
                problems,
            )
            self.assertIn(
                "docs/packs/v1/provenance: archive does not exactly match the site provenance archive",
                problems,
            )

    def test_wrong_content_address_fails(self):
        content = b'{"fixture":"tampered"}\n'
        name = f"{'0' * 64}.json"
        source_url = check_site.OFFICIAL_PACK_PROVENANCE_URL + name
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source_dir = root / "site"
            output_dir = root / "docs"
            source_dir.mkdir()
            output_dir.mkdir()
            (source_dir / name).write_bytes(content)
            (output_dir / name).write_bytes(content)
            self.assertIn(
                f"site/packs/v1/provenance/{name}: content digest does not match its filename",
                check_site.official_pack_provenance_problems(
                    self.catalog(source_url), source_dir, output_dir
                ),
            )

    def test_unpinned_provenance_origin_fails(self):
        with self.assertRaisesRegex(ValueError, "content-addressed provenance"):
            check_site.catalog_provenance_names(
                self.catalog("https://example.com/provenance/review.json")
            )

    def test_one_advertising_pack_with_plain_source_fails(self):
        content = b'{"fixture":"reviewed"}\n'
        name = f"{hashlib.sha256(content).hexdigest()}.json"
        source_url = check_site.OFFICIAL_PACK_PROVENANCE_URL + name
        with self.assertRaisesRegex(ValueError, "content-addressed provenance"):
            check_site.catalog_provenance_names(self.catalog(source_url, "manual notes"))


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
            '<a href=https://www.apple.com/app-store/>Download from Apple</a>',
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
