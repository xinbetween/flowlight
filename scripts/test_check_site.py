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


if __name__ == "__main__":
    unittest.main()
