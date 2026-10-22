"""Endpoints regression scenarios, collected by test_server_conversion."""

from __future__ import annotations

from python_app.tests._server_conversion_test_support import (
    FIXTURE_BOOK as FIXTURE_BOOK,
    MINIMAL_MP3 as MINIMAL_MP3,
    Path as Path,
    TestClient as TestClient,
    _configure_server_paths as _configure_server_paths,
    _fake_convert_to_mp3 as _fake_convert_to_mp3,
    _make_telemetry as _make_telemetry,
    asyncio as asyncio,
    json as json,
    server as server,
    uuid4 as uuid4,
)

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


def test_convert_endpoint_persists_priority_chapter_index(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    _make_telemetry(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "_enqueue_job", lambda job_id: True)

    client = TestClient(server.app)
    response = client.post(
        "/api/convert",
        files={"file": ("book.epub", FIXTURE_BOOK.read_bytes(), "application/epub+zip")},
        data={"engine": "edge", "priority_chapter_index": "3"},
    )
    assert response.status_code == 200

    job_id = response.json()["jobId"]
    assert server.jobs[job_id]["priorityChapterIndex"] == 3

    saved = server.job_manager.load_job(job_id)
    assert saved is not None
    assert saved["priorityChapterIndex"] == 3

    server.jobs.pop(job_id, None)


def test_convert_endpoint_ignores_invalid_priority_chapter_index(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    _make_telemetry(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "_enqueue_job", lambda job_id: True)

    client = TestClient(server.app)
    response = client.post(
        "/api/convert",
        files={"file": ("book.epub", FIXTURE_BOOK.read_bytes(), "application/epub+zip")},
        data={"engine": "edge", "priority_chapter_index": "abc"},
    )
    assert response.status_code == 200

    job_id = response.json()["jobId"]
    assert server.jobs[job_id].get("priorityChapterIndex") is None

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
