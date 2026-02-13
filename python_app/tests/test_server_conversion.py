from __future__ import annotations

import asyncio
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

try:
    from fastapi.testclient import TestClient
except ModuleNotFoundError:  # pragma: no cover - optional dependency
    raise unittest.SkipTest("fastapi not installed; skipping server conversion tests")

from src.config import ConversionConfig
from src.job_manager import JobManager
from src.telemetry import TelemetryRecorder

from python_app import server

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


def test_process_conversion_generates_chapters(tmp_path, monkeypatch):
    """Test server conversion with mocked TTS engine."""
    job_id = str(uuid4())

    _configure_server_paths(tmp_path, monkeypatch)

    upload_path = tmp_path / f"{job_id}_book.epub"
    upload_path.write_bytes(FIXTURE_BOOK.read_bytes())

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": [],
        "file_path": str(upload_path),
        "engine": "edge",
        "voice": None,
        "chapters": None,
        "footnote_mode": "inline",
        "language": "pt-BR",
        "outputs": [],
    }

    # Mock the TTS engine to create dummy audio files
    async def mock_synthesize(self, text, output_path):
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        # Create a minimal valid MP3 file (ID3 header + silence)
        # This is a minimal MP3 frame that ffprobe can read
        mp3_header = bytes(
            [
                0xFF,
                0xFB,
                0x90,
                0x00,  # MP3 frame header
            ]
            + [0x00] * 417
        )  # Padding to make valid frame
        output_path.write_bytes(mp3_header * 10)  # Multiple frames
        return output_path

    _make_telemetry(tmp_path, monkeypatch)

    monkeypatch.setattr(server.AudioProcessor, "convert_to_mp3", staticmethod(_fake_convert_to_mp3))

    with patch("src.tts.edge_engine.EdgeTTSEngine.synthesize_async", mock_synthesize):
        asyncio.run(server.process_conversion(job_id))

    job = server.jobs[job_id]
    assert job["state"] == "finished", f"Job failed: {job.get('error')}"
    assert len(job["outputs"]) >= 2  # At least zip + 1 chapter

    job_dir = Path(job.get("outputDir") or (tmp_path / job_id))
    generated_files = {p.name for p in job_dir.iterdir() if p.is_file()}

    for asset in job["outputs"]:
        assert asset["name"] in generated_files
        file_path = job_dir / asset["name"]
        assert file_path.stat().st_size > 0

    # Confirm zip was created
    zip_name = job["outputs"][0]["name"]
    assert zip_name.endswith(".zip")

    server.jobs.pop(job_id, None)


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


def test_preserves_reused_upload_inside_job_dir(tmp_path, monkeypatch):
    """Ensure metadata uploads stored inside job folder survive cleanup."""
    job_id = str(uuid4())

    _configure_server_paths(tmp_path, monkeypatch)

    job_dir = tmp_path / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    upload_path = job_dir / "book.epub"
    upload_path.write_bytes(FIXTURE_BOOK.read_bytes())
    cover_name = "cover.jpg"
    cover_path = job_dir / cover_name
    cover_path.write_bytes(b"fake-cover")

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": [],
        "file_path": str(upload_path),
        "engine": "edge",
        "voice": None,
        "chapters": None,
        "footnote_mode": "inline",
        "language": "pt-BR",
        "outputs": [],
        "cover": {
            "name": cover_name,
            "url": f"/api/outputs/{job_id}/{cover_name}",
            "mimeType": "image/jpeg",
        },
        "coverUrl": f"/api/outputs/{job_id}/{cover_name}",
    }

    _make_telemetry(tmp_path, monkeypatch)
    creators = {
        "edge": lambda: DummyTTSEngine("edge"),
    }
    dummy_factory = DummyFactory(creators, server.tts_factory.voice_provider)
    monkeypatch.setattr(server, "tts_factory", dummy_factory)
    monkeypatch.setattr(server.AudioProcessor, "convert_to_mp3", staticmethod(_fake_convert_to_mp3))

    asyncio.run(server.process_conversion(job_id))

    job = server.jobs[job_id]
    assert job["state"] == "finished", f"Job failed: {job.get('error')}"
    # Cover should still be served from the job output directory
    assert (tmp_path / job_id / cover_name).exists()
    server.jobs.pop(job_id, None)


