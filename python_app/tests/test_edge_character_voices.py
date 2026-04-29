"""Integration: verify Edge engine routes dialogue spans to ``character_voice``."""

from __future__ import annotations

import os
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.tts import edge_engine
from src.tts.edge_engine import EdgeTTSEngine


class TestEdgeCharacterVoices(unittest.TestCase):
    """Drive ``_prepare_segments`` with a payload that contains both narration
    and dialogue and assert each role lands on the correct voice."""

    def setUp(self) -> None:
        self._original_edge_tts = edge_engine.edge_tts
        edge_engine.edge_tts = Mock()

    def tearDown(self) -> None:
        edge_engine.edge_tts = self._original_edge_tts

    def _voices_seen(self, segments) -> set[str]:
        return {voice for voice, _ in segments}

    def test_disabled_keeps_single_voice(self):
        """Default off (or single-voice config) must leave behaviour unchanged."""
        engine = EdgeTTSEngine(
            "narrator-voice",
            enable_character_voices=False,
        )
        text = "Ele andou. \u201cOl\u00e1\u201d, disse ele."
        segments = engine._prepare_segments(text)
        # Every segment uses the single voice we passed in.
        self.assertEqual(self._voices_seen(segments), {"narrator-voice"})

    def test_enabled_with_identical_voices_is_noop(self):
        """If narrator and character voices are the same, splitting is wasted
        work — the engine must short-circuit and use a single voice."""
        engine = EdgeTTSEngine(
            "shared-voice",
            enable_character_voices=True,
            narrator_voice="shared-voice",
            character_voice="shared-voice",
        )
        text = "Andou. \u201cOl\u00e1\u201d, disse."
        segments = engine._prepare_segments(text)
        self.assertEqual(self._voices_seen(segments), {"shared-voice"})

    def test_enabled_routes_quoted_dialogue_to_character_voice(self):
        engine = EdgeTTSEngine(
            "narrator-voice",
            enable_character_voices=True,
            narrator_voice="narrator-voice",
            character_voice="character-voice",
        )
        text = "Ela parou na porta. \u201cBom dia\u201d, ele respondeu, " "olhando para cima."
        segments = engine._prepare_segments(text)

        voices = self._voices_seen(segments)
        self.assertIn("narrator-voice", voices)
        self.assertIn("character-voice", voices)

        # The character voice must carry the dialogue content.
        char_text = " ".join(text for voice, text in segments if voice == "character-voice")
        self.assertIn("Bom dia", char_text)

        # The narrator voice must NOT carry the dialogue content (otherwise
        # the listener hears the same line twice in different voices).
        narrator_text = " ".join(text for voice, text in segments if voice == "narrator-voice")
        self.assertNotIn("Bom dia", narrator_text)

    def test_enabled_routes_em_dash_lines_to_character_voice(self):
        engine = EdgeTTSEngine(
            "narrator-voice",
            enable_character_voices=True,
            narrator_voice="narrator-voice",
            character_voice="character-voice",
        )
        text = "Sala silenciosa.\n\u2014 Quem est\u00e1 a\u00ed?\nEle aguardou."
        segments = engine._prepare_segments(text)

        voices = self._voices_seen(segments)
        self.assertIn("character-voice", voices)
        char_text = " ".join(text for voice, text in segments if voice == "character-voice")
        self.assertIn("Quem est\u00e1 a\u00ed", char_text)


if __name__ == "__main__":
    unittest.main()
