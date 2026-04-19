# -*- coding: utf-8 -*-
"""Tests for Piper fallback prefetch in AudioConverter."""

import os
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.converter import AudioConverter


class TestPiperPrefetch(unittest.TestCase):
    def test_prefetch_idempotent(self):
        conv = AudioConverter()
        with patch("src.tts.factory.TTSFactory") as factory:
            with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "0"}, clear=False):
                conv._kick_off_piper_prefetch()
                conv._kick_off_piper_prefetch()
            time.sleep(0.05)
            self.assertLessEqual(factory.call_count, 1)
        self.assertTrue(getattr(conv, "_piper_prefetch_started", False))

    def test_prefetch_skipped_when_env_disabled(self):
        conv = AudioConverter()
        with patch("src.tts.factory.TTSFactory") as factory:
            with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "1"}, clear=False):
                conv._kick_off_piper_prefetch()
            time.sleep(0.05)
            factory.assert_not_called()
        self.assertFalse(getattr(conv, "_piper_prefetch_started", False))

    def test_prefetch_swallows_factory_errors(self):
        conv = AudioConverter()

        def _boom(*_a, **_k):
            raise RuntimeError("no net")

        with patch("src.tts.factory.TTSFactory", side_effect=_boom):
            with patch.dict(os.environ, {"DISABLE_PIPER_FALLBACK": "0"}, clear=False):
                conv._kick_off_piper_prefetch()
            time.sleep(0.05)


if __name__ == "__main__":
    unittest.main()