def test_edge_fallbacks_to_coqui_and_recovers(tmp_path, monkeypatch):
    job_id = str(uuid4())
    _configure_server_paths(tmp_path, monkeypatch)

    upload_path = tmp_path / f"{job_id}_book.epub"
    upload_path.write_bytes(FIXTURE_BOOK.read_bytes())

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": [],
        "file_path": str(upload_path),
        "engine": "edge",
        "voice": None,
        "chapters": None,
        "footnote_mode": "inline",
        "language": "pt-BR",
        "outputs": [],
    }

    _make_telemetry(tmp_path, monkeypatch)

    creators = {
        "edge": lambda: DummyTTSEngine("edge", fail_times=1),
        "coqui": lambda: DummyTTSEngine("coqui"),
        "piper": lambda: DummyTTSEngine("piper"),
    }
    dummy_factory = DummyFactory(creators, server.tts_factory.voice_provider)
    monkeypatch.setattr(server, "tts_factory", dummy_factory)
    monkeypatch.setattr(server.AudioProcessor, "convert_to_mp3", staticmethod(_fake_convert_to_mp3))

    asyncio.run(server.process_conversion(job_id))
    job = server.jobs[job_id]
    assert job["state"] == "finished"
    assert any("tentando fallback" in event for event in job["events"])
    assert all(entry["status"] == "completed" for entry in job.get("chapterProgress", []))
    assert job["outputs"], "expected generated assets"
    server.jobs.pop(job_id, None)


def test_edge_fallbacks_to_piper_when_coqui_fails(tmp_path, monkeypatch):
    job_id = str(uuid4())
    _configure_server_paths(tmp_path, monkeypatch)

    upload_path = tmp_path / f"{job_id}_book.epub"
    upload_path.write_bytes(FIXTURE_BOOK.read_bytes())

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": [],
        "file_path": str(upload_path),
        "engine": "edge",
        "voice": None,
        "chapters": None,
        "footnote_mode": "inline",
        "language": "pt-BR",
        "outputs": [],
    }

    _make_telemetry(tmp_path, monkeypatch)

    creators = {
        "edge": lambda: DummyTTSEngine("edge", fail_times=1),
        "coqui": lambda: DummyTTSEngine("coqui", fail_times=1),
        "piper": lambda: DummyTTSEngine("piper"),
    }
    dummy_factory = DummyFactory(creators, server.tts_factory.voice_provider)
    monkeypatch.setattr(server, "tts_factory", dummy_factory)
    monkeypatch.setattr(server.AudioProcessor, "convert_to_mp3", staticmethod(_fake_convert_to_mp3))

    asyncio.run(server.process_conversion(job_id))
    job = server.jobs[job_id]
    assert job["state"] == "finished"
    assert any("Agora usando PIPER" in event for event in job["events"])
    assert job["chapterProgress"]
    assert all(entry["status"] == "completed" for entry in job["chapterProgress"])
    server.jobs.pop(job_id, None)


def test_pick_auto_engine_prefers_fastest_telemetry():
    pool = {
        "edge": (ConversionConfig(engine="edge"), SimpleNamespace()),
        "coqui": (ConversionConfig(engine="coqui"), SimpleNamespace()),
    }
    telemetry_speeds = {"edge": 180.0, "coqui": 50.0}
    selected, order = server._pick_auto_engine(12_000, 600, pool, telemetry_speeds=telemetry_speeds)
    assert order[0] == "edge"
    assert selected == order[0]


def test_convert_endpoint_rejects_large_files(monkeypatch):
    client = TestClient(server.app)
    monkeypatch.setattr(server, "MAX_UPLOAD_BYTES", 10)
    monkeypatch.setattr(server, "MAX_UPLOAD_MB", 0)

    response = client.post(
        "/api/convert",
        files={
            "file": ("book.epub", b"X" * 16, "application/epub+zip"),
        },
    )
    assert response.status_code == 413


def _make_telemetry(tmp_path, monkeypatch):
    telemetry_path = Path(tmp_path) / "telemetry.json"
    recorder = TelemetryRecorder(telemetry_file=telemetry_path, max_samples=20)
    monkeypatch.setattr(server, "telemetry", recorder)
    return recorder
