# -*- coding: utf-8 -*-
"""Tests for language-aware telemetry aggregation introduced in v0.3.24."""

from __future__ import annotations

from pathlib import Path

from src.telemetry import TelemetryRecorder, _normalize_lang


def _recorder(tmp_path: Path) -> TelemetryRecorder:
    rec = TelemetryRecorder(telemetry_file=tmp_path / "tel.json", max_samples=50)
    rec.clear()
    return rec


def test_normalize_lang_strips_region_and_unknowns():
    assert _normalize_lang("pt-BR") == "pt"
    assert _normalize_lang("EN_US") == "en"
    assert _normalize_lang("auto") is None
    assert _normalize_lang("unknown") is None
    assert _normalize_lang(None) is None
    assert _normalize_lang("") is None


def test_summary_by_language_buckets(tmp_path):
    rec = _recorder(tmp_path)
    # Edge slow on pt-BR (50 cps), fast on en-US (200 cps).
    rec.record_sample(
        engine="edge",
        voice="pt-BR",
        chars=5000,
        synth_seconds=100.0,
        total_seconds=110.0,
        audio_seconds=30.0,
        job_id="j1",
        chapter="c1",
        language="pt-BR",
    )
    rec.record_sample(
        engine="edge",
        voice="en-US",
        chars=5000,
        synth_seconds=25.0,
        total_seconds=28.0,
        audio_seconds=30.0,
        job_id="j2",
        chapter="c2",
        language="en",
    )
    by_lang = rec.summary_by_language()
    assert "edge" in by_lang
    assert "pt" in by_lang["edge"]
    assert "en" in by_lang["edge"]
    pt_speed = by_lang["edge"]["pt"]["avg_chars_per_second"]
    en_speed = by_lang["edge"]["en"]["avg_chars_per_second"]
    assert en_speed > pt_speed
    # Engine-wide summary still works (back-compat).
    summary = rec.summary()
    assert "edge" in summary


def test_avg_speed_for_language_falls_back(tmp_path):
    rec = _recorder(tmp_path)
    # Only en-US samples exist. A pt-BR query should fall back to engine-wide.
    rec.record_sample(
        engine="edge",
        voice="en-US",
        chars=5000,
        synth_seconds=25.0,
        total_seconds=28.0,
        audio_seconds=30.0,
        job_id="j",
        chapter="c",
        language="en",
    )
    en_speed = rec.avg_speed_for("edge", "en-US")
    pt_fallback = rec.avg_speed_for("edge", "pt-BR")  # no pt samples → engine-wide
    assert en_speed > 0
    # Fallback returns the engine-wide aggregate, which equals the only
    # sample we have (en).
    assert pt_fallback == en_speed


def test_ranked_engines_lang_aware(tmp_path):
    rec = _recorder(tmp_path)
    # Edge fast on en, slow on pt. Kokoro steady at 80 cps on pt.
    rec.record_sample(
        engine="edge",
        voice="en",
        chars=5000,
        synth_seconds=25.0,
        total_seconds=25.0,
        audio_seconds=25.0,
        job_id="j",
        chapter="c",
        language="en",
    )
    rec.record_sample(
        engine="edge",
        voice="pt",
        chars=5000,
        synth_seconds=100.0,
        total_seconds=100.0,
        audio_seconds=25.0,
        job_id="j",
        chapter="c",
        language="pt",
    )
    rec.record_sample(
        engine="kokoro",
        voice="x",
        chars=5000,
        synth_seconds=62.5,
        total_seconds=62.5,
        audio_seconds=25.0,
        job_id="j",
        chapter="c",
        language="pt",
    )
    en_rank = rec.ranked_engines("en")
    pt_rank = rec.ranked_engines("pt")
    assert en_rank[0] == "edge"  # 200 cps > kokoro 80
    assert pt_rank[0] == "kokoro"  # 80 cps > edge 50 on pt


def test_record_sample_without_language_buckets_under_any(tmp_path):
    rec = _recorder(tmp_path)
    rec.record_sample(
        engine="edge",
        voice="x",
        chars=1000,
        synth_seconds=10.0,
        total_seconds=10.0,
        audio_seconds=10.0,
        job_id="j",
        chapter="c",
    )
    by_lang = rec.summary_by_language()
    assert by_lang["edge"]["_any"]["samples"] == 1.0
