# -*- coding: utf-8 -*-
"""Tests for progress ETA behavior."""

from __future__ import annotations

import unittest

from src.progress import ProgressTracker


class TestProgressTrackerEta(unittest.TestCase):
    def test_eta_prefers_runtime_hint_when_available(self):
        tracker = ProgressTracker(total_chapters=10)
        tracker.start(10)
        tracker.completed_chapters = 2
        tracker.update_eta_hint(remaining_chars=20_000, chars_per_second=200.0)

        eta = tracker._eta_seconds(elapsed=30.0)
        self.assertAlmostEqual(eta, 100.0, places=3)

    def test_eta_falls_back_without_hint(self):
        tracker = ProgressTracker(total_chapters=10)
        tracker.start(10)
        tracker.completed_chapters = 3
        tracker.current_index = 4
        tracker.total_chars = 1000
        tracker.processed_chars = 500

        eta = tracker._eta_seconds(elapsed=40.0)
        self.assertGreater(eta, 0.0)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
