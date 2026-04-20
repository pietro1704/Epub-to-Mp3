# -*- coding: utf-8 -*-
"""Tests for _chain_tier_allowed gating in the CLI path."""

import importlib
import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


class TestChainTierAllowed(unittest.TestCase):
    def _reload(self):
        import src.converter as converter

        return importlib.reload(converter)

    def test_override_none_blocks_all_tiers(self):
        env = {"FALLBACK_ENGINE_OVERRIDE": "none", "ENGINE_CHAIN_FALLBACK": "1"}
        with patch.dict(os.environ, env, clear=False):
            converter = self._reload()
            self.assertFalse(converter._chain_tier_allowed("kokoro"))
            self.assertFalse(converter._chain_tier_allowed("piper"))

    def test_override_piper_only_allows_piper(self):
        with patch.dict(os.environ, {"FALLBACK_ENGINE_OVERRIDE": "piper"}, clear=False):
            os.environ.pop("ENGINE_CHAIN_FALLBACK", None)
            converter = self._reload()
            self.assertFalse(converter._chain_tier_allowed("kokoro"))
            self.assertTrue(converter._chain_tier_allowed("piper"))

    def test_override_auto_respects_chain_flag(self):
        with patch.dict(os.environ, {"ENGINE_CHAIN_FALLBACK": "1"}, clear=False):
            os.environ.pop("FALLBACK_ENGINE_OVERRIDE", None)
            converter = self._reload()
            self.assertTrue(converter._chain_tier_allowed("kokoro"))
            self.assertTrue(converter._chain_tier_allowed("piper"))

    def test_default_blocks_all_tiers(self):
        env = dict(os.environ)
        env.pop("FALLBACK_ENGINE_OVERRIDE", None)
        env.pop("ENGINE_CHAIN_FALLBACK", None)
        with patch.dict(os.environ, env, clear=True):
            converter = self._reload()
            self.assertFalse(converter._chain_tier_allowed("kokoro"))
            self.assertFalse(converter._chain_tier_allowed("piper"))

    @classmethod
    def tearDownClass(cls):
        import src.converter as converter

        importlib.reload(converter)


if __name__ == "__main__":
    unittest.main()
