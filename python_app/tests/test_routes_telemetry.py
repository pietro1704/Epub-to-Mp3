# -*- coding: utf-8 -*-
"""Tests for python_app/src/routes_telemetry.py (summary + timeline)."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

# Ensure python_app is importable (mirrors other test modules)
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import python_app.src.routes_telemetry as routes_telemetry  # noqa: E402
from python_app.src.routes_telemetry import router  # noqa: E402
from python_app.src.telemetry import TelemetryRecorder  # noqa: E402


@pytest.fixture
def telemetry_ctx(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    recorder = TelemetryRecorder(telemetry_file=tmp_path / "samples.json")

    # Patch the module-level helper so the endpoint always reads our tmp recorder,
    # regardless of any pre-existing python_app.server module in sys.modules.
    monkeypatch.setattr(routes_telemetry, "_recorder", lambda: recorder)

    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)
    return client, recorder


@pytest.fixture
def telemetry_app(telemetry_ctx) -> TestClient:
    return telemetry_ctx[0]


def _seed(ctx, entries):
    _, recorder = ctx
    for entry in entries:
        recorder.record_sample(
            engine=entry["engine"],
            voice=entry.get("voice"),
            chars=entry["chars"],
            synth_seconds=entry["synth_seconds"],
            total_seconds=entry.get("total_seconds", entry["synth_seconds"]),
            audio_seconds=entry.get("audio_seconds"),
            job_id=entry.get("job_id"),
            chapter=entry.get("chapter"),
        )


def test_summary_empty(telemetry_ctx) -> None:
    client, _ = telemetry_ctx
    response = client.get("/api/telemetry/summary")
    assert response.status_code == 200
    payload = response.json()
    assert payload == {"engines": {}, "ranked": [], "totalSamples": 0}


def test_summary_aggregates_by_engine(telemetry_ctx) -> None:
    client, _ = telemetry_ctx
    _seed(
        telemetry_ctx,
        [
            {"engine": "edge", "chars": 1000, "synth_seconds": 5.0},
            {"engine": "edge", "chars": 2000, "synth_seconds": 10.0},
            {"engine": "piper", "chars": 500, "synth_seconds": 10.0},
        ],
    )
    response = client.get("/api/telemetry/summary")
    assert response.status_code == 200
    payload = response.json()
    engines = payload["engines"]
    assert set(engines.keys()) == {"edge", "piper"}
    assert engines["edge"]["samples"] == 2
    assert engines["edge"]["avg_chars_per_second"] == pytest.approx(200.0)
    assert engines["piper"]["avg_chars_per_second"] == pytest.approx(50.0)
    assert payload["ranked"][0] == "edge"
    assert payload["totalSamples"] == 3


def test_timeline_returns_recent_points(telemetry_ctx) -> None:
    client, _ = telemetry_ctx
    _seed(
        telemetry_ctx,
        [
            {
                "engine": "edge",
                "chars": 1000,
                "synth_seconds": 5.0,
                "chapter": "Ch1",
                "job_id": "j1",
                "voice": "ptBR-A",
            },
            {
                "engine": "piper",
                "chars": 600,
                "synth_seconds": 12.0,
                "chapter": "Ch2",
                "job_id": "j1",
            },
        ],
    )
    response = client.get("/api/telemetry/timeline?limit=10")
    assert response.status_code == 200
    payload = response.json()
    assert payload["count"] == 2
    assert len(payload["points"]) == 2
    first = payload["points"][0]
    assert first["engine"] == "edge"
    assert first["charsPerSecond"] == pytest.approx(200.0)
    assert first["chapter"] == "Ch1"
    assert first["voice"] == "ptBR-A"
    second = payload["points"][1]
    assert second["engine"] == "piper"
    assert second["charsPerSecond"] == pytest.approx(50.0)


def test_timeline_respects_limit(telemetry_ctx) -> None:
    client, _ = telemetry_ctx
    _seed(
        telemetry_ctx,
        [
            {"engine": "edge", "chars": 1000, "synth_seconds": 5.0},
            {"engine": "edge", "chars": 2000, "synth_seconds": 10.0},
            {"engine": "edge", "chars": 3000, "synth_seconds": 15.0},
        ],
    )
    response = client.get("/api/telemetry/timeline?limit=2")
    assert response.status_code == 200
    payload = response.json()
    assert payload["count"] == 2
    assert payload["points"][-1]["chars"] == 3000


def test_timeline_invalid_limit_returns_400(telemetry_ctx) -> None:
    client, _ = telemetry_ctx
    assert client.get("/api/telemetry/timeline?limit=0").status_code == 400
    assert client.get("/api/telemetry/timeline?limit=9999").status_code == 400


def test_timeline_skips_invalid_entries(telemetry_ctx) -> None:
    client, _ = telemetry_ctx
    _seed(
        telemetry_ctx,
        [
            {"engine": "edge", "chars": 1000, "synth_seconds": 5.0},
            {"engine": "edge", "chars": 0, "synth_seconds": 5.0},
        ],
    )
    response = client.get("/api/telemetry/timeline")
    assert response.status_code == 200
    assert response.json()["count"] == 1
