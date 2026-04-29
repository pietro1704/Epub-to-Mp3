"""Tolerance for almost-complete Edge syntheses.

Background — see `feedback_edge_segment_tolerance.md`. On 2026-04-29 a real
conversion of "Carl, o Explorador de Masmorras" produced 25 minutes of valid
audio on disk for a chapter where 41/42 segments succeeded; the conversor
nevertheless reported "0 chapters converted". The test suite locks in the new
behaviour: ≥95% of segments succeeding keeps the MP3.
"""

from __future__ import annotations

import os
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src._output_file_mixin import _OutputFileMixin


class _Host(_OutputFileMixin):
    """Bare host: the mixin only reads from ``tts_engine``, no other state."""


class TestEdgeSegmentTolerance(unittest.TestCase):
    def setUp(self) -> None:
        self.host = _Host()

    def _engine(self, expected: int, generated: int, failed: int):
        return SimpleNamespace(
            last_segment_report={
                "expected": expected,
                "generated": generated,
                "failed": failed,
            },
            partial_failure_detected=False,
        )

    def test_perfect_synthesis_passes(self):
        ok, err = self.host._edge_segment_integrity_ok(self._engine(45, 45, 0))
        self.assertTrue(ok)
        self.assertIsNone(err)

    def test_one_failed_segment_in_42_is_tolerated(self):
        """41/42 = 97.6% — the Carl Capítulo 47 case that triggered the fix."""
        ok, err = self.host._edge_segment_integrity_ok(self._engine(42, 41, 1))
        self.assertTrue(ok)
        self.assertIsNone(err)

    def test_one_failed_segment_in_45_is_tolerated(self):
        """44/45 = 97.7% — the Carl Capítulo 40 case that triggered the fix."""
        ok, err = self.host._edge_segment_integrity_ok(self._engine(45, 44, 1))
        self.assertTrue(ok)

    def test_failure_below_tolerance_still_rejects(self):
        """30/45 = 66.7% — far below 95% threshold, listener WOULD notice."""
        ok, err = self.host._edge_segment_integrity_ok(self._engine(45, 30, 15))
        self.assertFalse(ok)
        self.assertIn("Missing", err or "")

    def test_partial_failure_flag_overrides_tolerance(self):
        """Hard engine failures still disqualify the output — tolerance only
        applies to the missing-segment ratio, not to ``partial_failure_detected``
        which signals an unusable stream (ffmpeg crash, rate-limit storm)."""
        engine = self._engine(42, 41, 1)
        engine.partial_failure_detected = True
        ok, err = self.host._edge_segment_integrity_ok(engine)
        self.assertFalse(ok)
        self.assertIn("Partial failure", err or "")

    def test_env_var_can_force_strict_mode(self):
        """Operators with zero-tolerance requirements can opt out via env."""
        with patch.dict(os.environ, {"EDGE_SEGMENT_OK_RATIO": "1.0"}):
            ok, err = self.host._edge_segment_integrity_ok(self._engine(42, 41, 1))
            self.assertFalse(ok)
            self.assertIn("Missing", err or "")

    def test_invalid_env_var_falls_back_to_default(self):
        with patch.dict(os.environ, {"EDGE_SEGMENT_OK_RATIO": "not-a-number"}):
            ok, err = self.host._edge_segment_integrity_ok(self._engine(42, 41, 1))
            self.assertTrue(ok)


if __name__ == "__main__":
    unittest.main()
