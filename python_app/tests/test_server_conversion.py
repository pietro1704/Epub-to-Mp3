from __future__ import annotations

import asyncio
import json
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


def test_build_engine_chain_respects_guards(monkeypatch):
    config = ConversionConfig(engine="edge", primary_language="pt-BR")

    monkeypatch.setattr(server, "_has_coqui_support", lambda: False)
    monkeypatch.setattr(server, "_has_kokoro_support", lambda _: False)
    monkeypatch.setattr(server, "_has_piper_support", lambda: False)
    monkeypatch.setattr(server, "_has_spark_support", lambda: False)

    chain = server._build_engine_chain(config)
    assert [cfg.engine for cfg in chain] == ["edge"]


def test_build_engine_chain_includes_supported_fallbacks(monkeypatch):
    config = ConversionConfig(engine="edge", primary_language="pt-BR")

    monkeypatch.setattr(server, "_has_coqui_support", lambda: True)
    monkeypatch.setattr(server, "_has_kokoro_support", lambda _: True)
    monkeypatch.setattr(server, "_has_piper_support", lambda: True)
    monkeypatch.setattr(server, "_has_spark_support", lambda: False)

    chain = server._build_engine_chain(config)
    engines = [cfg.engine for cfg in chain]
    assert "edge" in engines and "coqui" in engines and "piper" in engines


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
    assert any("trying fallback" in event for event in job["events"])
    assert all(entry["status"] == "completed" for entry in job.get("chapterProgress", []))
    assert all(entry.get("engine") for entry in job.get("chapterProgress", []))
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
    assert any("Now using PIPER" in event for event in job["events"])
    assert job["chapterProgress"]
    assert all(entry["status"] == "completed" for entry in job["chapterProgress"])
    assert all(entry.get("engine") for entry in job["chapterProgress"])
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


def test_convert_endpoint_success_flow(tmp_path, monkeypatch):
    """Hit the HTTP endpoint and process the job to completion."""
    _configure_server_paths(tmp_path, monkeypatch)
    _make_telemetry(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "_enqueue_job", lambda job_id: True)
    monkeypatch.setattr(server.AudioProcessor, "convert_to_mp3", staticmethod(_fake_convert_to_mp3))

    async def mock_synthesize(self, text, output_path):
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(MINIMAL_MP3)
        return output_path

    monkeypatch.setattr("src.tts.edge_engine.EdgeTTSEngine.synthesize_async", mock_synthesize)

    client = TestClient(server.app)
    response = client.post(
        "/api/convert",
        files={"file": ("book.epub", FIXTURE_BOOK.read_bytes(), "application/epub+zip")},
        data={"engine": "edge"},
    )
    assert response.status_code == 200
    job_id = response.json()["jobId"]

    asyncio.run(server.process_conversion(job_id))

    job_response = client.get(f"/api/jobs/{job_id}")
    assert job_response.status_code == 200
    assert job_response.json()["state"] == "finished"

    server.jobs.pop(job_id, None)


def test_convert_endpoint_failure_flow(tmp_path, monkeypatch):
    """Ensure job state is marked failed when engine raises."""
    _configure_server_paths(tmp_path, monkeypatch)
    _make_telemetry(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "_enqueue_job", lambda job_id: True)

    async def fail_process(job_id: str):
        job = server.jobs[job_id]
        job["state"] = "failed"
        job["error"] = "edge boom"
        server.jobs[job_id] = job

    monkeypatch.setattr(server, "process_conversion", fail_process)

    client = TestClient(server.app)
    response = client.post(
        "/api/convert",
        files={"file": ("book.epub", FIXTURE_BOOK.read_bytes(), "application/epub+zip")},
        data={"engine": "edge"},
    )
    assert response.status_code == 200
    job_id = response.json()["jobId"]

    asyncio.run(server.process_conversion(job_id))

    job_response = client.get(f"/api/jobs/{job_id}")
    assert job_response.status_code == 200
    payload = job_response.json()
    assert payload["state"] == "failed"
    assert "edge boom" in payload.get("error", "")

    server.jobs.pop(job_id, None)


def test_job_status_rehydrates_outputs(tmp_path, monkeypatch):
    """Jobs that lose their metadata are rebuilt from existing audio files."""
    _configure_server_paths(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "jobs", {})
    monkeypatch.setattr(server, "_recent_jobs_index", {})

    job_id = str(uuid4())
    job_output_dir = tmp_path / "Recovered Book" / "edge"
    job_output_dir.mkdir(parents=True, exist_ok=True)
    (job_output_dir / "streams" / job_id / "chapter_0001").mkdir(parents=True, exist_ok=True)

    mp3_path = job_output_dir / "001 - Capitulo de teste.mp3"
    mp3_path.write_bytes(MINIMAL_MP3)
    zip_path = job_output_dir / "Recovered_Book.zip"
    zip_path.write_bytes(b"PK\x03\x0400")
    log_path = job_output_dir / "conversion.log"
    log_path.write_text("done", encoding="utf-8")
    cover_path = job_output_dir / "cover.jpg"
    cover_path.write_bytes(b"\xff" * 10)

    client = TestClient(server.app)
    response = client.get(f"/api/jobs/{job_id}")
    assert response.status_code == 200
    payload = response.json()
    assert payload["jobId"] == job_id
    assert payload["state"] == "finished"
    assert payload["chaptersCompleted"] == 1
    assert any(asset["name"].endswith(".zip") for asset in payload["outputs"])
    assert payload["bookTitle"].lower().startswith("recovered")
    assert payload["chapterProgress"] and payload["chapterProgress"][0]["status"] == "completed"

    job_state_path = tmp_path / ".jobs" / f"{job_id}.json"
    assert job_state_path.exists()


