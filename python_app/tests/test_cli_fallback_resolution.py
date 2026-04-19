# -*- coding: utf-8 -*-
"""Tests for CLI fallback-engine resolution (flag vs env var)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import _resolve_cli_fallback_engine


class TestResolveCliFallbackEngine(unittest.TestCase):
    def test_flag_wins_over_env(self):
        self.assertEqual(_resolve_cli_fallback_engine("piper", "kokoro"), "piper")

    def test_env_used_when_flag_auto(self):
        self.assertEqual(_resolve_cli_fallback_engine("auto", "piper"), "piper")

    def test_none_when_both_auto(self):
        self.assertIsNone(_resolve_cli_fallback_engine("auto", "auto"))

    def test_none_when_both_missing(self):
        self.assertIsNone(_resolve_cli_fallback_engine(None, None))

    def test_invalid_env_ignored(self):
        self.assertIsNone(_resolve_cli_fallback_engine("auto", "garbage"))

    def test_env_none_propagates(self):
        self.assertEqual(_resolve_cli_fallback_engine("auto", "none"), "none")


if __name__ == "__main__":
    unittest.main()
