"""Recovery path: cleanup + sub-division for failing Edge segments."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.tts import edge_engine
from src.tts.edge_engine import EdgeTTSEngine


def _async_test(coro):
    """Tiny adapter so unittest can drive an async coroutine."""
    import asyncio

    return asyncio.run(coro)


class TestEdgeRecovery(unittest.TestCase):
    def setUp(self) -> None:
        self._original_edge_tts = edge_engine.edge_tts
        edge_engine.edge_tts = Mock()
        self.engine = EdgeTTSEngine("test-voice")
        self.tmp = tempfile.mkdtemp()

    def tearDown(self) -> None:
        edge_engine.edge_tts = self._original_edge_tts
        import shutil

        shutil.rmtree(self.tmp, ignore_errors=True)

    def _output(self, name: str = "out.mp3") -> Path:
        return Path(self.tmp) / name

    def test_cleanup_alone_recovers_segment(self):
        """Step 1 of recovery: dirty payload accepted after sanitisation."""

        # Synthesize succeeds on the second call (after cleanup) and
        # writes a non-empty file. Use a Mock that accepts the call
        # signature and writes bytes to the path.
        async def fake_synth(text, voice, path, *, append):
            # First call: pretend cleanup is needed by writing nothing.
            # Second call: write bytes.
            Path(path).write_bytes(b"\xff\xfb" + b"\x00" * 10)
            return True

        self.engine._synthesize_segment = AsyncMock(side_effect=fake_synth)

        # Dirty input has a soft hyphen and a zero-width joiner — gets stripped.
        original = "co\u00admo\u200ddity normal text."
        out = self._output()

        result = _async_test(self.engine._recover_failed_segment(original, "test-voice", out))
        self.assertTrue(result)
        self.assertTrue(out.exists())
        self.assertGreater(out.stat().st_size, 0)
        # The cleanup branch was reached (cleaned != original).
        # First call uses cleaned text; verify by inspecting mock args.
        call_args = self.engine._synthesize_segment.call_args_list
        self.assertGreaterEqual(len(call_args), 1)
        first_text = call_args[0].args[0]
        self.assertNotIn("\u00ad", first_text)
        self.assertNotIn("\u200d", first_text)

    def test_falls_through_to_subdivision_when_whole_text_fails(self):
        """Step 1 fails → step 2 sub-divides and succeeds per-sentence.

        Use a payload with invisibles so step 1 (cleanup retry) actually
        fires; otherwise the cleanup branch is skipped because the text
        is already clean and we'd jump straight to subdivision.
        """
        call_count = {"n": 0}

        async def fake_synth(text, voice, path, *, append):
            call_count["n"] += 1
            # First call (whole-text recovery attempt) fails.
            if call_count["n"] == 1:
                self.engine.last_error = "no_audio_payload"
                return False
            # Subsequent per-sentence calls succeed and append.
            if append:
                with open(path, "ab") as fh:
                    fh.write(b"\xff\xfb" + b"\x00" * 5)
            else:
                Path(path).write_bytes(b"\xff\xfb" + b"\x00" * 5)
            return True

        self.engine._synthesize_segment = AsyncMock(side_effect=fake_synth)

        # Soft hyphen in word triggers cleanup, so step 1 fires.
        text = "Primei\u00adra frase. Segunda frase. Terceira."
        out = self._output()
        result = _async_test(self.engine._recover_failed_segment(text, "test-voice", out))
        self.assertTrue(result)
        self.assertTrue(out.exists())
        # 1 whole-text attempt + 3 per-sentence calls = 4 total.
        self.assertEqual(call_count["n"], 4)

    def test_returns_false_when_every_attempt_fails(self):
        """Pathological input that no Edge call can synthesise."""

        async def fake_synth(*args, **kwargs):
            self.engine.last_error = "no_audio_payload"
            return False

        self.engine._synthesize_segment = AsyncMock(side_effect=fake_synth)

        text = "Texto que sempre falha. Mais uma frase ruim."
        out = self._output()
        result = _async_test(self.engine._recover_failed_segment(text, "test-voice", out))
        self.assertFalse(result)

    def test_partial_subdivision_success_still_returns_true(self):
        """If 2/3 sub-fragments synth, we keep the audio (better than nothing)."""
        call_count = {"n": 0}

        async def fake_synth(text, voice, path, *, append):
            call_count["n"] += 1
            # Whole-text fails (call 1), then 2 of 3 fragments succeed.
            if call_count["n"] == 1:
                return False
            if call_count["n"] == 3:  # middle fragment fails
                return False
            if append:
                with open(path, "ab") as fh:
                    fh.write(b"\xff\xfb" + b"\x00" * 5)
            else:
                Path(path).write_bytes(b"\xff\xfb" + b"\x00" * 5)
            return True

        self.engine._synthesize_segment = AsyncMock(side_effect=fake_synth)

        text = "Primeira frase. Segunda frase. Terceira frase."
        out = self._output()
        result = _async_test(self.engine._recover_failed_segment(text, "test-voice", out))
        self.assertTrue(result)
        self.assertTrue(out.exists())
        self.assertGreater(out.stat().st_size, 0)

    def test_empty_text_short_circuits(self):
        self.engine._synthesize_segment = AsyncMock(return_value=True)
        out = self._output()
        result = _async_test(self.engine._recover_failed_segment("   ", "test-voice", out))
        self.assertFalse(result)
        # Synth should NOT have been called for empty input.
        self.engine._synthesize_segment.assert_not_called()


if __name__ == "__main__":
    unittest.main()
