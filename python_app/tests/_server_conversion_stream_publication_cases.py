"""Stream Publication regression scenarios, collected by test_server_conversion."""

from __future__ import annotations

from python_app.tests._server_conversion_test_support import (
    MINIMAL_MP3 as MINIMAL_MP3,
    StreamHTTPObservationStore as StreamHTTPObservationStore,
    TestClient as TestClient,
    _configure_server_paths as _configure_server_paths,
    json as json,
    server as server,
    uuid4 as uuid4,
)

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


def test_stream_chunk_optional_journey_header_correlates_actual_publication(tmp_path, monkeypatch):
    _configure_server_paths(tmp_path, monkeypatch)
    store = StreamHTTPObservationStore()
    monkeypatch.setattr(server, "stream_http_observations", store, raising=False)
    job_id = str(uuid4())
    monkeypatch.setattr(server, "jobs", {job_id: {"jobId": job_id, "outputDir": str(tmp_path / "Book")}})
    stream_dir = server._job_stream_dir(job_id, ensure=True)
    old_id, new_id = str(uuid4()), str(uuid4())
    (stream_dir / "old.mp3").write_bytes(b"old audio")
    (stream_dir / "new.mp3").write_bytes(b"new audio")
    server._save_stream_index(job_id, {"chapters": {"1": {
        "chunks": [{"id": new_id, "index": 0, "file": "new.mp3"}],
        "retiredChunks": [{"id": old_id, "file": "old.mp3"}],
    }}})
    with TestClient(server.app) as client:
        old_url = f"/api/streams/{job_id}/chapters/1/chunks/{old_id}"
        new_url = f"/api/streams/{job_id}/chapters/1/chunks/{new_id}"
        ordinary = client.get(new_url)
        assert ordinary.content == b"new audio"
        assert "x-stream-request-id" not in ordinary.headers
        assert "cache-control" not in ordinary.headers
        assert store.export() == []
        for value in ("not-a-uuid", "", str(uuid4()).replace("-", "")):
            invalid = client.get(new_url, headers={"X-Playback-Journey-ID": value})
            assert invalid.status_code == 422
        assert store.export() == []
        journeys = [str(uuid4()), str(uuid4())]
        responses = [client.get(url, headers={"X-Playback-Journey-ID": journey})
                     for url, journey in zip((old_url, new_url), journeys)]
        assert [response.content for response in responses] == [b"old audio", b"new audio"]
        records = store.export()
        assert len(records) == 2
        assert len({record["requestId"] for record in records}) == 2
        for record, response, journey, publication in zip(records, responses, journeys, (old_id, new_id)):
            assert response.headers["cache-control"] == "no-store"
            assert response.headers["x-playback-journey-id"] == record["journeyId"] == journey
            assert response.headers["x-stream-publication-id"] == record["publicationId"] == publication
            assert response.headers["x-stream-request-id"] == record["requestId"]
            assert record["outcome"] == "body_sent"
            assert record["responseBytes"] == len(response.content)
            assert set(record) == {"version", "requestId", "journeyId", "publicationId",
                                   "requestReceivedElapsedNanoseconds", "outcome", "responseStatus",
                                   "responseBytes", "responseCompletedElapsedNanoseconds"}
        assert "journeyObservations" not in server.jobs[job_id]


def test_streams_are_isolated_for_jobs_sharing_one_book_output_dir(tmp_path, monkeypatch):
    """A second conversion of the same title must not expose the first job's chunks."""
    _configure_server_paths(tmp_path, monkeypatch)
    first_job_id = str(uuid4())
    second_job_id = str(uuid4())
    output_book_dir = tmp_path / "Shared Streaming Book"

    for job_id in (first_job_id, second_job_id):
        server.jobs[job_id] = {
            "jobId": job_id,
            "state": "finished",
            "outputDir": str(output_book_dir),
        }

    first_stream_dir = server._job_stream_dir(first_job_id, ensure=True)
    second_stream_dir = server._job_stream_dir(second_job_id, ensure=True)
    assert first_stream_dir != second_stream_dir

    first_chunk = first_stream_dir / "first.mp3"
    second_chunk = second_stream_dir / "second.mp3"
    first_chunk.write_bytes(b"FIRST" + MINIMAL_MP3)
    second_chunk.write_bytes(b"SECOND" + MINIMAL_MP3)

    for job_id, chunk in ((first_job_id, first_chunk), (second_job_id, second_chunk)):
        server._save_stream_index(
            job_id,
            {
                "jobId": job_id,
                "chapters": {
                    "1": {
                        "chapterIndex": 1,
                        "chunks": [
                            {
                                "id": "0",
                                "index": 0,
                                "file": chunk.name,
                                "url": f"/api/streams/{job_id}/chapters/1/chunks/0",
                            }
                        ],
                    }
                },
            },
        )

    client = TestClient(server.app)
    for job_id, expected in ((first_job_id, b"FIRST"), (second_job_id, b"SECOND")):
        manifest = client.get(f"/api/streams/{job_id}/chapters/1")
        assert manifest.status_code == 200
        assert manifest.json()["chunks"][0]["url"] == f"/api/streams/{job_id}/chapters/1/chunks/0"
        chunk = client.get(f"/api/streams/{job_id}/chapters/1/chunks/0")
        assert chunk.status_code == 200
        assert chunk.content.startswith(expected)


def test_legacy_shared_stream_manifest_never_leaks_to_another_job(tmp_path, monkeypatch):
    """Old title-level manifests remain readable only by their owning job."""
    _configure_server_paths(tmp_path, monkeypatch)
    owner_job_id = str(uuid4())
    other_job_id = str(uuid4())
    output_book_dir = tmp_path / "Legacy Shared Streaming Book"
    legacy_stream_dir = output_book_dir / "streams"
    legacy_stream_dir.mkdir(parents=True, exist_ok=True)

    for job_id in (owner_job_id, other_job_id):
        server.jobs[job_id] = {
            "jobId": job_id,
            "state": "finished",
            "outputDir": str(output_book_dir),
        }

    chunk_path = legacy_stream_dir / "owner.mp3"
    chunk_path.write_bytes(b"OWNER" + MINIMAL_MP3)
    (legacy_stream_dir / "index.json").write_text(
        json.dumps(
            {
                "jobId": owner_job_id,
                "chapters": {
                    "1": {
                        "chapterIndex": 1,
                        "chunks": [{"id": "0", "index": 0, "file": chunk_path.name}],
                    }
                },
            }
        ),
        encoding="utf-8",
    )

    client = TestClient(server.app)
    owner_manifest = client.get(f"/api/streams/{owner_job_id}/chapters/1")
    assert owner_manifest.status_code == 200
    assert owner_manifest.json()["chunks"][0]["file"] == chunk_path.name

    other_manifest = client.get(f"/api/streams/{other_job_id}/chapters/1")
    assert other_manifest.status_code == 200
    assert other_manifest.json()["chunks"] == []
    assert client.get(f"/api/streams/{other_job_id}/chapters/1/chunks/0").status_code == 404
