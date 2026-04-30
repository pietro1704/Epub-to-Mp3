"""Silence padding must match the source's sample rate.

Carl Capa regression (v0.3.21): Edge produces 24 kHz MP3, but
`add_silence_padding` defaulted to `sample_rate=16000` for both the
intro and outro silence fragments. The concat-copy path then merged
16 kHz silence + 24 kHz Edge audio + 16 kHz silence into a single MP3.
Decoders pick up the *first* frame's sample rate (16 kHz), so the
listener heard the entire chapter as if it were Piper output — wrong
language phonemes, robotic timbre, the lot.

These tests pin the auto-detection helper and the integration site:
the function MUST probe the source rate and override the default
when it differs.
"""

from __future__ import annotations

import inspect
import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.audio_postprocess import _detect_audio_sample_rate, add_silence_padding


class TestSilencePaddingSampleRate(unittest.TestCase):
    def test_detect_helper_returns_none_for_missing_file(self):
        result = _detect_audio_sample_rate(__file__ + "_does_not_exist")
        self.assertIsNone(result)

    def test_function_detects_rate_before_using_caller_default(self):
        """Source-level guard: ``add_silence_padding`` must call
        ``_detect_audio_sample_rate`` before generating silence fragments.

        Anything weaker would let a future refactor reintroduce the
        16 kHz hardcoded default for an Edge (24 kHz) output.
        """
        src = inspect.getsource(add_silence_padding)
        self.assertIn("_detect_audio_sample_rate", src)
        self.assertIn("sample_rate = detected_rate", src)


class TestDetectAudioSampleRateBranches(unittest.TestCase):
    def _mock_subprocess_run(self, returncode: int, stdout: str):
        from unittest.mock import MagicMock

        result = MagicMock()
        result.returncode = returncode
        result.stdout = stdout
        return result

    def test_returns_int_for_well_formed_probe_output(self):
        import subprocess as real_subprocess

        with patch.object(
            real_subprocess,
            "run",
            return_value=self._mock_subprocess_run(0, "24000\n"),
        ):
            result = _detect_audio_sample_rate("/some/path.mp3")
            self.assertEqual(result, 24000)

    def test_returns_none_on_nonzero_exit(self):
        import subprocess as real_subprocess

        with patch.object(
            real_subprocess,
            "run",
            return_value=self._mock_subprocess_run(1, ""),
        ):
            result = _detect_audio_sample_rate("/some/path.mp3")
            self.assertIsNone(result)

    def test_returns_none_when_stdout_is_not_numeric(self):
        import subprocess as real_subprocess

        with patch.object(
            real_subprocess,
            "run",
            return_value=self._mock_subprocess_run(0, "garbage\n"),
        ):
            result = _detect_audio_sample_rate("/some/path.mp3")
            self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
