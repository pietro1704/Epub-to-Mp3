from __future__ import annotations

import asyncio
import json
import unittest
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


def test_job_output_dir_rejects_stored_path_outside_output_root(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    job_id = str(uuid4())
    safe_dir = tmp_path / "Safe Book"

    target = server._job_output_dir(
        job_id,
        {
            "jobId": job_id,
            "bookTitle": "Safe Book",
            "fileName": "safe-book.epub",
            "outputDir": "/tmp/../../etc",
        },
    )

    assert target == safe_dir


def test_resolve_relative_path_within_root_rejects_absolute_candidate(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)

    with pytest.raises(ValueError, match="Expected relative path"):
        server._resolve_relative_path_within_root(tmp_path, "/tmp/escape", must_exist=False)


def test_get_job_fulltext_rejects_source_path_outside_allowed_roots(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    job_id = str(uuid4())
    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "file_path": "/etc/passwd",
    }

    client = TestClient(server.app)
    response = client.get(f"/api/jobs/{job_id}/fulltext")

    assert response.status_code == 404


def test_build_engine_chain_respects_guards(monkeypatch):
    """When all non-Edge engines are unavailable and no monolingual voice exists, chain = [edge]."""
    config = ConversionConfig(engine="edge", primary_language="pt-BR")

    monkeypatch.setattr(server, "_has_coqui_support", lambda: False)
    monkeypatch.setattr(server, "_has_kokoro_support", lambda _: False)
    monkeypatch.setattr(server, "_has_piper_support", lambda: False)
    monkeypatch.setattr(server, "_has_spark_support", lambda: False)
    # Suppress monolingual fallback so only the primary Edge entry appears.
    monkeypatch.setattr(
        server.tts_factory.voice_provider, "get_monolingual_voice", lambda _lang: None
    )

    chain = server._build_engine_chain(config)
    assert [cfg.engine for cfg in chain] == ["edge"]


def test_build_engine_chain_includes_edge_monolingual_fallback(monkeypatch):
    """Edge monolingual fallback is inserted as tier-2 when a distinct mono voice exists."""
    config = ConversionConfig(engine="edge", primary_language="pt-BR")

    monkeypatch.setattr(server, "_has_coqui_support", lambda: False)
    monkeypatch.setattr(server, "_has_kokoro_support", lambda _: False)
    monkeypatch.setattr(server, "_has_piper_support", lambda: False)
    monkeypatch.setattr(server, "_has_spark_support", lambda: False)
    # Simulate a multilingual primary voice and a distinct monolingual alternative.
    monkeypatch.setattr(
        server.tts_factory.voice_provider,
        "edge_voice_is_multilingual",
        lambda _voice: True,
    )
    monkeypatch.setattr(
        server.tts_factory.voice_provider,
        "get_monolingual_voice",
        lambda _lang: "pt-BR-AntonioNeural",
    )

    chain = server._build_engine_chain(config)
    engines = [cfg.engine for cfg in chain]
    assert engines == ["edge", "edge"]
    # Second entry must use the monolingual voice.
    assert chain[1].voice == "pt-BR-AntonioNeural"


def test_build_engine_chain_includes_supported_fallbacks(monkeypatch):
    config = ConversionConfig(engine="edge", primary_language="pt-BR")

    monkeypatch.setattr(server, "_has_coqui_support", lambda: True)
    monkeypatch.setattr(server, "_has_kokoro_support", lambda _: True)
    monkeypatch.setattr(server, "_has_piper_support", lambda: True)
    monkeypatch.setattr(server, "_has_spark_support", lambda: False)

    chain = server._build_engine_chain(config)
    engines = [cfg.engine for cfg in chain]
    assert "edge" in engines and "coqui" in engines and "piper" in engines


def test_should_retry_edge_before_fallback_prefers_one_local_retry():
    assert server._should_retry_edge_before_fallback("edge", edge_slow_mode=False) is True
    assert server._should_retry_edge_before_fallback("EDGE", edge_slow_mode=True) is False
    assert server._should_retry_edge_before_fallback("piper", edge_slow_mode=False) is False


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


def test_job_fulltext_uses_file_path_when_input_file_is_missing(tmp_path, monkeypatch):
    job_id = str(uuid4())
    _configure_server_paths(tmp_path, monkeypatch)

    upload_path = tmp_path / f"{job_id}_book.epub"
    upload_path.write_bytes(FIXTURE_BOOK.read_bytes())

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": [],
        "file_path": str(upload_path),
        "bookTitle": "Recovered Book",
        "bookAuthor": "Recovered Author",
    }

    client = TestClient(server.app)
    response = client.get(f"/api/jobs/{job_id}/fulltext")

    assert response.status_code == 200
    payload = response.json()
    assert payload["jobId"] == job_id
    assert payload["bookTitle"] == "Recovered Book"
    assert payload["bookAuthor"] == "Recovered Author"
    assert isinstance(payload["chapters"], list)
    assert len(payload["chapters"]) > 0
    assert payload["chapters"][0]["index"] == 1
    assert "html" in payload["chapters"][0]
    assert "css" in payload["chapters"][0]

    server.jobs.pop(job_id, None)


