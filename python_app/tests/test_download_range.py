"""Byte-range support for /api/outputs and /api/streams chunk downloads.

The mobile clients (SwiftUI iOS + Flutter offline cache) rely on HTTP
range requests so they can resume interrupted downloads of large
chapter MP3s and so AVQueuePlayer / just_audio can seek within a
chapter without re-downloading from byte 0.

FastAPI/Starlette's `FileResponse` advertises and honours `Range:`
headers automatically, but a regression to e.g. `StreamingResponse`
(which does NOT) would silently break mobile seek/resume. These
tests pin the contract on both download surfaces — final outputs
and progressive stream chunks — so any such drift fails CI
immediately.
"""

from __future__ import annotations

import json
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from python_app import server
from python_app.src.job_manager import JobManager

MINIMAL_MP3 = bytes([0xFF, 0xFB, 0x90, 0x00]) * 64  # 256 bytes — easy to range over


def _configure(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    uploads = tmp_path / ".uploads"
    uploads.mkdir(exist_ok=True)
    jobs_dir = tmp_path / ".jobs"
    jobs_dir.mkdir(exist_ok=True)
    monkeypatch.setattr(server, "output_dir", tmp_path)
    monkeypatch.setattr(server, "persistent_root", tmp_path)
    monkeypatch.setattr(server, "uploads_dir", uploads)
    monkeypatch.setattr(server, "job_manager", JobManager(jobs_dir))


def _seed_mp3(tmp_path: Path, payload: bytes = MINIMAL_MP3) -> tuple[str, str]:
    job_id = str(uuid4())
    book_dir = tmp_path / "Range Book"
    book_dir.mkdir(parents=True, exist_ok=True)
    target = book_dir / "chapter-001.mp3"
    target.write_bytes(payload)
    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "finished",
        "outputDir": str(book_dir),
    }
    return job_id, "chapter-001.mp3"


