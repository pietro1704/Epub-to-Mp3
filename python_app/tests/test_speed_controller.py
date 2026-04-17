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


class TestEngineRankingReliability:
    """Failure rate must penalize the score multiplicatively; user cancels
    must NOT count against the engine."""

    def _append(
        self,
        ctrl: AdaptiveSpeedController,
        engine: str,
        *,
        success: bool,
        chars: int = 4000,
        elapsed: float = 10.0,
        error: str | None = None,
    ) -> None:
        ctrl._history[engine].append(
            ChapterPerf(
                index=1,
                name="ch",
                chars=chars,
                elapsed=elapsed,
                success=success,
                error=error,
                from_cache=False,
            )
        )

    def test_all_success_scores_higher_than_mixed(self):
        good = AdaptiveSpeedController()
        flaky = AdaptiveSpeedController()
        for _ in range(4):
            self._append(good, "edge", success=True)
        # 2 of 4 failures on flaky → ~50% failure rate
        self._append(flaky, "edge", success=True)
        self._append(flaky, "edge", success=False, error="boom")
        self._append(flaky, "edge", success=True)
        self._append(flaky, "edge", success=False, error="boom")

        good_score, _ = good._calculate_engine_score("edge")
        flaky_score, _ = flaky._calculate_engine_score("edge")
        assert good_score > flaky_score
        # Quadratic-ish penalty: flaky drops to less than 60% of good.
        assert flaky_score < good_score * 0.6

    def test_user_cancellation_does_not_penalize(self):
        """A chapter cancelled by the user must not drag the engine's score
        down — the engine did nothing wrong."""
        ctrl_real_fail = AdaptiveSpeedController()
        ctrl_cancel = AdaptiveSpeedController()
        # Both: 2 successes + 1 negative outcome. One is a real failure, one
        # is a cancellation — only the real failure should hurt the score.
        for _ in range(2):
            self._append(ctrl_real_fail, "edge", success=True)
            self._append(ctrl_cancel, "edge", success=True)
        self._append(ctrl_real_fail, "edge", success=False, error="timeout")
        self._append(ctrl_cancel, "edge", success=False, error="cancelled by user")

        real_score, _ = ctrl_real_fail._calculate_engine_score("edge")
        cancel_score, _ = ctrl_cancel._calculate_engine_score("edge")
        assert cancel_score > real_score

    def test_only_cancellations_returns_neutral(self):
        ctrl = AdaptiveSpeedController()
        for _ in range(3):
            self._append(ctrl, "edge", success=False, error="Cancellation requested")
        score, reason = ctrl._calculate_engine_score("edge")
        assert 40 <= score <= 60
        assert "cancel" in reason

    def test_slow_reliable_beats_fast_flaky(self):
        """A slower but always-reliable engine should rank higher than a fast
        but 50%-failing one — the core motivation for the reliability factor."""
        ctrl = AdaptiveSpeedController()
        # Piper: 100 chars/s, 100% success
        for _ in range(4):
            self._append(ctrl, "piper", success=True, chars=3000, elapsed=30.0)
        # Edge: 500 chars/s but 50% failure rate
        self._append(ctrl, "edge", success=True, chars=3000, elapsed=6.0)
        self._append(ctrl, "edge", success=False, error="timeout")
        self._append(ctrl, "edge", success=True, chars=3000, elapsed=6.0)
        self._append(ctrl, "edge", success=False, error="timeout")

        rankings = ctrl.get_engine_ranking(["edge", "piper"])
        top = rankings[0][0]
        assert top == "piper", f"expected piper to outrank flaky edge, got {rankings}"


class TestRankingSizeAwareness:
    """`get_engine_ranking` should bias towards samples in the target size
    bucket when one is provided."""

    def _append(
        self,
        ctrl: AdaptiveSpeedController,
        engine: str,
        *,
        chars: int,
        elapsed: float,
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

    def test_ranking_uses_bucket_samples_when_enough(self):
        ctrl = AdaptiveSpeedController()
        # Edge: very fast on short chapters (2 samples in short bucket)
        self._append(ctrl, "edge", chars=3000, elapsed=6.0)
        self._append(ctrl, "edge", chars=3500, elapsed=7.0)
        # Edge: very slow on long chapters (also 2 samples, in long bucket)
        self._append(ctrl, "edge", chars=50_000, elapsed=1000.0)
        self._append(ctrl, "edge", chars=45_000, elapsed=900.0)

        ranking_short = ctrl.get_engine_ranking(["edge"], chapter_chars=3200)
        ranking_long = ctrl.get_engine_ranking(["edge"], chapter_chars=48_000)
        # Short bucket should outperform long by a wide margin (10×+ cps).
        assert ranking_short[0][1] > ranking_long[0][1]
        assert "short bucket" in ranking_short[0][2]
        assert "long bucket" in ranking_long[0][2]

    def test_ranking_falls_back_when_bucket_sparse(self):
        """With only 1 sample in the bucket, ranking uses the full window."""
        ctrl = AdaptiveSpeedController()
        self._append(ctrl, "edge", chars=3000, elapsed=6.0)  # short, single sample
        self._append(ctrl, "edge", chars=40_000, elapsed=80.0)
        self._append(ctrl, "edge", chars=38_000, elapsed=80.0)

        ranking = ctrl.get_engine_ranking(["edge"], chapter_chars=3200)
        # Bucket has <2 samples → falls back to full window. Reason must NOT
        # claim it used the short bucket.
        assert "bucket" not in ranking[0][2]
