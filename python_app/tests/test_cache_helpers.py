# -*- coding: utf-8 -*-
"""Tests for the pure cache-helper extraction."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src._cache_helpers import compute_cache_model_bucket, hash_text
from src.config import ConversionConfig


class TestComputeCacheModelBucket(unittest.TestCase):
    def test_edge_with_voice(self):
        cfg = ConversionConfig(engine="edge", voice="pt-BR-AntonioNeural")
        self.assertEqual(compute_cache_model_bucket(cfg), "edge__pt-BR-AntonioNeural")

    def test_piper_uses_model_stem(self):
        cfg = ConversionConfig(engine="piper", model_path="/tmp/pt_BR-faber-medium.onnx")
        self.assertEqual(compute_cache_model_bucket(cfg), "piper__pt_BR-faber-medium")

    def test_coqui_prefers_voice_over_model(self):
        cfg = ConversionConfig(
            engine="coqui",
            voice="tts_models/pt/cv/vits",
            model_path="/tmp/ignored.pth",
        )
        bucket = compute_cache_model_bucket(cfg)
        self.assertIn("coqui", bucket)
        self.assertIn("vits", bucket)

    def test_unknown_engine_with_voice(self):
        cfg = ConversionConfig(engine="", voice="something")
        self.assertEqual(compute_cache_model_bucket(cfg), "unknown__something")

    def test_no_voice_or_model_returns_engine_only(self):
        cfg = ConversionConfig(engine="edge")
        self.assertEqual(compute_cache_model_bucket(cfg), "edge")


class TestHashText(unittest.TestCase):
    def test_stable_hash_for_identical_input(self):
        self.assertEqual(hash_text("abc"), hash_text("abc"))

    def test_different_inputs_differ(self):
        self.assertNotEqual(hash_text("abc"), hash_text("abd"))

    def test_non_utf8_does_not_raise(self):
        hash_text("naïve — em português")


if __name__ == "__main__":
    unittest.main()
