# -*- coding: utf-8 -*-
"""Tests for telemetry benchmarking utilities."""

from __future__ import annotations

from pathlib import Path

from src.telemetry import TelemetryRecorder


def test_telemetry_summary_and_ranking(tmp_path):
    telemetry_path = Path(tmp_path) / "telemetry.json"
    recorder = TelemetryRecorder(telemetry_file=telemetry_path, max_samples=20)
    recorder.clear()
    recorder.record_sample(
        engine="edge",
        voice="pt-BR",
        chars=10_000,
        synth_seconds=50.0,
        total_seconds=55.0,
        audio_seconds=60.0,
        job_id="job-1",
        chapter="chapter-1",
    )
    recorder.record_sample(
        engine="coqui",
        voice="xtts",
        chars=8_000,
        synth_seconds=120.0,
        total_seconds=130.0,
        audio_seconds=90.0,
        job_id="job-2",
        chapter="chapter-2",
    )
    summary = recorder.summary()
    assert "edge" in summary and "coqui" in summary
    assert summary["edge"]["avg_chars_per_second"] > summary["coqui"]["avg_chars_per_second"]
    ranked = recorder.ranked_engines()
    assert ranked[0] == "edge"
    recent = recorder.recent_samples(limit=1)
    assert len(recent) == 1
    assert recent[0]["engine"] == "coqui"


def test_telemetry_ignores_invalid_samples(tmp_path):
    telemetry_path = Path(tmp_path) / "telemetry.json"
    recorder = TelemetryRecorder(telemetry_file=telemetry_path, max_samples=5)
    recorder.clear()
    recorder.record_sample(
        engine="edge",
        voice=None,
        chars=0,
        synth_seconds=0,
        total_seconds=0,
        audio_seconds=None,
        job_id=None,
        chapter=None,
    )
    assert recorder.summary() == {}


# ── Failure tracking / reliability factor ─────────────────────────────────


def _fresh_recorder(tmp_path) -> TelemetryRecorder:
    recorder = TelemetryRecorder(telemetry_file=tmp_path / "telemetry.json", max_samples=5)
    recorder.clear()
    return recorder


def test_record_failure_increments_counter(tmp_path):
    recorder = _fresh_recorder(tmp_path)
    assert recorder.failure_count_recent("edge") == 0
    recorder.record_failure("edge")
    recorder.record_failure("edge")
    assert recorder.failure_count_recent("edge") == 2
    # Other engines unaffected.
    assert recorder.failure_count_recent("piper") == 0


def test_record_failure_normalizes_engine_name(tmp_path):
    recorder = _fresh_recorder(tmp_path)
    recorder.record_failure("EDGE")
    recorder.record_failure(" edge ")
    assert recorder.failure_count_recent("edge") == 2


def test_record_failure_ignores_empty(tmp_path):
    recorder = _fresh_recorder(tmp_path)
    recorder.record_failure("")
    recorder.record_failure(None)  # type: ignore[arg-type]
    assert recorder.failure_count_recent("edge") == 0


def test_failure_count_respects_window(tmp_path):
    import time as _time

    recorder = _fresh_recorder(tmp_path)
    recorder.record_failure("edge")
    # Force old timestamp so it falls outside the window.
    recorder._failure_timestamps["edge"][0] = _time.time() - 10_000
    assert recorder.failure_count_recent("edge", window_seconds=900) == 0
    # Widening the window should surface it again.
    assert recorder.failure_count_recent("edge", window_seconds=20_000) == 1


def test_reliability_factor_shapes(tmp_path):
    recorder = _fresh_recorder(tmp_path)
    # No failures → full confidence.
    assert recorder.reliability_factor("edge") == 1.0
    # One failure → 0.85.
    recorder.record_failure("edge")
    assert abs(recorder.reliability_factor("edge") - 0.85) < 1e-9
    # Many failures → floor at 0.10.
    for _ in range(30):
        recorder.record_failure("edge")
    assert recorder.reliability_factor("edge") == 0.10


def test_reliability_factor_is_monotone_decreasing(tmp_path):
    recorder = _fresh_recorder(tmp_path)
    prev = recorder.reliability_factor("edge")
    for _ in range(6):
        recorder.record_failure("edge")
        current = recorder.reliability_factor("edge")
        assert current <= prev
        prev = current
