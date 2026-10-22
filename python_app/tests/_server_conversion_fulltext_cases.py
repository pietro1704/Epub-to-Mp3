"""Fulltext regression scenarios, collected by test_server_conversion."""

from __future__ import annotations

from python_app.tests._server_conversion_test_support import (
    DummyFactory as DummyFactory,
    DummyTTSEngine as DummyTTSEngine,
    FIXTURE_BOOK as FIXTURE_BOOK,
    Path as Path,
    TestClient as TestClient,
    _configure_server_paths as _configure_server_paths,
    _fake_convert_to_mp3 as _fake_convert_to_mp3,
    _make_telemetry as _make_telemetry,
    asyncio as asyncio,
    server as server,
    uuid4 as uuid4,
)

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
    assert "sourcePath" in payload["chapters"][0]
    assert "footnotes" in payload["chapters"][0]

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
                        "html": '<p class="chapter">Cached text body.</p>',
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
            "sourcePath": None,
            "text": "Cached text body.",
            "html": '<p class="chapter">Cached text body.</p>',
            "css": ".chapter { font-style: italic; }",
            "resources": [],
            "footnotes": None,
            "charCount": len("Cached text body."),
        }
    ]

    server.jobs.pop(job_id, None)


def test_job_fulltext_returns_503_when_source_missing_and_job_running(tmp_path, monkeypatch):
    """Source file missing on a running job is transient — return 503 so the
    UI retries instead of showing a permanent error."""
    job_id = str(uuid4())
    _configure_server_paths(tmp_path, monkeypatch)

    upload_path = tmp_path / f"{job_id}_book.epub"
    # Intentionally do NOT write the file — simulates upload-in-progress.

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": [],
        "file_path": str(upload_path),
        "bookTitle": "Pending Book",
    }

    class EmptyCacheManager:
        def get_cached_chapters(self, _ebook_path):
            return None

        def save_chapters_to_cache(self, *_args, **_kwargs):
            return True

    monkeypatch.setattr(server, "get_cache_manager", lambda: EmptyCacheManager())

    client = TestClient(server.app)
    response = client.get(f"/api/jobs/{job_id}/fulltext")

    assert response.status_code == 503
    assert "retry" in response.json().get("detail", "").lower()
    server.jobs.pop(job_id, None)


def test_job_fulltext_returns_404_when_source_missing_and_job_failed(tmp_path, monkeypatch):
    """Once the job is in a terminal failed state, a missing source file is
    a permanent 404 — there is no point in the UI retrying forever."""
    job_id = str(uuid4())
    _configure_server_paths(tmp_path, monkeypatch)

    upload_path = tmp_path / f"{job_id}_book.epub"
    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "failed",
        "events": [],
        "file_path": str(upload_path),
    }

    class EmptyCacheManager:
        def get_cached_chapters(self, _ebook_path):
            return None

        def save_chapters_to_cache(self, *_args, **_kwargs):
            return True

    monkeypatch.setattr(server, "get_cache_manager", lambda: EmptyCacheManager())

    client = TestClient(server.app)
    response = client.get(f"/api/jobs/{job_id}/fulltext")

    assert response.status_code == 404
    server.jobs.pop(job_id, None)


def test_job_fulltext_uses_cache_even_when_source_file_is_gone(tmp_path, monkeypatch):
    """If the source file was cleaned up but the cache still holds the parsed
    chapters, the reader must keep working."""
    job_id = str(uuid4())
    _configure_server_paths(tmp_path, monkeypatch)

    upload_path = tmp_path / f"{job_id}_book.epub"
    # Source file deliberately absent — cache should be the source of truth.

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "completed",
        "events": [],
        "file_path": str(upload_path),
        "bookTitle": "Recovered From Cache",
    }

    class WarmCacheManager:
        def get_cached_chapters(self, _ebook_path):
            return {
                "title": "Recovered From Cache",
                "author": "",
                "chapters": [
                    {
                        "title": "Only Chapter",
                        "text": "Body.",
                        "html": "<p>Body.</p>",
                        "css": "",
                    },
                ],
            }

        def save_chapters_to_cache(self, *_args, **_kwargs):
            return True

    monkeypatch.setattr(server, "get_cache_manager", lambda: WarmCacheManager())

    def fail_reader(*_args, **_kwargs):
        raise AssertionError("EbookReader must not be used when the cache satisfies the request")

    monkeypatch.setattr(server, "EbookReader", fail_reader)

    client = TestClient(server.app)
    response = client.get(f"/api/jobs/{job_id}/fulltext")

    assert response.status_code == 200
    payload = response.json()
    assert payload["bookTitle"] == "Recovered From Cache"
    assert len(payload["chapters"]) == 1
    server.jobs.pop(job_id, None)


def test_job_fulltext_returns_422_when_parsing_yields_no_chapters_on_failed_job(
    tmp_path, monkeypatch
):
    """A parseable but chapter-less file on a failed job is a hard error so
    the UI shows a permanent message instead of spinning forever."""
    job_id = str(uuid4())
    _configure_server_paths(tmp_path, monkeypatch)

    upload_path = tmp_path / f"{job_id}_book.epub"
    upload_path.write_bytes(FIXTURE_BOOK.read_bytes())

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "failed",
        "events": [],
        "file_path": str(upload_path),
    }

    class EmptyCacheManager:
        def get_cached_chapters(self, _ebook_path):
            return None

        def save_chapters_to_cache(self, *_args, **_kwargs):
            return True

    monkeypatch.setattr(server, "get_cache_manager", lambda: EmptyCacheManager())

    class StubReader:
        def __init__(self, *_args, **_kwargs):
            pass

        def get_chapter_structure(self, *_args, **_kwargs):
            return []

        def extract_chapter_stylesheet(self, *_args, **_kwargs):
            return ""

    monkeypatch.setattr(server, "EbookReader", StubReader)

    client = TestClient(server.app)
    response = client.get(f"/api/jobs/{job_id}/fulltext")

    assert response.status_code == 422
    server.jobs.pop(job_id, None)