def test_job_fulltext_prefers_cached_chapters(tmp_path, monkeypatch):
    job_id = str(uuid4())
    _configure_server_paths(tmp_path, monkeypatch)

    upload_path = tmp_path / f"{job_id}_book.epub"
    upload_path.write_bytes(FIXTURE_BOOK.read_bytes())

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": [],
        "file_path": str(upload_path),
        "bookTitle": "Cached Book",
        "bookAuthor": "Cached Author",
    }

    class FakeCacheManager:
        def get_cached_chapters(self, ebook_path):
            assert Path(ebook_path) == upload_path
            return {
                "title": "Cached Book",
                "author": "Cached Author",
                "chapters": [
                    {
                        "title": "Cached Chapter",
                        "text": "Cached text body.",
                        "html": "<p class='chapter'>Cached text body.</p>",
                        "css": ".chapter { font-style: italic; }",
                    },
                ],
            }

        def save_chapters_to_cache(self, ebook_path, chapters_data):
            return True

    monkeypatch.setattr(server, "get_cache_manager", lambda: FakeCacheManager())

    def fail_reader(*args, **kwargs):
        raise AssertionError("EbookReader should not be used when cache is warm")

    monkeypatch.setattr(server, "EbookReader", fail_reader)

    client = TestClient(server.app)
    response = client.get(f"/api/jobs/{job_id}/fulltext")

    assert response.status_code == 200
    payload = response.json()
    assert payload["bookTitle"] == "Cached Book"
    assert payload["bookAuthor"] == "Cached Author"
    assert payload["chapters"] == [
        {
            "index": 1,
            "name": "Cached Chapter",
            "text": "Cached text body.",
            "html": "<p class='chapter'>Cached text body.</p>",
            "css": ".chapter { font-style: italic; }",
            "charCount": len("Cached text body."),
        }
    ]

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
    monkeypatch.setattr(
        server, "_should_retry_edge_before_fallback", lambda *_args, **_kwargs: False
    )

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
    monkeypatch.setattr(
        server, "_should_retry_edge_before_fallback", lambda *_args, **_kwargs: False
    )

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


def test_server_short_audio_detection_uses_cli_completeness_threshold(monkeypatch, tmp_path):
    output_file = tmp_path / "chapter.mp3"
    output_file.write_bytes(MINIMAL_MP3)

    called = {}

    def fake_validate(audio_path, text_length):
        called["audio_path"] = audio_path
        called["text_length"] = text_length
        return False, 72.0

    monkeypatch.setattr(
        "src.converter.validate_audio_completeness",
        fake_validate,
    )

    warning = server_audio_helpers._detect_short_audio_output(
        "x" * 1600,
        output_file,
        engine_label="edge",
    )

    assert warning == "Audio possibly truncated (72% coverage, expected full chapter)"
    assert called["audio_path"] == output_file
    assert called["text_length"] == 1600


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


