# -*- coding: utf-8 -*-
"""Tests for FALLBACK_ENGINE_OVERRIDE (server-side mirror of CLI flag)."""

import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src._server_engine_helpers import (
    _build_engine_chain,
    _engine_chain_fallback_enabled,
    _fallback_engine_override,
    _piper_model_available,
)
from src.config import ConversionConfig


class TestFallbackEngineOverride(unittest.TestCase):
    def test_override_none_returns_none(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("FALLBACK_ENGINE_OVERRIDE", None)
            self.assertIsNone(_fallback_engine_override())

    def test_override_auto_returns_none(self):
        with patch.dict(os.environ, {"FALLBACK_ENGINE_OVERRIDE": "auto"}, clear=False):
            self.assertIsNone(_fallback_engine_override())

    def test_override_specific_engine(self):
        with patch.dict(os.environ, {"FALLBACK_ENGINE_OVERRIDE": "piper"}, clear=False):
            self.assertEqual(_fallback_engine_override(), "piper")

    def test_override_invalid_returns_none(self):
        with patch.dict(os.environ, {"FALLBACK_ENGINE_OVERRIDE": "garbage"}, clear=False):
            self.assertIsNone(_fallback_engine_override())

    def test_override_none_strips_fallbacks(self):
        cfg = ConversionConfig(engine="edge", voice="en-US-JennyNeural", primary_language="en")
        with patch.dict(os.environ, {"FALLBACK_ENGINE_OVERRIDE": "none"}, clear=False):
            chain = _build_engine_chain(cfg)
        engines = [c.engine for c in chain]
        self.assertNotIn("piper", engines)
        self.assertNotIn("kokoro", engines)
        self.assertNotIn("coqui", engines)

    def test_override_specific_filters_to_single_engine(self):
        cfg = ConversionConfig(engine="edge", voice="en-US-JennyNeural", primary_language="en")
        env = {"FALLBACK_ENGINE_OVERRIDE": "piper", "ENGINE_CHAIN_FALLBACK": "1"}
        with patch.dict(os.environ, env, clear=False):
            chain = _build_engine_chain(cfg)
        fallback_engines = [c.engine for c in chain[1:] if c.engine != "edge"]
        self.assertNotIn("kokoro", fallback_engines)
        self.assertNotIn("coqui", fallback_engines)

    def test_explicit_piper_fallback_still_requires_installed_model(self):
        with patch("src._server_engine_helpers._piper_model_available", return_value=False):
            cfg = ConversionConfig(engine="edge", voice="en-US-JennyNeural", primary_language="en")
            with patch.dict(
                os.environ,
                {"FALLBACK_ENGINE_OVERRIDE": "piper", "ENGINE_CHAIN_FALLBACK": "1"},
                clear=False,
            ):
                chain = _build_engine_chain(cfg)
        self.assertNotIn("piper", [candidate.engine for candidate in chain])

    def test_piper_model_probe_is_false_when_factory_has_no_model(self):
        with patch("python_app.server.tts_factory._find_piper_model", side_effect=FileNotFoundError):
            self.assertFalse(_piper_model_available("pt-BR"))


class TestEngineChainFallbackGate(unittest.TestCase):
    def test_chain_fallback_flag_defaults_off(self):
        env = dict(os.environ)
        env.pop("ENGINE_CHAIN_FALLBACK", None)
        with patch.dict(os.environ, env, clear=True):
            self.assertFalse(_engine_chain_fallback_enabled())

    def test_chain_fallback_flag_on(self):
        with patch.dict(os.environ, {"ENGINE_CHAIN_FALLBACK": "1"}, clear=False):
            self.assertTrue(_engine_chain_fallback_enabled())

    def test_default_chain_is_edge_only(self):
        cfg = ConversionConfig(engine="edge", voice="en-US-JennyNeural", primary_language="en")
        env = dict(os.environ)
        env.pop("ENGINE_CHAIN_FALLBACK", None)
        env.pop("FALLBACK_ENGINE_OVERRIDE", None)
        with patch.dict(os.environ, env, clear=True):
            chain = _build_engine_chain(cfg)
        engines = [c.engine for c in chain]
        self.assertTrue(all(e == "edge" for e in engines), f"got {engines}")

    def test_enabling_flag_restores_cascade(self):
        cfg = ConversionConfig(engine="edge", voice="en-US-JennyNeural", primary_language="en")
        with patch.dict(os.environ, {"ENGINE_CHAIN_FALLBACK": "1"}, clear=False):
            os.environ.pop("FALLBACK_ENGINE_OVERRIDE", None)
            with patch("src._server_engine_helpers._piper_model_available", return_value=True):
                chain = _build_engine_chain(cfg)
        engines = {c.engine for c in chain}
        self.assertIn("edge", engines)
        self.assertTrue(engines - {"edge"}, f"expected offline tiers, got {engines}")


if __name__ == "__main__":
    unittest.main()
