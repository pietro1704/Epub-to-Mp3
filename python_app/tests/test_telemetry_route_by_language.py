# -*- coding: utf-8 -*-
"""Telemetry summary endpoint exposes the per-language breakdown."""

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


@pytest.fixture
def client(tmp_path, monkeypatch):
    rec = TelemetryRecorder(telemetry_file=tmp_path / "tel.json")
    monkeypatch.setattr(routes_telemetry, "_recorder", lambda: rec)
    app = FastAPI()
    app.include_router(router)
    return TestClient(app), rec


def test_summary_includes_by_language_breakdown(client):
    c, rec = client
    rec.record_sample(
        engine="edge",
        voice="pt",
        chars=5000,
        synth_seconds=100.0,
        total_seconds=100.0,
        audio_seconds=30.0,
        job_id="j",
        chapter="c",
        language="pt-BR",
    )
    rec.record_sample(
        engine="edge",
        voice="en",
        chars=5000,
        synth_seconds=25.0,
        total_seconds=25.0,
        audio_seconds=30.0,
        job_id="j",
        chapter="c",
        language="en",
    )
    payload = c.get("/api/telemetry/summary").json()
    assert "byLanguage" in payload
    assert "edge" in payload["byLanguage"]
    assert {"pt", "en"} <= set(payload["byLanguage"]["edge"].keys())
    pt_speed = payload["byLanguage"]["edge"]["pt"]["avg_chars_per_second"]
    en_speed = payload["byLanguage"]["edge"]["en"]["avg_chars_per_second"]
    assert en_speed > pt_speed