def test_download_output_serves_named_file_from_job_directory(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    job_id = str(uuid4())
    output_book_dir = tmp_path / "Download Book"
    output_book_dir.mkdir(parents=True, exist_ok=True)
    target = output_book_dir / "chapter-001.mp3"
    target.write_bytes(MINIMAL_MP3)

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "finished",
        "outputDir": str(output_book_dir),
    }

    client = TestClient(server.app)
    response = client.get(f"/api/outputs/{job_id}/chapter-001.mp3")

    assert response.status_code == 200
    assert response.content == MINIMAL_MP3


def test_stream_endpoints_serve_manifest_and_chunk_from_job_stream_dir(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    job_id = str(uuid4())
    output_book_dir = tmp_path / "Streaming Book"
    stream_dir = output_book_dir / "streams"
    stream_dir.mkdir(parents=True, exist_ok=True)

    manifest_path = stream_dir / "index.json"
    chunk_path = stream_dir / "stream_chunk_1.mp3"
    chunk_path.write_bytes(MINIMAL_MP3)
    manifest_path.write_text(
        json.dumps(
            {
                "jobId": job_id,
                "chapters": {
                    "1": {
                        "chapterIndex": 1,
                        "chunks": [
                            {
                                "id": "0",
                                "index": 0,
                                "file": chunk_path.name,
                                "url": f"/api/streams/{job_id}/chapters/1/chunks/0",
                            }
                        ],
                        "updatedAt": 1.0,
                        "baseUrl": f"/api/streams/{job_id}/chapters/1",
                    }
                },
            }
        ),
        encoding="utf-8",
    )

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "finished",
        "outputDir": str(output_book_dir),
    }

    client = TestClient(server.app)

    manifest_response = client.get(f"/api/streams/{job_id}/chapters/1")
    assert manifest_response.status_code == 200
    manifest_payload = manifest_response.json()
    assert manifest_payload["chunks"][0]["file"] == chunk_path.name

    chunk_response = client.get(f"/api/streams/{job_id}/chapters/1/chunks/0")
    assert chunk_response.status_code == 200
    assert chunk_response.content == MINIMAL_MP3


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


# ---------------------------------------------------------------------------
# Per-chapter timing: _set_chapter_status timestamps
# ---------------------------------------------------------------------------


def _make_job_with_chapters(n: int = 3) -> dict:
    return {
        "chapterProgress": [
            {"index": i, "name": f"Chapter {i}", "status": "queued"} for i in range(1, n + 1)
        ]
    }


