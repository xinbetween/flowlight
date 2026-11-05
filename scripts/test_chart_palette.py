#!/usr/bin/env python3
"""Fail-capable tests for the Flowlight chart palette contract."""

from __future__ import annotations

import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/check_chart_palette.py"
SPEC = importlib.util.spec_from_file_location("check_chart_palette", MODULE_PATH)
assert SPEC and SPEC.loader
PALETTE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PALETTE)
SOURCE = ROOT / "Flowlight/UI/DesignTokens.swift"


class ChartPaletteTests(unittest.TestCase):
    def test_committed_light_and_dark_palettes_pass(self):
        tokens = PALETTE.parse_tokens(SOURCE.read_text(encoding="utf-8"))
        self.assertEqual(PALETTE.validate(tokens), [])

    def test_directional_collision_is_rejected_under_normal_and_cvd_vision(self):
        tokens = PALETTE.parse_tokens(SOURCE.read_text(encoding="utf-8"))
        tokens["sent"] = dict(tokens["received"])
        issues = PALETTE.validate(tokens)
        joined = "\n".join(issues)
        self.assertIn("directional received/sent normal Delta E", joined)
        self.assertIn("directional received/sent protan Delta E", joined)
        self.assertIn("directional received/sent deutan Delta E", joined)

    def test_low_contrast_mark_is_rejected_in_both_modes(self):
        tokens = PALETTE.parse_tokens(SOURCE.read_text(encoding="utf-8"))
        tokens["received"] = dict(tokens["surface"])
        issues = "\n".join(PALETTE.validate(tokens))
        self.assertIn("light received contrast", issues)
        self.assertIn("dark received contrast", issues)

    def test_missing_semantic_token_fails_closed(self):
        tokens = PALETTE.parse_tokens(SOURCE.read_text(encoding="utf-8"))
        del tokens["graphInvocation"]
        self.assertEqual(PALETTE.validate(tokens), ["missing semantic token: graphInvocation"])


if __name__ == "__main__":
    unittest.main()
