# -*- coding: utf-8 -*-
"""Tests for _chain_tier_allowed gating in the CLI path.

Note: _chain_tier_allowed reads FALLBACK_ENGINE_OVERRIDE at call time and only
consults the module-level ENGINE_CHAIN_FALLBACK constant as the default case.
Tests patch the env var directly and, when they need to exercise the default
path, override the module constant with mock.patch to avoid a module reload
(importlib.reload leaks class identities across test files).
"""

import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src import converter


class TestChainTierAllowed(unittest.TestCase):
    def test_override_none_blocks_all_tiers(self):
        with (
            patch.dict(os.environ, {"FALLBACK_ENGINE_OVERRIDE": "none"}, clear=False),
            patch.object(converter, "ENGINE_CHAIN_FALLBACK", True),
        ):
            self.assertFalse(converter._chain_tier_allowed("kokoro"))
            self.assertFalse(converter._chain_tier_allowed("piper"))

    def test_override_piper_only_allows_piper(self):
        env = dict(os.environ)
        env["FALLBACK_ENGINE_OVERRIDE"] = "piper"
        env.pop("ENGINE_CHAIN_FALLBACK", None)
        with patch.dict(os.environ, env, clear=True):
            self.assertFalse(converter._chain_tier_allowed("kokoro"))
            self.assertTrue(converter._chain_tier_allowed("piper"))

    def test_override_auto_respects_chain_flag(self):
        env = dict(os.environ)
        env.pop("FALLBACK_ENGINE_OVERRIDE", None)
        with (
            patch.dict(os.environ, env, clear=True),
            patch.object(converter, "ENGINE_CHAIN_FALLBACK", True),
        ):
            self.assertTrue(converter._chain_tier_allowed("kokoro"))
            self.assertTrue(converter._chain_tier_allowed("piper"))

    def test_default_blocks_all_tiers(self):
        env = dict(os.environ)
        env.pop("FALLBACK_ENGINE_OVERRIDE", None)
        env.pop("ENGINE_CHAIN_FALLBACK", None)
        with (
            patch.dict(os.environ, env, clear=True),
            patch.object(converter, "ENGINE_CHAIN_FALLBACK", False),
        ):
            self.assertFalse(converter._chain_tier_allowed("kokoro"))
            self.assertFalse(converter._chain_tier_allowed("piper"))


if __name__ == "__main__":
    unittest.main()