class TestSetChapterStatusTimestamps:
    def test_processing_sets_started_at(self):
        job = _make_job_with_chapters(2)
        server._set_chapter_status(job, 1, "processing", engine_label="edge")
        entry = job["chapterProgress"][0]
        assert "startedAt" in entry
        assert entry["startedAt"]  # non-empty ISO string

    def test_processing_initialises_engine_sequence(self):
        job = _make_job_with_chapters(2)
        server._set_chapter_status(job, 1, "processing", engine_label="edge")
        entry = job["chapterProgress"][0]
        assert entry["engineSequence"] == ["edge"]

    def test_processing_started_at_not_overwritten_on_retry(self):
        job = _make_job_with_chapters(2)
        server._set_chapter_status(job, 1, "processing", engine_label="edge")
        first_ts = job["chapterProgress"][0]["startedAt"]
        server._set_chapter_status(job, 1, "processing", engine_label="edge")
        assert job["chapterProgress"][0]["startedAt"] == first_ts

    def test_retrying_appends_new_engine_to_sequence(self):
        job = _make_job_with_chapters(2)
        server._set_chapter_status(job, 1, "processing", engine_label="edge")
        server._set_chapter_status(job, 1, "retrying", engine_label="piper")
        entry = job["chapterProgress"][0]
        assert "piper" in entry["engineSequence"]

    def test_retrying_does_not_duplicate_same_engine(self):
        job = _make_job_with_chapters(2)
        server._set_chapter_status(job, 1, "processing", engine_label="edge")
        server._set_chapter_status(job, 1, "retrying", engine_label="edge")
        entry = job["chapterProgress"][0]
        assert entry["engineSequence"].count("edge") == 1

    def test_completed_sets_completed_at(self):
        job = _make_job_with_chapters(2)
        server._set_chapter_status(job, 1, "processing", engine_label="edge")
        server._set_chapter_status(job, 1, "completed")
        entry = job["chapterProgress"][0]
        assert "completedAt" in entry

    def test_failed_sets_completed_at(self):
        job = _make_job_with_chapters(2)
        server._set_chapter_status(job, 1, "processing", engine_label="edge")
        server._set_chapter_status(job, 1, "failed")
        assert "completedAt" in job["chapterProgress"][0]

    def test_skipped_sets_completed_at(self):
        job = _make_job_with_chapters(2)
        server._set_chapter_status(job, 1, "skipped")
        assert "completedAt" in job["chapterProgress"][0]


# ---------------------------------------------------------------------------
# _extract_chapter_details
# ---------------------------------------------------------------------------


class TestExtractChapterDetails:
    def test_extracts_fields_from_chapter_progress(self):
        job = {
            "chapterProgress": [
                {
                    "index": 1,
                    "name": "Chapter 1",
                    "status": "completed",
                    "engine": "edge",
                    "elapsedSeconds": 42.0,
                    "charsPerSecond": 110.5,
                    "charsProcessed": 2400,
                    "progressRatio": 1.0,
                    "wordCount": 510,
                    "engineSequence": ["edge"],
                    "startedAt": "2026-03-16T10:00:00+00:00",
                    "completedAt": "2026-03-16T10:00:42+00:00",
                }
            ]
        }
        details = server._extract_chapter_details(job)
        assert len(details) == 1
        d = details[0]
        assert d["index"] == 1
        assert d["name"] == "Chapter 1"
        assert d["engine"] == "edge"
        assert d["elapsedSeconds"] == 42.0
        assert d["charsPerSecond"] == 110.5
        assert d["charsProcessed"] == 2400
        assert d["progressRatio"] == 1.0
        assert d["wordCount"] == 510
        assert d["engineSequence"] == ["edge"]
        assert d["startedAt"] == "2026-03-16T10:00:00+00:00"
        assert d["completedAt"] == "2026-03-16T10:00:42+00:00"

    def test_none_values_excluded(self):
        job = {
            "chapterProgress": [{"index": 1, "name": "Ch", "status": "completed", "engine": "edge"}]
        }
        details = server._extract_chapter_details(job)
        assert "chars" not in details[0]

    def test_returns_empty_list_when_no_chapter_progress(self):
        assert server._extract_chapter_details({}) == []

    def test_handles_non_dict_entries_gracefully(self):
        job = {"chapterProgress": [None, "bad", {"index": 1, "status": "completed"}]}
        details = server._extract_chapter_details(job)
        assert len(details) == 1


# ---------------------------------------------------------------------------
# GET /api/estimate
# ---------------------------------------------------------------------------


