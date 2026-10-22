"""Confinement regression scenarios, collected by test_server_conversion."""

from __future__ import annotations

from python_app.tests._server_conversion_test_support import MINIMAL_MP3 as MINIMAL_MP3
from python_app.tests._server_conversion_test_support import Path as Path
from python_app.tests._server_conversion_test_support import TestClient as TestClient
from python_app.tests._server_conversion_test_support import (
    _configure_server_paths as _configure_server_paths,
)
from python_app.tests._server_conversion_test_support import asyncio as asyncio
from python_app.tests._server_conversion_test_support import json as json
from python_app.tests._server_conversion_test_support import os as os
from python_app.tests._server_conversion_test_support import pytest as pytest
from python_app.tests._server_conversion_test_support import server as server
from python_app.tests._server_conversion_test_support import uuid4 as uuid4


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


@pytest.mark.parametrize("job_id", ["../escape", "folder/child", r"folder\\child", ".", ".."])
def test_job_stream_dir_rejects_non_component_job_ids(tmp_path, monkeypatch, job_id):
    _configure_server_paths(tmp_path, monkeypatch)

    with pytest.raises(ValueError, match="Invalid job_id"):
        server._job_stream_dir(job_id, ensure=True)


def test_cleanup_does_not_expose_filesystem_exceptions(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    expired_dir = tmp_path / "expired-job"
    expired_dir.mkdir()
    os.utime(expired_dir, (0, 0))

    monkeypatch.setattr("python_app.server.time.time", lambda: 10_000)

    def fail_removal(_: Path) -> None:
        raise OSError("/secret/path")

    monkeypatch.setattr("python_app.server.shutil.rmtree", fail_removal)

    result = asyncio.run(server.cleanup_old_files(max_age_hours=0))

    assert result["errors"] == 1
    assert "/secret/path" not in str(result)


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


@pytest.mark.parametrize("layout", ["recorded", "legacy"])
@pytest.mark.parametrize("foreign_location", ["outside-output", "prefix-sibling", "sibling-book"])
@pytest.mark.parametrize("request_kind", ["get", "head", "range"])
def test_download_output_rejects_symlink_to_foreign_file(
    tmp_path, monkeypatch, layout, foreign_location, request_kind
):
    output_root = tmp_path / "outputs"
    _configure_server_paths(output_root, monkeypatch)
    job_id = str(uuid4())
    job_dir = output_root / ("Download Book" if layout == "recorded" else job_id)
    job_dir.mkdir()
    foreign_dir = {
        "outside-output": tmp_path / "foreign",
        "prefix-sibling": tmp_path / "outputs-other",
        "sibling-book": output_root / "Other Book",
    }[foreign_location]
    foreign_dir.mkdir()
    foreign = foreign_dir / "chapter-001.mp3"
    foreign_bytes = b"owned foreign fixture must not be downloaded"
    foreign.write_bytes(foreign_bytes)
    link = job_dir / "chapter-001.mp3"
    link.symlink_to(foreign)
    monkeypatch.setattr(
        server,
        "jobs",
        {job_id: {"jobId": job_id, "state": "finished", "outputDir": str(job_dir)}}
        if layout == "recorded"
        else {},
    )

    client = TestClient(server.app)
    response = client.request(
        "HEAD" if request_kind == "head" else "GET",
        f"/api/outputs/{job_id}/chapter-001.mp3",
        headers={"Range": "bytes=0-9"} if request_kind == "range" else {},
    )

    assert response.status_code == 404
    assert "content-range" not in response.headers
    assert foreign_bytes not in response.content
    assert link.is_symlink()
    assert foreign.read_bytes() == foreign_bytes


@pytest.mark.parametrize("layout", ["recorded", "legacy"])
@pytest.mark.parametrize("member_kind", ["nested", "internal-symlink"])
@pytest.mark.parametrize("request_kind", ["get", "head", "range"])
def test_download_output_serves_confined_nested_member(
    tmp_path, monkeypatch, layout, member_kind, request_kind
):
    output_root = tmp_path / "outputs"
    _configure_server_paths(output_root, monkeypatch)
    job_id = str(uuid4())
    job_dir = output_root / ("Download Book" if layout == "recorded" else job_id)
    nested = job_dir / "nested"
    nested.mkdir(parents=True)
    target = nested / ("actual.mp3" if member_kind == "internal-symlink" else "chapter-001.mp3")
    target.write_bytes(MINIMAL_MP3)
    if member_kind == "internal-symlink":
        (nested / "chapter-001.mp3").symlink_to(target)
    monkeypatch.setattr(
        server,
        "jobs",
        {job_id: {"jobId": job_id, "state": "finished", "outputDir": str(job_dir)}}
        if layout == "recorded"
        else {},
    )

    client = TestClient(server.app)
    response = client.request(
        "HEAD" if request_kind == "head" else "GET",
        f"/api/outputs/{job_id}/chapter-001.mp3",
        headers={"Range": "bytes=0-9"} if request_kind == "range" else {},
    )

    assert response.status_code == (206 if request_kind == "range" else 200)
    expected = {"get": MINIMAL_MP3, "head": b"", "range": MINIMAL_MP3[:10]}[request_kind]
    assert response.content == expected
    expected_length = 10 if request_kind == "range" else len(MINIMAL_MP3)
    assert response.headers["content-length"] == str(expected_length)
    assert target.read_bytes() == MINIMAL_MP3


@pytest.mark.parametrize("valid_location", ["later-member", "legacy-fallback"])
@pytest.mark.parametrize("request_kind", ["get", "head", "range"])
def test_download_output_skips_foreign_member_before_valid_match(
    tmp_path, monkeypatch, valid_location, request_kind
):
    output_root = tmp_path / "outputs"
    _configure_server_paths(output_root, monkeypatch)
    job_id = str(uuid4())
    job_dir = output_root / "Download Book"
    first = job_dir / "a-first"
    first.mkdir(parents=True)
    foreign = tmp_path / "foreign.mp3"
    foreign_bytes = b"owned foreign fixture remains outside the job"
    foreign.write_bytes(foreign_bytes)
    (first / "chapter-001.mp3").symlink_to(foreign)
    valid_dir = job_dir / "z-last" if valid_location == "later-member" else output_root / job_id
    valid_dir.mkdir()
    target = valid_dir / "chapter-001.mp3"
    target.write_bytes(MINIMAL_MP3)
    monkeypatch.setattr(
        server,
        "jobs",
        {job_id: {"jobId": job_id, "state": "finished", "outputDir": str(job_dir)}},
    )

    client = TestClient(server.app)
    response = client.request(
        "HEAD" if request_kind == "head" else "GET",
        f"/api/outputs/{job_id}/chapter-001.mp3",
        headers={"Range": "bytes=0-9"} if request_kind == "range" else {},
    )

    assert response.status_code == (206 if request_kind == "range" else 200)
    expected = {"get": MINIMAL_MP3, "head": b"", "range": MINIMAL_MP3[:10]}[request_kind]
    assert response.content == expected
    assert foreign.read_bytes() == foreign_bytes
    assert target.read_bytes() == MINIMAL_MP3


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


def test_stream_chunk_rejects_path_traversal_in_manifest_file_field(tmp_path, monkeypatch):
    """Even if a stale/corrupted manifest somehow contains a `../` filename,
    the endpoint must refuse to serve files outside the stream directory.

    Guards against the CodeQL `py/path-injection` finding that flagged the
    FileResponse path: the manifest is treated as semi-trusted because it
    comes from disk, but its `file` field can in theory be tampered with.
    """
    _configure_server_paths(tmp_path, monkeypatch)
    job_id = str(uuid4())
    output_book_dir = tmp_path / "Trav Book"
    stream_dir = output_book_dir / "streams"
    stream_dir.mkdir(parents=True, exist_ok=True)

    secret = output_book_dir / "secret.bin"
    secret.write_bytes(b"SECRET")

    manifest_path = stream_dir / "index.json"
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
                                # Attempted traversal — must NOT serve `secret.bin`.
                                "file": "../secret.bin",
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
    response = client.get(f"/api/streams/{job_id}/chapters/1/chunks/0")

    assert response.status_code in {400, 404}
    assert response.content != b"SECRET"


def test_direct_convert_rejects_oversize_stream_without_partial_input(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "MAX_UPLOAD_BYTES", 5)
    monkeypatch.setattr(server, "MAX_UPLOAD_MB", 0)

    response = TestClient(server.app).post(
        "/api/convert",
        files={"file": ("too-large.epub", b"x" * 10, "application/epub+zip")},
    )

    assert response.status_code == 413
    assert list((tmp_path / ".job_inputs").iterdir()) == []
