"""Kokoro engine routes dialogue spans to a separate character voice.

Mirror of `test_piper_character_voices.py` for Kokoro. Two different
Kokoro voice IDs configure narrator + character; the dialogue splitter
in `synthesize_async` decides which voice synthesises each span.

Doesn't drive the actual Kokoro pipeline (which needs the model
download + ONNX runtime). Instead, mocks `_synthesize_chunk_sync` to
record (voice, text) pairs and asserts the routing.
"""

from __future__ import annotations

import asyncio
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


def _make_engine(**overrides):
    # Patch the language guard so we can instantiate without loading
    # Kokoro on the CI host.
    with patch("src.tts.kokoro_engine.kokoro_supports_language", return_value=True):
        from src.tts.kokoro_engine import KokoroTTSEngine

        kwargs = dict(
            voice="af_heart",
            primary_language="en",
            enable_character_voices=True,
            narrator_voice="af_heart",
            character_voice="bf_heart",
        )
        kwargs.update(overrides)
        return KokoroTTSEngine(**kwargs)


class TestKokoroCharacterVoicesConfig(unittest.TestCase):
    def test_distinct_voices_enable_split(self):
        engine = _make_engine()
        self.assertTrue(engine.enable_character_voices)
        self.assertEqual(engine.narrator_voice, "af_heart")
        self.assertEqual(engine.character_voice, "bf_heart")

    def test_identical_voices_disable_split(self):
        engine = _make_engine(character_voice="af_heart")
        self.assertFalse(engine.enable_character_voices)

    def test_empty_voice_falls_back_to_main(self):
        engine = _make_engine(narrator_voice="", character_voice="")
        # Both fall back to the main voice — no split.
        self.assertEqual(engine.narrator_voice, "af_heart")
        self.assertFalse(engine.enable_character_voices)

    def test_disabled_flag_keeps_split_off(self):
        engine = _make_engine(enable_character_voices=False)
        self.assertFalse(engine.enable_character_voices)


class TestKokoroDialogueRouting(unittest.TestCase):
    """End-to-end: with a quoted text payload, narrator and character
    voices must BOTH appear in the synthesis call list."""

    def test_routes_quoted_dialogue_to_character_voice(self):
        engine = _make_engine()
        text = "Ele andou ate a porta. \u201cBom dia\u201d, ele disse, olhando ao redor."
        output_path = Path("/tmp/test_kokoro_dialogue.wav")

        # Mock the heavy dependencies that would require a real Kokoro
        # install. We only want to observe the (lang_code, voice, text)
        # tuples passed into the chunk synthesiser.
        from src.tts import kokoro_engine as _mod

        recorded: list[tuple[str, str, str]] = []

        def fake_chunk_sync(text, lang_code, voice):
            recorded.append((lang_code, voice, text))
            # Return non-None so the engine considers the chunk done.
            return b"\x00" * 100

        # Avoid the real numpy.concatenate / soundfile.write paths.
        fake_np = MagicMock()
        fake_np.concatenate = lambda parts, *_a, **_k: b"".join(parts)
        fake_sf = MagicMock()
        fake_sf.write = lambda *a, **k: None

        with (
            patch.object(_mod, "np", fake_np),
            patch.object(_mod, "sf", fake_sf),
            patch.object(engine, "_synthesize_chunk_sync", side_effect=fake_chunk_sync),
        ):
            asyncio.run(engine.synthesize_async(text, output_path))

        voices_called = {voice for _, voice, _ in recorded}
        self.assertIn("af_heart", voices_called)  # narrator
        self.assertIn("bf_heart", voices_called)  # character

        # The quoted line must have been routed through the character voice.
        char_payloads = [t for _, v, t in recorded if v == "bf_heart"]
        self.assertTrue(
            any("Bom dia" in p for p in char_payloads),
            f"character voice should carry the dialogue, got {char_payloads!r}",
        )

    def test_pure_narration_uses_only_narrator_voice(self):
        engine = _make_engine()
        text = "Apenas narração sem aspas e sem diálogo."
        output_path = Path("/tmp/test_kokoro_narration.wav")

        from src.tts import kokoro_engine as _mod

        recorded: list[tuple[str, str, str]] = []

        def fake_chunk_sync(text, lang_code, voice):
            recorded.append((lang_code, voice, text))
            return b"\x00" * 100

        fake_np = MagicMock()
        fake_np.concatenate = lambda parts, *_a, **_k: b"".join(parts)
        fake_sf = MagicMock()
        fake_sf.write = lambda *a, **k: None

        with (
            patch.object(_mod, "np", fake_np),
            patch.object(_mod, "sf", fake_sf),
            patch.object(engine, "_synthesize_chunk_sync", side_effect=fake_chunk_sync),
        ):
            asyncio.run(engine.synthesize_async(text, output_path))

        voices_called = {voice for _, voice, _ in recorded}
        # Only narrator should fire — splitter found no character role.
        self.assertEqual(voices_called, {"af_heart"})


if __name__ == "__main__":
    unittest.main()
