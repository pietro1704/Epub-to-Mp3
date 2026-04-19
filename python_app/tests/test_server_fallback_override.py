# -*- coding: utf-8 -*-
"""Tests for FALLBACK_ENGINE_OVERRIDE (server-side mirror of CLI flag)."""

import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src._server_engine_helpers import _build_engine_chain, _fallback_engine_override
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
        with patch.dict(os.environ, {"FALLBACK_ENGINE_OVERRIDE": "piper"}, clear=False):
            chain = _build_engine_chain(cfg)
        fallback_engines = [c.engine for c in chain[1:] if c.engine != "edge"]
        self.assertNotIn("kokoro", fallback_engines)
        self.assertNotIn("coqui", fallback_engines)


if __name__ == "__main__":
    unittest.main()
