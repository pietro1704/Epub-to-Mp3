"""Inject silence post-synthesis to give chapter titles a real pause.

Edge plain-text caps inter-sentence silence at ~700 ms regardless of
punctuation density. A chapter announcement like "Capítulo 1." running
straight into the body without a real beat sounds rushed; the user
reported "ainda sem pausa" / "deveria perceber sozinho".

The fix: detect the natural silence Edge produces after the title via
`silencedetect`, then splice an extra 1 s of silence at that point.
"""

from __future__ import annotations

import inspect
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.audio_postprocess import (
    find_first_silence_after_title,
    inject_silence_at_offset,
)


class TestInjectSilenceHelpers(unittest.TestCase):
    def test_find_first_silence_after_title_signature(self):
        sig = inspect.signature(find_first_silence_after_title)
        self.assertIn("min_search_offset", sig.parameters)
        self.assertIn("max_search_offset", sig.parameters)
        self.assertEqual(sig.parameters["min_search_offset"].default, 0.5)
        self.assertEqual(sig.parameters["max_search_offset"].default, 12.0)

    def test_inject_signature_takes_seconds_and_ms(self):
        sig = inspect.signature(inject_silence_at_offset)
        self.assertIn("insert_at_seconds", sig.parameters)
        self.assertIn("silence_ms", sig.parameters)
        self.assertEqual(sig.parameters["silence_ms"].default, 1000)

    def test_converter_calls_injection_after_apply_silence_padding(self):
        from src import converter

        src = inspect.getsource(converter)
        self.assertIn("find_first_silence_after_title", src)
        self.assertIn("inject_silence_at_offset", src)
        self.assertIn("silence_ms=1000", src)


if __name__ == "__main__":
    unittest.main()
