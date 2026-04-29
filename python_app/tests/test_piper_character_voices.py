"""Piper engine routes dialogue spans to a separate character model.

Mirror of `test_edge_character_voices.py` for the Piper engine. Two
real ONNX model paths configure narrator + character; the dialogue
splitter inside `_synthesize_with_character_voices` decides which
model handles each span. This test pins the contract so a future
refactor of the splitter integration doesn't silently fall back to
single-voice synthesis.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.tts.piper_engine import PiperTTSEngine


class TestPiperCharacterVoices(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        # Real Piper models are .onnx files; we only need the file to
        # exist for the path-resolver, so a 0-byte file is enough.
        self.narrator_model = self.tmp / "narrator.onnx"
        self.character_model = self.tmp / "character.onnx"
        self.narrator_model.write_bytes(b"")
        self.character_model.write_bytes(b"")
        self.output_path = self.tmp / "out.wav"

    def tearDown(self) -> None:
        import shutil

        shutil.rmtree(self.tmp, ignore_errors=True)

    def _engine(self, **overrides) -> PiperTTSEngine:
        kwargs = dict(
            model_path=self.narrator_model,
            primary_language="pt-BR",
            enable_character_voices=True,
            narrator_voice=str(self.narrator_model),
            character_voice=str(self.character_model),
        )
        kwargs.update(overrides)
        return PiperTTSEngine(**kwargs)

    def test_distinct_models_enable_split(self):
        engine = self._engine()
        self.assertTrue(engine.enable_character_voices)
        self.assertEqual(engine.narrator_model_path, self.narrator_model)
        self.assertEqual(engine.character_model_path, self.character_model)

    def test_identical_models_disable_split(self):
        engine = self._engine(character_voice=str(self.narrator_model))
        # Same file → no point routing.
        self.assertFalse(engine.enable_character_voices)

    def test_missing_voice_path_disables_split(self):
        engine = self._engine(character_voice="/tmp/does-not-exist.onnx")
        self.assertFalse(engine.enable_character_voices)

    def test_disabled_flag_keeps_split_off_even_with_paths(self):
        engine = self._engine(enable_character_voices=False)
        self.assertFalse(engine.enable_character_voices)

    def test_synthesize_with_character_voices_routes_models(self):
        """When dialogue is present, narrator and character models are
        BOTH invoked. Quoted text → character; rest → narrator.

        Skips when numpy/soundfile aren't installed in this test
        environment (the multi-voice path requires them for concat). The
        routing logic itself is engine-independent so the model-pick
        assertions are still meaningful when we mock out the audio I/O.
        """
        from src.tts import piper_engine as _piper_mod

        if _piper_mod.np is None or _piper_mod.sf is None:
            # Mock numpy / soundfile so the concat path proceeds.
            fake_np = MagicMock()
            fake_np.concatenate = lambda chunks, axis=0: b"".join(chunks) if chunks else b""
            fake_sf = MagicMock()
            fake_sf.read = lambda path: (b"x" * 100, 22050)
            fake_sf.write = lambda path, data, sr: Path(path).write_bytes(b"WAV")
            np_patch = patch.object(_piper_mod, "np", fake_np)
            sf_patch = patch.object(_piper_mod, "sf", fake_sf)
        else:
            from contextlib import nullcontext

            np_patch = nullcontext()
            sf_patch = nullcontext()

        engine = self._engine()
        text = "Ele andou ate a porta. \u201cBom dia\u201d, ele disse, sorrindo."

        calls: list[tuple[Path, str]] = []

        async def fake_synth(payload: str, out_path: Path, model: Path) -> Path:
            calls.append((model, payload))
            out_path.write_bytes(b"\x00" * 100)
            return out_path

        import asyncio

        with np_patch, sf_patch, patch.object(engine, "_synthesize_single", side_effect=fake_synth):
            result = asyncio.run(engine._synthesize_with_character_voices(text, self.output_path))

        self.assertIsNotNone(result)

        models_called = {model for model, _ in calls}
        self.assertIn(self.narrator_model, models_called)
        self.assertIn(self.character_model, models_called)

        char_payloads = [p for m, p in calls if m == self.character_model]
        self.assertTrue(
            any("Bom dia" in p for p in char_payloads),
            f"character model should have synthesised the dialogue; got {char_payloads!r}",
        )

    def test_returns_none_when_no_dialogue_present(self):
        """Pure narration: the multi-voice path returns None so the
        single-voice fallback handles it without extra concat overhead."""
        engine = self._engine()
        import asyncio

        result = asyncio.run(
            engine._synthesize_with_character_voices(
                "Apenas narração sem nenhum diálogo entre aspas.",
                self.output_path,
            )
        )
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
