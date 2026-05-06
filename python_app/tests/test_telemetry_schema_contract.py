# -*- coding: utf-8 -*-
"""Schema contract test: pin the shape of /api/telemetry/summary so a
backend rename or removed field breaks the test instead of silently
breaking the web bundle in CI.

The frontend `TelemetrySummary` interface in
``web/src/services/TelemetryService.ts`` declares:

    {
        engines: Record<string, EngineStats>,
        ranked: string[],
        totalSamples: number,
        byLanguage?: Record<string, Record<string, EngineStats>>,
    }

Where ``EngineStats`` requires:

    { samples, avg_chars_per_second, max_chars_per_second, min_chars_per_second }

This test verifies the live server payload conforms — even with empty
recorder, with a single engine, and with multi-language samples.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import python_app.src.routes_telemetry as routes_telemetry  # noqa: E402
from python_app.src.routes_telemetry import router  # noqa: E402
from python_app.src.telemetry import TelemetryRecorder  # noqa: E402

# Frontend-required fields. Adding a new field here means updating
# TelemetryService.ts in lockstep — that's the whole point of this test.
_TOP_LEVEL_REQUIRED = {"engines", "ranked", "totalSamples"}
_TOP_LEVEL_OPTIONAL = {"byLanguage"}
_ENGINE_STATS_REQUIRED = {
    "samples",
    "avg_chars_per_second",
    "max_chars_per_second",
    "min_chars_per_second",
}


@pytest.fixture
def client(tmp_path, monkeypatch):
    rec = TelemetryRecorder(telemetry_file=tmp_path / "tel.json")
    monkeypatch.setattr(routes_telemetry, "_recorder", lambda: rec)
    app = FastAPI()
    app.include_router(router)
    return TestClient(app), rec


def _assert_top_level_shape(payload: dict) -> None:
    assert _TOP_LEVEL_REQUIRED <= set(
        payload.keys()
    ), f"Missing required keys: {_TOP_LEVEL_REQUIRED - set(payload.keys())}"
    extra = set(payload.keys()) - _TOP_LEVEL_REQUIRED - _TOP_LEVEL_OPTIONAL
    assert not extra, f"Unexpected top-level keys (update TelemetryService.ts first): {extra}"
    assert isinstance(payload["engines"], dict)
    assert isinstance(payload["ranked"], list)
    assert isinstance(payload["totalSamples"], int)
    if "byLanguage" in payload:
        assert isinstance(payload["byLanguage"], dict)


def _assert_engine_stats_shape(stats: dict) -> None:
    assert _ENGINE_STATS_REQUIRED <= set(
        stats.keys()
    ), f"Missing EngineStats fields: {_ENGINE_STATS_REQUIRED - set(stats.keys())}"
    for field in _ENGINE_STATS_REQUIRED:
        value = stats[field]
        assert isinstance(
            value, (int, float)
        ), f"{field} must be numeric, got {type(value).__name__}"


def test_empty_recorder_payload_matches_schema(client):
    c, _ = client
    payload = c.get("/api/telemetry/summary").json()
    _assert_top_level_shape(payload)
    assert payload["engines"] == {}
    assert payload["ranked"] == []
    assert payload["totalSamples"] == 0


def test_engine_stats_match_schema(client):
    c, rec = client
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
    payload = c.get("/api/telemetry/summary").json()
    _assert_top_level_shape(payload)
    assert "edge" in payload["engines"]
    _assert_engine_stats_shape(payload["engines"]["edge"])


def test_by_language_breakdown_matches_schema(client):
    c, rec = client
    rec.record_sample(
        engine="edge",
        voice="pt",
        chars=1000,
        synth_seconds=20.0,
        total_seconds=20.0,
        audio_seconds=10.0,
        job_id="j",
        chapter="c",
        language="pt-BR",
    )
    rec.record_sample(
        engine="edge",
        voice="en",
        chars=1000,
        synth_seconds=5.0,
        total_seconds=5.0,
        audio_seconds=10.0,
        job_id="j",
        chapter="c",
        language="en",
    )
    payload = c.get("/api/telemetry/summary").json()
    _assert_top_level_shape(payload)
    assert "byLanguage" in payload
    by_lang = payload["byLanguage"]
    assert "edge" in by_lang
    for lang, stats in by_lang["edge"].items():
        assert isinstance(lang, str) and lang
        _assert_engine_stats_shape(stats)


def test_ranked_is_sorted_by_speed(client):
    c, rec = client
    rec.record_sample(
        engine="edge",
        voice="x",
        chars=10000,
        synth_seconds=50.0,
        total_seconds=50.0,
        audio_seconds=50.0,
        job_id="j",
        chapter="c",
    )
    rec.record_sample(
        engine="kokoro",
        voice="x",
        chars=10000,
        synth_seconds=200.0,
        total_seconds=200.0,
        audio_seconds=50.0,
        job_id="j",
        chapter="c",
    )
    payload = c.get("/api/telemetry/summary").json()
    assert payload["ranked"] == ["edge", "kokoro"]
