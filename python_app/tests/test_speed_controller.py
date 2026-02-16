# -*- coding: utf-8 -*-
"""Tests for AdaptiveSpeedController per-chapter engine selection."""

from __future__ import annotations

from python_app.src.speed_controller import AdaptiveSpeedController, ChapterPerf


class TestRecommendEngineForChapter:
    """Tests for recommend_engine_for_chapter (size-aware engine selection)."""

    def _make_controller(self) -> AdaptiveSpeedController:
        ctrl = AdaptiveSpeedController()
        # Ensure piper/kokoro buckets exist
        for engine in ("edge", "piper", "kokoro"):
            if engine not in ctrl._history:
                from collections import deque

                ctrl._history[engine] = deque(maxlen=6)
        return ctrl

    def _record(
        self, ctrl: AdaptiveSpeedController, engine: str, chars: int, elapsed: float
    ) -> None:
        ctrl._history[engine].append(
            ChapterPerf(
                index=1,
                name="ch",
                chars=chars,
                elapsed=elapsed,
                success=True,
                error=None,
                from_cache=False,
            )
        )

    # --- Heuristic tests (no history) ---

    def test_short_chapter_prefers_local(self):
        ctrl = self._make_controller()
        pick = ctrl.recommend_engine_for_chapter(2000, ["edge", "piper"])
        assert pick == "piper"

    def test_short_chapter_prefers_kokoro_if_available(self):
        ctrl = self._make_controller()
        pick = ctrl.recommend_engine_for_chapter(3000, ["edge", "kokoro"])
        assert pick == "kokoro"

    def test_long_chapter_prefers_edge(self):
        ctrl = self._make_controller()
        pick = ctrl.recommend_engine_for_chapter(50_000, ["edge", "piper"])
        assert pick == "edge"

    def test_medium_chapter_no_preference(self):
        ctrl = self._make_controller()
        pick = ctrl.recommend_engine_for_chapter(15_000, ["edge", "piper"])
        assert pick is None

    def test_single_engine_returns_none(self):
        ctrl = self._make_controller()
        pick = ctrl.recommend_engine_for_chapter(2000, ["edge"])
        assert pick is None

    def test_empty_engines_returns_none(self):
        ctrl = self._make_controller()
        pick = ctrl.recommend_engine_for_chapter(2000, [])
        assert pick is None

    def test_zero_chars_returns_none(self):
        ctrl = self._make_controller()
        pick = ctrl.recommend_engine_for_chapter(0, ["edge", "piper"])
        assert pick is None

    # --- Data-driven tests (with history) ---

    def test_data_overrides_heuristic_short(self):
        """If Edge is faster for short chapters in practice, pick Edge."""
        ctrl = self._make_controller()
        # Edge: 500 chars/s for short chapters
        self._record(ctrl, "edge", 3000, 6.0)
        # Piper: 100 chars/s for short chapters
        self._record(ctrl, "piper", 3000, 30.0)

        pick = ctrl.recommend_engine_for_chapter(2500, ["edge", "piper"])
        assert pick == "edge"

    def test_data_overrides_heuristic_long(self):
        """If Piper is faster for long chapters in practice, pick Piper."""
        ctrl = self._make_controller()
        # Piper: 200 chars/s for long chapters
        self._record(ctrl, "piper", 40_000, 200.0)
        # Edge: 50 chars/s for long chapters
        self._record(ctrl, "edge", 40_000, 800.0)

        pick = ctrl.recommend_engine_for_chapter(35_000, ["edge", "piper"])
        assert pick == "piper"

    def test_data_uses_correct_bucket(self):
        """History from a different size bucket should not influence decision."""
        ctrl = self._make_controller()
        # Piper fast for SHORT chapters
        self._record(ctrl, "piper", 2000, 2.0)  # 1000 chars/s
        # Edge fast for LONG chapters
        self._record(ctrl, "edge", 40_000, 40.0)  # 1000 chars/s

        # For a MEDIUM chapter — no matching bucket data → heuristic (None)
        pick = ctrl.recommend_engine_for_chapter(15_000, ["edge", "piper"])
        assert pick is None

    def test_data_ignores_failures(self):
        """Failed chapters should not count towards throughput."""
        ctrl = self._make_controller()
        # Edge: one success
        self._record(ctrl, "edge", 3000, 10.0)
        # Piper: only a failure (not counted)
        ctrl._history["piper"].append(
            ChapterPerf(
                index=1,
                name="ch",
                chars=3000,
                elapsed=1.0,
                success=False,
                error="crash",
                from_cache=False,
            )
        )

        pick = ctrl.recommend_engine_for_chapter(2000, ["edge", "piper"])
        # Only edge has valid data for short bucket
        assert pick == "edge"

    def test_data_ignores_cached(self):
        """Cached chapters should not count."""
        ctrl = self._make_controller()
        ctrl._history["piper"].append(
            ChapterPerf(
                index=1,
                name="ch",
                chars=3000,
                elapsed=0.1,
                success=True,
                error=None,
                from_cache=True,
            )
        )
        self._record(ctrl, "edge", 3000, 10.0)

        pick = ctrl.recommend_engine_for_chapter(2000, ["edge", "piper"])
        assert pick == "edge"


class TestSizeBucket:
    def test_buckets(self):
        assert AdaptiveSpeedController._size_bucket(500) == "short"
        assert AdaptiveSpeedController._size_bucket(4999) == "short"
        assert AdaptiveSpeedController._size_bucket(5000) == "medium"
        assert AdaptiveSpeedController._size_bucket(29999) == "medium"
        assert AdaptiveSpeedController._size_bucket(30000) == "long"
        assert AdaptiveSpeedController._size_bucket(100000) == "long"
