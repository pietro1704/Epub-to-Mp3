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


class TestProgressTrackerMonotonic(unittest.TestCase):
    def test_percentage_never_decreases_across_parallel_chapters(self):
        tracker = ProgressTracker(total_chapters=10)
        tracker.start(10)
        tracker.completed_chapters = 5
        tracker.current_index = 6
        tracker.total_chunks = 10
        tracker.processed_chunks = 9
        tracker._chunks_confident = True
        high = tracker._progress_percentage()

        # Simulate switching display to another active chapter at earlier chunks
        tracker.current_index = 7
        tracker.total_chunks = 20
        tracker.processed_chunks = 2
        low = tracker._progress_percentage()
        self.assertGreaterEqual(low, high)

    def test_percentage_floor_matches_completed_ratio(self):
        tracker = ProgressTracker(total_chapters=4)
        tracker.start(4)
        tracker.completed_chapters = 3
        tracker.current_index = 4
        tracker.total_chunks = 10
        tracker.processed_chunks = 0
        pct = tracker._progress_percentage()
        self.assertGreaterEqual(pct, 75.0)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
