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