def test_full_download_returns_200_with_full_body(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    job_id, name = _seed_mp3(tmp_path)

    client = TestClient(server.app)
    response = client.get(f"/api/outputs/{job_id}/{name}")

    assert response.status_code == 200
    assert response.content == MINIMAL_MP3
    # Whether or not Accept-Ranges is advertised, the body must be the
    # full payload. (Starlette emits `accept-ranges: bytes` on
    # FileResponse; we don't assert it here so we stay resilient to
    # header-case changes.)


def test_range_request_returns_206_with_partial_body(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    job_id, name = _seed_mp3(tmp_path)

    client = TestClient(server.app)
    response = client.get(
        f"/api/outputs/{job_id}/{name}",
        headers={"Range": "bytes=0-9"},
    )

    assert response.status_code == 206, (
        "FileResponse must honour Range: headers — mobile clients need "
        "partial content for resume + seek."
    )
    assert response.content == MINIMAL_MP3[:10]
    # Content-Range must reflect the actual range served.
    content_range = response.headers.get("content-range", "")
    assert content_range.startswith("bytes 0-9/"), content_range
    assert content_range.endswith(f"/{len(MINIMAL_MP3)}"), content_range
    assert response.headers.get("content-length") == "10"


def test_range_request_open_ended_serves_rest_of_file(tmp_path, monkeypatch):
    """`Range: bytes=100-` must serve from byte 100 to EOF."""
    _configure(tmp_path, monkeypatch)
    job_id, name = _seed_mp3(tmp_path)

    client = TestClient(server.app)
    response = client.get(
        f"/api/outputs/{job_id}/{name}",
        headers={"Range": "bytes=100-"},
    )

    assert response.status_code == 206
    assert response.content == MINIMAL_MP3[100:]
    # Content-Range: bytes 100-255/256
    expected_end = len(MINIMAL_MP3) - 1
    assert response.headers.get("content-range") == (f"bytes 100-{expected_end}/{len(MINIMAL_MP3)}")


def test_range_request_suffix_serves_last_n_bytes(tmp_path, monkeypatch):
    """`Range: bytes=-50` must serve the LAST 50 bytes of the file."""
    _configure(tmp_path, monkeypatch)
    job_id, name = _seed_mp3(tmp_path)

    client = TestClient(server.app)
    response = client.get(
        f"/api/outputs/{job_id}/{name}",
        headers={"Range": "bytes=-50"},
    )

    assert response.status_code == 206
    assert response.content == MINIMAL_MP3[-50:]


def test_range_request_unsatisfiable_returns_416(tmp_path, monkeypatch):
    """Out-of-bounds ranges must respond 416 Range Not Satisfiable."""
    _configure(tmp_path, monkeypatch)
    job_id, name = _seed_mp3(tmp_path)

    client = TestClient(server.app)
    response = client.get(
        f"/api/outputs/{job_id}/{name}",
        # File is 256 bytes; bytes=1000-2000 cannot be satisfied.
        headers={"Range": "bytes=1000-2000"},
    )

    assert response.status_code == 416, (
        "Unsatisfiable ranges must return HTTP 416 per RFC 7233 — "
        "mobile clients depend on this to fall back to a full GET."
    )
    # Per RFC 7233 §4.4, a 416 MUST advertise the full size so the
    # client can issue a satisfiable request next.
    content_range = response.headers.get("content-range", "")
    assert content_range == f"bytes */{len(MINIMAL_MP3)}", content_range


def test_full_response_advertises_accept_ranges_and_audio_content_type(tmp_path, monkeypatch):
    """A bare GET on an MP3 output must advertise `Accept-Ranges: bytes`
    and the correct audio content-type, so the mobile player can decide
    to resume / seek without a preliminary HEAD probe.
    """
    _configure(tmp_path, monkeypatch)
    job_id, name = _seed_mp3(tmp_path)

    client = TestClient(server.app)
    response = client.get(f"/api/outputs/{job_id}/{name}")

    assert response.status_code == 200
    assert response.headers.get("accept-ranges", "").lower() == "bytes"
    assert response.headers.get("content-type", "").lower().startswith("audio/mpeg")
    assert response.headers.get("content-length") == str(len(MINIMAL_MP3))


def test_head_request_returns_headers_without_body(tmp_path, monkeypatch):
    """HEAD lets mobile clients learn `Content-Length` + `Accept-Ranges`
    before scheduling a background download. The body must be empty.
    """
    _configure(tmp_path, monkeypatch)
    job_id, name = _seed_mp3(tmp_path)

    client = TestClient(server.app)
    response = client.head(f"/api/outputs/{job_id}/{name}")

    assert response.status_code == 200
    assert response.content == b""
    assert response.headers.get("accept-ranges", "").lower() == "bytes"
    assert response.headers.get("content-length") == str(len(MINIMAL_MP3))


# ── Streaming-chunk Range coverage ────────────────────────────────────────
#
# `/api/streams/{job_id}/chapters/{chapter_index}/chunks/{chunk_id}` serves
# live progressive chunks while a job is still converting. AVQueuePlayer
# and just_audio both issue Range probes against this URL to bring up
# the player UI quickly, so the same byte-range contract must hold here.


def _seed_stream_chunk(tmp_path: Path, payload: bytes = MINIMAL_MP3) -> tuple[str, str]:
    job_id = str(uuid4())
    book_dir = tmp_path / "Streaming Range Book"
    stream_dir = book_dir / "streams"
    stream_dir.mkdir(parents=True, exist_ok=True)
    chunk_path = stream_dir / "stream_chunk_0.mp3"
    chunk_path.write_bytes(payload)
    manifest = stream_dir / "index.json"
    manifest.write_text(
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
        "state": "running",
        "outputDir": str(book_dir),
    }
    return job_id, "0"


def test_stream_chunk_full_get_returns_200_with_accept_ranges(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    job_id, chunk_id = _seed_stream_chunk(tmp_path)

    client = TestClient(server.app)
    response = client.get(f"/api/streams/{job_id}/chapters/1/chunks/{chunk_id}")

    assert response.status_code == 200
    assert response.content == MINIMAL_MP3
    assert response.headers.get("accept-ranges", "").lower() == "bytes"
    assert response.headers.get("content-type", "").lower().startswith("audio/mpeg")
    assert response.headers.get("content-length") == str(len(MINIMAL_MP3))


def test_stream_chunk_range_request_returns_206_with_partial_body(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    job_id, chunk_id = _seed_stream_chunk(tmp_path)

    client = TestClient(server.app)
    response = client.get(
        f"/api/streams/{job_id}/chapters/1/chunks/{chunk_id}",
        headers={"Range": "bytes=16-47"},
    )

    assert response.status_code == 206
    assert response.content == MINIMAL_MP3[16:48]
    assert response.headers.get("content-range") == f"bytes 16-47/{len(MINIMAL_MP3)}"
    assert response.headers.get("content-length") == "32"


def test_stream_chunk_open_ended_range_serves_rest_of_file(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    job_id, chunk_id = _seed_stream_chunk(tmp_path)

    client = TestClient(server.app)
    response = client.get(
        f"/api/streams/{job_id}/chapters/1/chunks/{chunk_id}",
        headers={"Range": "bytes=200-"},
    )

    assert response.status_code == 206
    assert response.content == MINIMAL_MP3[200:]
    end = len(MINIMAL_MP3) - 1
    assert response.headers.get("content-range") == (f"bytes 200-{end}/{len(MINIMAL_MP3)}")


def test_stream_chunk_suffix_range_serves_last_n_bytes(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    job_id, chunk_id = _seed_stream_chunk(tmp_path)

    client = TestClient(server.app)
    response = client.get(
        f"/api/streams/{job_id}/chapters/1/chunks/{chunk_id}",
        headers={"Range": "bytes=-32"},
    )

    assert response.status_code == 206
    assert response.content == MINIMAL_MP3[-32:]


def test_stream_chunk_unsatisfiable_range_returns_416(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    job_id, chunk_id = _seed_stream_chunk(tmp_path)

    client = TestClient(server.app)
    response = client.get(
        f"/api/streams/{job_id}/chapters/1/chunks/{chunk_id}",
        headers={"Range": "bytes=9999-99999"},
    )

    assert response.status_code == 416
    assert response.headers.get("content-range") == f"bytes */{len(MINIMAL_MP3)}"
