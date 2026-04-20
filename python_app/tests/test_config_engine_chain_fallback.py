# -*- coding: utf-8 -*-
"""Tests for per-job engine_chain_fallback via ConversionConfig (web UI toggle)."""

import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src._server_engine_helpers import _build_engine_chain, _engine_chain_fallback_enabled
from src.config import ConversionConfig


class TestEngineChainFallbackConfigOverride(unittest.TestCase):
    def test_config_true_wins_over_env_unset(self):
        cfg = ConversionConfig(
            engine="edge",
            voice="en-US-JennyNeural",
            primary_language="en",
            engine_chain_fallback=True,
        )
        env = dict(os.environ)
        env.pop("ENGINE_CHAIN_FALLBACK", None)
        env.pop("FALLBACK_ENGINE_OVERRIDE", None)
        with patch.dict(os.environ, env, clear=True):
            self.assertTrue(_engine_chain_fallback_enabled(cfg))
            chain = _build_engine_chain(cfg)
        engines = {c.engine for c in chain}
        self.assertTrue(engines - {"edge"}, f"expected offline tiers, got {engines}")

    def test_config_false_wins_over_env_true(self):
        cfg = ConversionConfig(
            engine="edge",
            voice="en-US-JennyNeural",
            primary_language="en",
            engine_chain_fallback=False,
        )
        with patch.dict(os.environ, {"ENGINE_CHAIN_FALLBACK": "1"}, clear=False):
            os.environ.pop("FALLBACK_ENGINE_OVERRIDE", None)
            self.assertFalse(_engine_chain_fallback_enabled(cfg))
            chain = _build_engine_chain(cfg)
        engines = [c.engine for c in chain]
        self.assertTrue(all(e == "edge" for e in engines), f"got {engines}")

    def test_config_none_defers_to_env(self):
        cfg = ConversionConfig(
            engine="edge",
            voice="en-US-JennyNeural",
            primary_language="en",
            engine_chain_fallback=None,
        )
        with patch.dict(os.environ, {"ENGINE_CHAIN_FALLBACK": "1"}, clear=False):
            self.assertTrue(_engine_chain_fallback_enabled(cfg))


if __name__ == "__main__":
    unittest.main()