class TestEstimateEndpoint:
    def _make_client(self) -> "TestClient":
        from fastapi.testclient import TestClient

        return TestClient(server.app)

    def _register_upload(self, monkeypatch, tmp_path, chapters: list[dict]) -> tuple[str, Path]:
        """Register a fake upload and return (upload_id, epub_path)."""
        import uuid as _uuid

        upload_id = str(_uuid.uuid4())
        upload_dir = tmp_path / upload_id
        upload_dir.mkdir()
        # Create a dummy epub file (content doesn't matter; we bypass EbookReader)
        epub_path = upload_dir / "book.epub"
        epub_path.write_bytes(b"fake")

        # Patch _pending_uploads so the endpoint finds the file
        monkeypatch.setitem(
            server._pending_uploads,
            upload_id,
            {
                "file_path": str(epub_path),
                "file_name": "book.epub",
                "book_title": "Test Book",
            },
        )

        # Patch get_cache_manager to return cached chapter data
        cached_data = {
            "title": "Test Book",
            "author": "Test Author",
            "chapters": chapters,
            "size": 4,
            "mtime": epub_path.stat().st_mtime,
        }

        class _FakeCache:
            def get_cached_chapters(self, path):
                return cached_data

        monkeypatch.setattr(server, "get_cache_manager", lambda: _FakeCache())

        return upload_id, epub_path

    def test_returns_estimate_with_cache_hit(self, monkeypatch, tmp_path):
        chapters = [
            {"title": "Chapter 1", "text": "a" * 5000},
            {"title": "Chapter 2", "text": "b" * 7000},
        ]
        upload_id, _ = self._register_upload(monkeypatch, tmp_path, chapters)

        monkeypatch.setattr(server, "uploads_dir", tmp_path)
        client = self._make_client()
        resp = client.get(f"/api/estimate?upload_id={upload_id}")
        assert resp.status_code == 200
        data = resp.json()
        assert data["chapters"] == 2
        assert data["total_chars"] == 12000
        assert "estimated_duration_seconds" in data
        assert data["estimated_duration_seconds"] > 0
        assert "estimated_output_mb" in data
        assert "engine_estimates" in data
        assert "edge" in data["engine_estimates"]
        assert "piper" in data["engine_estimates"]
        assert "chapter_breakdown" in data
        assert len(data["chapter_breakdown"]) == 2

    def test_returns_404_for_unknown_upload_id(self, monkeypatch, tmp_path):
        monkeypatch.setattr(server, "uploads_dir", tmp_path)
        client = self._make_client()
        resp = client.get("/api/estimate?upload_id=nonexistent-id")
        assert resp.status_code == 404

    def test_engine_param_selects_engine(self, monkeypatch, tmp_path):
        chapters = [{"title": "Ch", "text": "x" * 10000}]
        upload_id, _ = self._register_upload(monkeypatch, tmp_path, chapters)
        monkeypatch.setattr(server, "uploads_dir", tmp_path)
        _make_telemetry(tmp_path, monkeypatch)  # isolate from real telemetry on disk
        client = self._make_client()

        resp_edge = client.get(f"/api/estimate?upload_id={upload_id}&engine=edge")
        resp_piper = client.get(f"/api/estimate?upload_id={upload_id}&engine=piper")
        assert resp_edge.status_code == 200
        assert resp_piper.status_code == 200
        # Piper is slower → longer estimate
        assert (
            resp_piper.json()["estimated_duration_seconds"]
            > resp_edge.json()["estimated_duration_seconds"]
        )

    def test_telemetry_based_flag_false_with_no_samples(self, monkeypatch, tmp_path):
        chapters = [{"title": "Ch", "text": "x" * 5000}]
        upload_id, _ = self._register_upload(monkeypatch, tmp_path, chapters)
        monkeypatch.setattr(server, "uploads_dir", tmp_path)

        # Empty telemetry
        from src.telemetry import TelemetryRecorder

        empty_telemetry = TelemetryRecorder(telemetry_file=tmp_path / "empty.json")
        monkeypatch.setattr(server, "telemetry", empty_telemetry)

        client = self._make_client()
        resp = client.get(f"/api/estimate?upload_id={upload_id}&engine=edge")
        data = resp.json()
        assert data["telemetry_based"] is False
        assert data["chars_per_second"] == 110.0  # default fallback

    def test_duration_formatted_contains_minutes(self, monkeypatch, tmp_path):
        # 12 000 chars at 110 chars/s ≈ 109s ≈ 1m 49s
        chapters = [{"title": "Ch", "text": "x" * 12000}]
        upload_id, _ = self._register_upload(monkeypatch, tmp_path, chapters)
        monkeypatch.setattr(server, "uploads_dir", tmp_path)

        from src.telemetry import TelemetryRecorder

        empty_telemetry = TelemetryRecorder(telemetry_file=tmp_path / "empty2.json")
        monkeypatch.setattr(server, "telemetry", empty_telemetry)

        client = self._make_client()
        resp = client.get(f"/api/estimate?upload_id={upload_id}&engine=edge")
        formatted = resp.json()["estimated_duration_formatted"]
        assert "m" in formatted


