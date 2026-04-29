"""Truncation heuristic stays out of the way for PT-BR dialogue audio.

Background — `feedback_truncation_tolerance.md`. The 2026-04-29 Carl run
had a 32-minute MP3 (real, ffprobe) flagged as truncated because
chars/WPM expected ~38 minutes; the cache was deleted and re-synthesised
pointlessly. New default ratio: 0.50 (was 0.60), env-tunable.
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src._output_file_mixin import _OutputFileMixin


class _Host(_OutputFileMixin):
    """Minimal harness — the mixin only reads from path + config."""

    def __init__(self, actual_seconds: float, file_size: int):
        self._actual = actual_seconds
        self._size = file_size

    def _probe_audio_duration(self, path):
        return self._actual

    # `_expected_audio_bytes` and `_bitrate_to_bps` come from the mixin;
    # nothing to override.


class TestTruncationTolerance(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path("/tmp/test-truncation.mp3")
        self.tmp.write_bytes(b"x" * 5_000_000)  # 5 MB placeholder
        self.config = SimpleNamespace(bitrate="8k", engine="edge")

    def tearDown(self) -> None:
        if self.tmp.exists():
            self.tmp.unlink()

    def _payload(self, word_count: int) -> str:
        # `TextValidator.estimate_duration` counts words (not chars), so
        # synth realistic word-spaced text. WPM 150 → 0.4 s/word.
        return ("palavra " * word_count).strip()

    def test_carl_capitulo_4_real_audio_no_longer_flagged(self):
        """The exact failure scenario from the Carl conversion: 32 min
        of valid audio with chars/WPM expecting ~38 min. Old code at
        ratio 0.60 flagged it; new default 0.50 keeps it.

        5700 words → estimate ~2280s. Actual 1925s → ratio 0.84, passes.
        """
        host = _Host(actual_seconds=1925, file_size=12_500_000)
        host.file_manager = None  # not used by this method
        result = host._detect_short_audio_output(
            self.tmp,
            self._payload(5700),
            self.config,
        )
        self.assertIsNone(result)

    def test_genuinely_short_audio_still_flagged(self):
        """We must keep catching real truncations — 25% of expected is
        nowhere near tolerable, the listener will notice."""
        # estimate ~2280s; actual 500s → ratio 0.22, well below default 0.50.
        host = _Host(actual_seconds=500, file_size=2_500_000)
        host.file_manager = None
        result = host._detect_short_audio_output(
            self.tmp,
            self._payload(5700),
            self.config,
        )
        self.assertIsNotNone(result)
        self.assertIn("truncated", result)

    def test_strict_mode_via_env_var(self):
        """Operators that need tighter checks (archival masters,
        accessibility-grade audiobooks) can set the legacy 60% threshold."""
        # 1250s / 2280s ≈ 0.55 — passes default 0.50 but fails strict 0.65.
        host = _Host(actual_seconds=1250, file_size=6_500_000)
        host.file_manager = None
        with patch.dict(os.environ, {"EDGE_TRUNCATION_RATIO": "0.65"}):
            result = host._detect_short_audio_output(
                self.tmp,
                self._payload(5700),
                self.config,
            )
        self.assertIsNotNone(result)

    def test_invalid_env_var_falls_back_to_default(self):
        host = _Host(actual_seconds=1250, file_size=6_500_000)
        host.file_manager = None
        with patch.dict(os.environ, {"EDGE_TRUNCATION_RATIO": "garbage"}):
            result = host._detect_short_audio_output(
                self.tmp,
                self._payload(5700),
                self.config,
            )
        # Default 0.50 — 0.55 ratio passes.
        self.assertIsNone(result)

    def test_short_chapters_skip_validation_entirely(self):
        """Chapters under 2000 chars never trigger the heuristic — they
        are too small to estimate reliably and Edge synthesises them in
        one shot anyway."""
        host = _Host(actual_seconds=10, file_size=80_000)
        host.file_manager = None
        result = host._detect_short_audio_output(
            self.tmp,
            self._payload(50),  # < 2000 chars
            self.config,
        )
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
