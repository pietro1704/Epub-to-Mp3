# -*- coding: utf-8 -*-
"""Tests for shared edge-chunk degradation helper and jittered auto-tune
thresholds (both parts of the fallback/fine-tuning pass)."""

from __future__ import annotations

import random

from python_app.src._edge_throttle_mixin import _EdgeThrottleMixin
from python_app.src._server_engine_helpers import degrade_edge_chunk_chars


class TestDegradeEdgeChunkChars:
    def test_default_shrinks_to_80_percent(self):
        # 10_000 * 0.8 = 8_000, within [4000, 8000] → 8000.
        assert degrade_edge_chunk_chars(10_000) == 8_000

    def test_floor_clamp(self):
        # 4_000 * 0.8 = 3_200 → clamped up to floor 4_000.
        assert degrade_edge_chunk_chars(4_000) == 4_000

    def test_cap_clamp(self):
        # Huge input shrinks but stays capped at 8_000.
        assert degrade_edge_chunk_chars(20_000) == 8_000

    def test_none_falls_back_to_cap_then_shrinks(self):
        # base = cap = 8000 → shrunk = 6400 (within [4000, 8000]).
        assert degrade_edge_chunk_chars(None) == 6_400

    def test_zero_falls_back_to_cap_then_shrinks(self):
        assert degrade_edge_chunk_chars(0) == 6_400

    def test_negative_falls_back_to_cap_then_shrinks(self):
        assert degrade_edge_chunk_chars(-5_000) == 6_400

    def test_custom_floor_cap(self):
        # Used by converter.py with (floor=4000, cap=12000).
        # 12_000 * 0.8 = 9_600 → within bounds.
        assert degrade_edge_chunk_chars(12_000, floor=4_000, cap=12_000) == 9_600

    def test_custom_cap_below_floor_returns_floor(self):
        # Defensive: if caller passes floor > cap, floor wins.
        assert degrade_edge_chunk_chars(10_000, floor=6_000, cap=5_000) == 6_000

    def test_custom_shrink_factor(self):
        assert degrade_edge_chunk_chars(10_000, floor=1_000, cap=9_000, shrink_factor=0.5) == 5_000

    def test_cli_and_web_degradation_converge(self):
        """Same input must produce the same output regardless of caller.

        Regression test for the dual-path divergence: CLI applied `× 0.8` and
        Web applied `min(current, safe_cap)`. Now both go through this helper.
        """
        current = 12_000
        cli_result = degrade_edge_chunk_chars(current, floor=4_000, cap=12_000)
        web_result = degrade_edge_chunk_chars(current, floor=4_000, cap=12_000)
        assert cli_result == web_result


class TestJitteredAutoTuneThresholds:
    def test_bands(self):
        rng = random.Random(0)
        samples_down, samples_up = [], []
        for _ in range(500):
            # Replace module-level random draws deterministically.
            saved = random.uniform
            random.uniform = rng.uniform  # type: ignore[assignment]
            try:
                down, up = _EdgeThrottleMixin._jittered_auto_tune_thresholds()
            finally:
                random.uniform = saved  # type: ignore[assignment]
            samples_down.append(down)
            samples_up.append(up)

        # Bands: down ∈ [0.70, 0.86], up ∈ [1.06, 1.30]. Small epsilon for fp.
        assert min(samples_down) >= 0.70 - 1e-9
        assert max(samples_down) <= 0.86 + 1e-9
        assert min(samples_up) >= 1.06 - 1e-9
        assert max(samples_up) <= 1.30 + 1e-9

    def test_non_constant(self):
        """Repeated calls must produce varied values — jitter is doing work."""
        values_down = {
            round(_EdgeThrottleMixin._jittered_auto_tune_thresholds()[0], 4) for _ in range(50)
        }
        values_up = {
            round(_EdgeThrottleMixin._jittered_auto_tune_thresholds()[1], 4) for _ in range(50)
        }
        assert len(values_down) > 10
        assert len(values_up) > 10

    def test_down_always_below_up(self):
        # Even with extreme jitter, the down threshold must stay below the up
        # threshold — otherwise the decision logic becomes incoherent.
        # down cap = 0.86, up floor = 1.06 → 0.86 < 1.06.
        for _ in range(200):
            down, up = _EdgeThrottleMixin._jittered_auto_tune_thresholds()
            assert down < up