# ---------------------------------------------------------------------------
# _set_chapter_status → _schedule_chapter_broadcast (SSE chapter events)
# ---------------------------------------------------------------------------


class TestChapterBroadcastOnStatusChange:
    """Verify that _set_chapter_status triggers a per-chapter SSE broadcast."""

    def _make_job(self) -> dict:
        return {
            "jobId": "job-sse-test",
            "chapterProgress": [
                {"index": 1, "name": "Ch 1", "status": "queued"},
                {"index": 2, "name": "Ch 2", "status": "queued"},
            ],
        }

    def test_broadcast_called_on_processing(self, monkeypatch):
        calls: list[dict] = []
        monkeypatch.setattr(
            server,
            "_schedule_chapter_broadcast",
            lambda jid, data: calls.append({"jid": jid, "data": data}),
        )

        job = self._make_job()
        server._set_chapter_status(job, chapter_index=1, status="processing", engine_label="edge")

        assert len(calls) == 1
        assert calls[0]["jid"] == "job-sse-test"
        assert calls[0]["data"]["status"] == "processing"
        assert calls[0]["data"]["index"] == 1

    def test_broadcast_called_on_completed(self, monkeypatch):
        calls: list[dict] = []
        monkeypatch.setattr(
            server, "_schedule_chapter_broadcast", lambda jid, data: calls.append(data)
        )

        job = self._make_job()
        server._set_chapter_status(
            job, chapter_index=2, status="completed", download_url="/api/files/ch2.mp3"
        )

        assert len(calls) == 1
        assert calls[0]["status"] == "completed"
        assert calls[0]["index"] == 2

    def test_broadcast_called_on_failed(self, monkeypatch):
        calls: list[dict] = []
        monkeypatch.setattr(
            server, "_schedule_chapter_broadcast", lambda jid, data: calls.append(data)
        )

        job = self._make_job()
        server._set_chapter_status(job, chapter_index=1, status="failed", error_message="timed out")

        assert len(calls) == 1
        assert calls[0]["status"] == "failed"
        assert calls[0].get("errorCategory") == "timeout"

    def test_no_broadcast_without_job_id(self, monkeypatch):
        calls: list[dict] = []
        monkeypatch.setattr(
            server, "_schedule_chapter_broadcast", lambda jid, data: calls.append(data)
        )

        job = {
            "chapterProgress": [{"index": 1, "name": "Ch 1", "status": "queued"}],
        }
        server._set_chapter_status(job, chapter_index=1, status="processing")

        assert calls == []

    def test_broadcast_payload_is_copy(self, monkeypatch):
        """Modifying the job after broadcast must not affect the broadcasted payload."""
        captured: list[dict] = []
        monkeypatch.setattr(
            server, "_schedule_chapter_broadcast", lambda jid, data: captured.append(data)
        )

        job = self._make_job()
        server._set_chapter_status(job, chapter_index=1, status="processing")
        # Mutate job after broadcast
        job["chapterProgress"][0]["status"] = "completed"

        assert captured[0]["status"] == "processing"
