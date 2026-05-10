"""When the user picks a non-Edge engine but configured narrator/character
voices, the factory prints a clear warning so the silent ignore stops
being a silent ignore.

The dialogue splitter (v0.3.7) routes quoted spans to the
`character_voice` and the rest to the `narrator_voice`, but it's wired
only into Edge-TTS so far. Without this warning, a user picking Piper
or Kokoro through the web form sees no immediate signal that their
voice config is being dropped — they only find out when the resulting
MP3 has a single voice throughout.
"""

from __future__ import annotations

import io
import os
import sys
import unittest
from contextlib import redirect_stderr
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.config import ConversionConfig
from src.tts.factory import TTSFactory


class TestMultiVoiceEdgeOnlyWarning(unittest.TestCase):
    def _capture_stderr(self, config: ConversionConfig) -> str:
        buf = io.StringIO()
        # Patch the engine constructor so we don't actually try to load
        # Piper/Kokoro/Coqui — we just want to observe the warning.
        with (
            redirect_stderr(buf),
            patch.object(
                TTSFactory, "create_engine", side_effect=TTSFactory.create_engine, autospec=True
            ),
        ):
            try:
                TTSFactory().create_engine(config)
            except Exception:
                # The factory raises when the chosen engine isn't installed
                # locally — that's fine for the warning test, the print is
                # emitted before the import lookup.
                pass
        return buf.getvalue()

    def test_warning_fires_for_unsupported_engine_with_split_voices(self):
        # Engines outside the supported set ("edge", "piper", "kokoro") cause
        # multi-voice configs to be silently ignored, so the factory must
        # emit the warning.
        cfg = ConversionConfig(
            engine="unknown",
            primary_language="en",
            enable_character_voices=True,
            narrator_voice="speaker-A",
            character_voice="speaker-B",
        )
        stderr = self._capture_stderr(cfg)
        self.assertIn("Multi-voice narration", stderr)
        self.assertIn("unknown", stderr)

    def test_no_warning_for_kokoro_with_split_voices(self):
        # v0.3.20 wired multi-voice into Kokoro; warning would mislead.
        cfg = ConversionConfig(
            engine="kokoro",
            primary_language="en",
            enable_character_voices=True,
            narrator_voice="af_heart",
            character_voice="bf_heart",
        )
        stderr = self._capture_stderr(cfg)
        self.assertNotIn("Multi-voice narration", stderr)

    def test_no_warning_for_piper_with_split_voices(self):
        # v0.3.18 wired multi-voice into Piper; the warning would be
        # misleading now.
        cfg = ConversionConfig(
            engine="piper",
            primary_language="pt-BR",
            enable_character_voices=True,
            narrator_voice="/some/narrator.onnx",
            character_voice="/some/character.onnx",
        )
        stderr = self._capture_stderr(cfg)
        self.assertNotIn("Multi-voice narration", stderr)

    def test_no_warning_when_engine_is_edge(self):
        cfg = ConversionConfig(
            engine="edge",
            primary_language="pt-BR",
            enable_character_voices=True,
            narrator_voice="pt-BR-AntonioNeural",
            character_voice="pt-BR-FranciscaNeural",
        )
        stderr = self._capture_stderr(cfg)
        self.assertNotIn("Multi-voice narration", stderr)

    def test_no_warning_when_voices_are_identical(self):
        # Same voice → splitter would be a no-op even on Edge, so the
        # other engines are not "missing" anything.
        cfg = ConversionConfig(
            engine="unknown",
            primary_language="en",
            enable_character_voices=True,
            narrator_voice="speaker-A",
            character_voice="speaker-A",
        )
        stderr = self._capture_stderr(cfg)
        self.assertNotIn("Multi-voice narration", stderr)

    def test_no_warning_when_split_disabled(self):
        cfg = ConversionConfig(
            engine="unknown",
            primary_language="pt-BR",
            enable_character_voices=False,
            narrator_voice="a",
            character_voice="b",
        )
        stderr = self._capture_stderr(cfg)
        self.assertNotIn("Multi-voice narration", stderr)


if __name__ == "__main__":
    unittest.main()
