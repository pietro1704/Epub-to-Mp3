from __future__ import annotations

import asyncio
import json
import os
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

import pytest

try:
    from fastapi.testclient import TestClient
except ModuleNotFoundError:  # pragma: no cover - optional dependency
    raise unittest.SkipTest("fastapi not installed; skipping server conversion tests")

from src.config import ConversionConfig
from src.job_manager import JobManager
from src.stream_http_observation import StreamHTTPObservationStore
from src.telemetry import TelemetryRecorder

from python_app import server
from python_app.src import _server_audio_helpers as server_audio_helpers


FIXTURE_BOOK = Path(__file__).resolve().parents[2] / "web" / "public" / "sample.epub"
MINIMAL_MP3 = (
    bytes(
        [
            0xFF,
            0xFB,
            0x90,
            0x00,
        ]
    )
    * 10
)
MINIMAL_WAV = (
    b"RIFF\x24\x80\x00\x00WAVEfmt "
    + b"\x10\x00\x00\x00\x01\x00\x01\x00"
    + b"\x40\x1f\x00\x00\x80>\x00\x00\x02\x00\x10\x00data\x00\x80\x00\x00"
)


def requires_ffmpeg(func):
    return func


def _configure_server_paths(tmp_path, monkeypatch):
    tmp_path.mkdir(exist_ok=True)
    uploads = tmp_path / ".uploads"
    uploads.mkdir(exist_ok=True)
    job_inputs = tmp_path / ".job_inputs"
    job_inputs.mkdir(exist_ok=True)
    covers = tmp_path / ".cover_cache"
    covers.mkdir(exist_ok=True)
    jobs_dir = tmp_path / ".jobs"
    jobs_dir.mkdir(exist_ok=True)
    monkeypatch.setattr(server, "output_dir", tmp_path)
    monkeypatch.setattr(server, "persistent_root", tmp_path)
    monkeypatch.setattr(server, "uploads_dir", uploads)
    monkeypatch.setattr(server, "job_inputs_dir", job_inputs)
    monkeypatch.setattr(server, "cover_cache_dir", covers)
    monkeypatch.setattr(server, "job_manager", JobManager(jobs_dir))


class DummyTTSEngine:
    def __init__(self, name: str, fail_times: int = 0):
        self.name = name
        self.fail_times = fail_times
        self.calls = 0

    async def synthesize_async(self, text, output_path):
        self.calls += 1
        if self.calls <= self.fail_times:
            raise RuntimeError(f"{self.name} unavailable")
        path = Path(output_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = MINIMAL_MP3 if path.suffix.lower() == ".mp3" else MINIMAL_WAV
        path.write_bytes(payload)
        return path


class DummyFactory:
    def __init__(self, creators, provider):
        self._creators = creators
        self.voice_provider = provider

    def create_engine(self, config):
        engine_name = (config.engine or "").lower()
        creator = self._creators.get(engine_name)
        if not creator:
            raise ValueError(f"Unsupported engine {engine_name}")
        return creator()


async def _fake_convert_to_mp3(input_file: Path, output_file: Path, bitrate: str = "8k"):
    output_path = Path(output_file)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(MINIMAL_MP3)
    return output_path


def _make_telemetry(tmp_path, monkeypatch):
    telemetry_path = Path(tmp_path) / "telemetry.json"
    recorder = TelemetryRecorder(telemetry_file=telemetry_path, max_samples=20)
    monkeypatch.setattr(server, "telemetry", recorder)
    return recorder


# ---------------------------------------------------------------------------
# Per-chapter timing: _set_chapter_status timestamps
# ---------------------------------------------------------------------------


def _make_job_with_chapters(n: int = 3) -> dict:
    return {
        "chapterProgress": [
            {"index": i, "name": f"Chapter {i}", "status": "queued"} for i in range(1, n + 1)
        ]
    }


__all__ = [
    "ConversionConfig",
    "DummyFactory",
    "DummyTTSEngine",
    "FIXTURE_BOOK",
    "JobManager",
    "MINIMAL_MP3",
    "MINIMAL_WAV",
    "Path",
    "SimpleNamespace",
    "StreamHTTPObservationStore",
    "TelemetryRecorder",
    "TestClient",
    "_configure_server_paths",
    "_fake_convert_to_mp3",
    "_make_job_with_chapters",
    "_make_telemetry",
    "asyncio",
    "json",
    "os",
    "patch",
    "pytest",
    "replace",
    "requires_ffmpeg",
    "server",
    "server_audio_helpers",
    "unittest",
    "uuid4",
]
