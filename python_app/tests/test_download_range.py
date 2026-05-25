"""Byte-range support for /api/outputs/{job_id}/{filename}.

The mobile clients (SwiftUI iOS + Flutter offline cache) rely on HTTP
range requests so they can resume interrupted downloads of large
chapter MP3s and so AVQueuePlayer / just_audio can seek within a
chapter without re-downloading from byte 0.

FastAPI/Starlette's `FileResponse` advertises and honours `Range:`
headers automatically, but a regression to e.g. `StreamingResponse`
(which does NOT) would silently break mobile seek/resume. These
tests pin the contract so any such drift fails CI immediately.
"""

from __future__ import annotations

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
