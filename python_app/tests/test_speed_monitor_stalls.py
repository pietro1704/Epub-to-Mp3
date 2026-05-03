# -*- coding: utf-8 -*-
"""Stall-detection guards in SpeedMonitor.

A single slow sample on a small chunk used to trigger STALL_DETECTED →
auto-tuner reduces chunk to 4000 → cascading reductions on a perfectly
healthy run. Two guards now prevent that:

1. Two consecutive stall-shaped samples are required before signalling.
2. Samples below 2000 chars are ignored (small chunks are setup-bound and
   not representative of throughput).
"""

from __future__ import annotations

from python_app.src.speed_monitor import (
    STALL_DURATION_SECONDS,
    SpeedMonitor,
)


def _make_monitor() -> SpeedMonitor:
    return SpeedMonitor()


class TestStallDetectionGuards:
    def test_single_slow_sample_does_not_signal_stall(self):
        mon = _make_monitor()
        slow_chars = 4000
        slow_duration = STALL_DURATION_SECONDS + 5  # speed ~80 chars/s
        action = mon.record_sample(chars=slow_chars, duration=slow_duration)
        assert action is None or "STALL" not in action

    def test_two_consecutive_slow_samples_signal_stall(self):
        mon = _make_monitor()
        slow_chars = 4000
        slow_duration = STALL_DURATION_SECONDS + 5
        first = mon.record_sample(chars=slow_chars, duration=slow_duration)
        second = mon.record_sample(chars=slow_chars, duration=slow_duration)
        assert first is None or "STALL" not in (first or "")
        assert second is not None and "STALL_DETECTED" in second

    def test_small_chunk_slow_sample_is_not_stall(self):
        """Small chunks (<2K chars) are setup-bound — slow doesn't mean throttled."""
        mon = _make_monitor()
        # A 1500-char chunk taking 50s would be 30 chars/s — looks like a
        # stall but is dominated by request/response overhead. Even repeated,
        # this must not signal STALL.
        first = mon.record_sample(chars=1500, duration=STALL_DURATION_SECONDS + 5)
        second = mon.record_sample(chars=1500, duration=STALL_DURATION_SECONDS + 5)
        assert first is None or "STALL" not in (first or "")
        assert second is None or "STALL" not in (second or "")

    def test_healthy_sample_resets_pending_stall(self):
        """One slow + one healthy + one slow must NOT signal — guard resets."""
        mon = _make_monitor()
        slow_chars = 4000
        slow_duration = STALL_DURATION_SECONDS + 5
        mon.record_sample(chars=slow_chars, duration=slow_duration)
        # Healthy sample (well above min_speed)
        healthy = mon.record_sample(chars=8000, duration=10.0)  # 800 chars/s
        assert healthy is None or "STALL" not in (healthy or "")
        # Now a fresh slow sample — should not immediately stall because the
        # streak was reset by the healthy one.
        third = mon.record_sample(chars=slow_chars, duration=slow_duration)
        assert third is None or "STALL" not in (third or "")