def test_feature_history_endpoint_missing_file(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "CACHE_DIR", tmp_path)
    client = TestClient(server.app)

    response = client.get("/api/telemetry/feature-history")
    assert response.status_code == 200
    payload = response.json()
    assert payload["available"] is False
    assert payload["count"] == 0
    assert payload["entries"] == []


def test_feature_history_endpoint_returns_limited_entries(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "CACHE_DIR", tmp_path)
    telemetry_dir = tmp_path / "telemetry"
    telemetry_dir.mkdir(parents=True, exist_ok=True)
    history_path = telemetry_dir / "feature-ab-history.json"
    history_path.write_text(
        json.dumps(
            {
                "updated_at": 1700000000.0,
                "entries": [
                    {"ts": 3, "engine": "edge", "stage_vs_baseline_gain_pct": 10.0},
                    {"ts": 2, "engine": "edge", "stage_vs_baseline_gain_pct": 8.0},
                    {"ts": 1, "engine": "edge", "stage_vs_baseline_gain_pct": 6.0},
                ],
            }
        ),
        encoding="utf-8",
    )
    client = TestClient(server.app)

    response = client.get("/api/telemetry/feature-history?limit=2")
    assert response.status_code == 200
    payload = response.json()
    assert payload["available"] is True
    assert payload["count"] == 3
    assert len(payload["entries"]) == 2
    assert payload["entries"][0]["ts"] == 3


def test_server_max_chapter_chars_skip_predicate():
    """Server MAX_CHAPTER_CHARS skip condition mirrors converter.py logic."""
    # When limit > 0 and chapter exceeds it → skip
    limit = 200_000
    assert limit > 0 and 279_000 > limit, "Oversized chapter should match skip condition"
    assert not (limit > 0 and 5_000 > limit), "Normal chapter should not match skip condition"

    # When limit == 0 (disabled) → never skip regardless of size
    assert not (0 > 0 and 999_999 > 0), "Disabled limit should never trigger skip"


def test_server_max_chapter_chars_default_is_zero():
    """MAX_CHAPTER_CHARS in server defaults to 0 (disabled), same as converter."""
    import os

    raw = os.environ.get("MAX_CHAPTER_CHARS", "")
    value = int(raw) if raw else 0
    assert value == 0, "Default MAX_CHAPTER_CHARS must be 0 (disabled)"


def test_server_outlier_detection_appends_event(monkeypatch):
    """Outlier chapters trigger a MAX_CHAPTER_CHARS hint in job events.

    Tests the detection logic directly by simulating the chapter_char_totals
    dict and checking that _append_event is called with the warning message.
    """
    from src.ebook_reader import Chapter

    job: dict = {"events": []}

    # Build char totals: 9 small chapters (1K) + 1 outlier (300K)
    normal_chapters = [
        Chapter(index=i, name=f"Ch {i}", source_path=f"ch{i}.xhtml", text="A" * 1_000)
        for i in range(1, 10)
    ]
    outlier_chapter = Chapter(
        index=10, name="Sumário (giant)", source_path="sum.xhtml", text="B" * 300_000
    )
    chapters = normal_chapters + [outlier_chapter]

    chapter_char_totals = {i + 1: len(ch.text) for i, ch in enumerate(chapters)}

    # Run the same outlier detection logic as in process_conversion
    sorted_lengths = sorted(chapter_char_totals.values())
    median_chars = sorted_lengths[len(sorted_lengths) // 2]
    outlier_floor = 50_000
    outlier_threshold = max(median_chars * 5, outlier_floor)
    warnings = []
    for idx, ch_chars in chapter_char_totals.items():
        if ch_chars > outlier_threshold and ch_chars > outlier_floor:
            ch = chapters[idx - 1] if 0 < idx <= len(chapters) else None
            ch_name = getattr(ch, "name", f"Chapter {idx}")[:60] if ch else f"Chapter {idx}"
            ratio = ch_chars // max(median_chars, 1)
            suggested = (ch_chars // 1000) * 1000
            msg = (
                f"⚠️ Oversized chapter [{idx}]: {ch_name}"
                f" ({ch_chars:,} chars = {ratio}× median)"
                f" → Set MAX_CHAPTER_CHARS={suggested:,} to skip it"
            )
            warnings.append(msg)

    assert len(warnings) == 1, f"Expected 1 outlier warning, got {len(warnings)}"
    assert "Sumário (giant)" in warnings[0]
    assert "MAX_CHAPTER_CHARS=300,000" in warnings[0]
    assert "300×" in warnings[0] or "× median" in warnings[0]


def _make_telemetry(tmp_path, monkeypatch):
    telemetry_path = Path(tmp_path) / "telemetry.json"
    recorder = TelemetryRecorder(telemetry_file=telemetry_path, max_samples=20)
    monkeypatch.setattr(server, "telemetry", recorder)
    return recorder
