"""Execution regression scenarios, collected by test_server_conversion."""

from __future__ import annotations

from python_app.tests._server_conversion_test_support import (
    DummyFactory as DummyFactory,
    DummyTTSEngine as DummyTTSEngine,
    FIXTURE_BOOK as FIXTURE_BOOK,
    MINIMAL_MP3 as MINIMAL_MP3,
    Path as Path,
    SimpleNamespace as SimpleNamespace,
    TestClient as TestClient,
    _configure_server_paths as _configure_server_paths,
    _fake_convert_to_mp3 as _fake_convert_to_mp3,
    _make_telemetry as _make_telemetry,
    asyncio as asyncio,
    patch as patch,
    pytest as pytest,
    replace as replace,
    server as server,
    uuid4 as uuid4,
)

@pytest.mark.parametrize("retry_first", [False, True])
def test_process_conversion_generates_chapters(tmp_path, monkeypatch, retry_first):
    """Test server conversion with mocked TTS engine."""
    job_id = str(uuid4())

    _configure_server_paths(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "_CHAPTER_RETRY_BACKOFF_SECONDS", 0)

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
    recorded_callbacks = []
    expected_stream_bytes = {}
    failed_attempt_ids = set()
    publication_responses = []

    async def mock_synthesize(self, text, output_path, progress_callback=None, chunk_callback=None):
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
        if chunk_callback is not None:
            recorded_callbacks.append((chunk_callback, output_path))
            for index in (1, 0):
                segment = output_path.with_name(f"fixture-segment-{index}.mp3")
                segment.write_bytes(mp3_header * (10 + index))
                expected_stream_bytes[index] = segment.read_bytes()
                chunk_callback(index, segment, "Private fixture text")
                segment.unlink()
            chapter_index = int(output_path.name.split(" - ", 1)[0])
            client = TestClient(server.app)
            manifest_url = f"/api/streams/{job_id}/chapters/{chapter_index}"
            first_chunk = next(chunk for chunk in client.get(manifest_url).json()["chunks"] if chunk["index"] == 0)
            first_bytes = expected_stream_bytes[0]
            replacement = output_path.with_name("republished-segment.mp3")
            replacement.write_bytes(mp3_header * 12)
            expected_stream_bytes[0] = replacement.read_bytes()
            chunk_callback(0, replacement, "Republished fixture segment")
            replacement.unlink()
            public_manifest = client.get(manifest_url).json()
            assert "retiredChunks" not in public_manifest
            new_chunk = next(chunk for chunk in public_manifest["chunks"] if chunk["index"] == 0)
            private_chapter = server._load_stream_index(job_id)["chapters"][str(chapter_index)]
            assert all(set(chunk) == {"id", "file"} for chunk in private_chapter["retiredChunks"])
            assert sum(chunk["id"] == first_chunk["id"] for chunk in private_chapter["retiredChunks"]) == 1
            old_response = client.get(first_chunk["url"])
            new_response = client.get(new_chunk["url"])
            publication_responses.append((first_chunk, new_chunk, first_bytes, expected_stream_bytes[0],
                                          old_response.status_code, old_response.content,
                                          new_response.status_code, new_response.content))
            previous_manifest = server._stream_index_path(job_id, ensure=False).read_bytes()
            stream_root = server._job_stream_dir(job_id, ensure=False)
            previous_files = {path.name: path.read_bytes() for path in stream_root.glob("stream_*")}
            replacement = output_path.with_name("publication-failure.mp3")
            replacement.write_bytes(b"replacement must stay unpublished")
            with patch.object(server, "_save_stream_index", side_effect=OSError("manifest failure")):
                chunk_callback(0, replacement, "Private replacement")
            replacement.unlink()
            assert server._stream_index_path(job_id, ensure=False).read_bytes() == previous_manifest
            assert {path.name: path.read_bytes() for path in stream_root.glob("stream_*")} == previous_files
            if retry_first and len(recorded_callbacks) == 1:
                for chapter in server._load_stream_index(job_id)["chapters"].values():
                    failed_attempt_ids.update(chunk["observation"]["attemptId"] for chunk in chapter["chunks"])
                raise RuntimeError("Temporary stream transport interruption")
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

    stream_index = server._load_stream_index(job_id)
    assert stream_index["chapters"]
    observed_attempts = []
    for chapter in stream_index["chapters"].values():
        assert [chunk["index"] for chunk in chapter["chunks"]] == [0, 1]
        attempts = set()
        for chunk in chapter["chunks"]:
            assert (server._job_stream_dir(job_id, ensure=False) / chunk["file"]).read_bytes() == expected_stream_bytes[chunk["index"]]
            observation = chunk["observation"]
            assert set(observation) == {"version", "attemptId", "segmentReadyElapsedNanoseconds", "artifactPublishedElapsedNanoseconds"}
            assert observation["artifactPublishedElapsedNanoseconds"] >= observation["segmentReadyElapsedNanoseconds"] >= 0
            attempts.add(observation["attemptId"])
        assert len(attempts) == 1
        observed_attempts.extend(attempts)
    assert len(set(observed_attempts)) == len(observed_attempts)
    assert publication_responses
    for old, new, old_bytes, new_bytes, old_status, old_content, new_status, new_content in publication_responses:
        assert old["observation"]
        assert new["observation"]
        assert old_status == 200
        assert old_content == old_bytes, "An old manifest URL must keep serving its original publication bytes"
        assert new_status == 200
        assert new_content == new_bytes
        assert old["id"] != new["id"]
        assert old["index"] == new["index"] == 0
        # Earlier URLs must also survive subsequent engine attempts.
        response = TestClient(server.app).get(old["url"])
        assert response.status_code == 200
        assert response.content == old_bytes
    if retry_first:
        assert failed_attempt_ids
        assert failed_attempt_ids.isdisjoint(observed_attempts)
    before_late_callback = server._load_stream_index(job_id)
    for callback, source in recorded_callbacks:
        callback(99, source, "Late obsolete callback")
    assert server._load_stream_index(job_id) == before_late_callback

    server.jobs.pop(job_id, None)


@pytest.mark.parametrize("missing_field", ["id", "file", "non_dict"])
def test_process_conversion_recovers_malformed_previous_stream(tmp_path, monkeypatch, missing_field):
    _configure_server_paths(tmp_path, monkeypatch)
    _make_telemetry(tmp_path, monkeypatch)
    job_id = str(uuid4())
    upload_path = tmp_path / "book.epub"
    upload_path.write_bytes(FIXTURE_BOOK.read_bytes())
    server.jobs[job_id] = {
        "jobId": job_id, "state": "queued", "events": [],
        "file_path": str(upload_path), "engine": "edge", "voice": None,
        "chapters": None, "footnote_mode": "inline", "language": "pt-BR", "outputs": [],
        "resumeRequested": True,
    }
    malformed = {"id": "legacy", "file": "old.mp3"}
    if missing_field == "non_dict":
        malformed = None
    else:
        malformed.pop(missing_field)
    retained = {"id": 0, "file": "retained.mp3"}
    (server._job_stream_dir(job_id, ensure=True) / retained["file"]).write_bytes(b"prior audio")
    server._save_stream_index(job_id, {
        "chapters": {str(index): {"chunks": [malformed, retained],
                                  "retiredChunks": [malformed, retained]}
                     for index in range(1, 5)}
    })
    audio_bytes = (bytes([0xFF, 0xFB, 0x90, 0x00]) + bytes(417)) * 10
    emitted_chapters = []

    async def synthesize(self, text, output_path, progress_callback=None, chunk_callback=None):
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(audio_bytes)
        if chunk_callback is not None:
            chunk_callback(0, output_path, "Fresh segment")
            emitted_chapters.append(int(output_path.name.split(" - ", 1)[0]))
        return output_path

    monkeypatch.setattr(server.AudioProcessor, "convert_to_mp3", staticmethod(_fake_convert_to_mp3))
    try:
        with patch("src.tts.edge_engine.EdgeTTSEngine.synthesize_async", synthesize):
            asyncio.run(server.process_conversion(job_id))
        assert server.jobs[job_id]["state"] == "finished"
        assert emitted_chapters
        with TestClient(server.app) as client:
            for index in emitted_chapters:
                response = client.get(f"/api/streams/{job_id}/chapters/{index}")
                assert response.status_code == 200
                chunks = response.json()["chunks"]
                assert len(chunks) == 1
                assert "observation" in chunks[0], "Fresh publication must replace malformed history"
                audio = client.get(chunks[0]["url"])
                assert audio.status_code == 200
                assert audio.content == audio_bytes
                previous_audio = client.get(f"/api/streams/{job_id}/chapters/{index}/chunks/0")
                assert previous_audio.status_code == 200
                assert previous_audio.content == b"prior audio"
                history = server._load_stream_index(job_id)["chapters"][str(index)]["retiredChunks"]
                assert history == [retained]
    finally:
        server.jobs.pop(job_id, None)


def test_edge_fallbacks_to_piper(tmp_path, monkeypatch):
    job_id = str(uuid4())
    _configure_server_paths(tmp_path, monkeypatch)
    monkeypatch.setenv("ENGINE_CHAIN_FALLBACK", "1")
    monkeypatch.delenv("FALLBACK_ENGINE_OVERRIDE", raising=False)
    monkeypatch.delenv("DISABLE_PIPER_FALLBACK", raising=False)
    # This test supplies a dummy Piper engine, so do not depend on the
    # process-level native Piper capability probe or on test collection order.
    monkeypatch.setattr(server, "_has_piper_support", lambda: True)

    upload_path = tmp_path / f"{job_id}_book.epub"
    upload_path.write_bytes(FIXTURE_BOOK.read_bytes())

    server.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "events": [],
        "file_path": str(upload_path),
        "engine": "edge",
        "engineChainFallback": True,
        "voice": None,
        "chapters": None,
        "footnote_mode": "inline",
        "language": "pt-BR",
        "outputs": [],
    }

    _make_telemetry(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "_has_piper_support", lambda: True)
    monkeypatch.setattr(
        server,
        "_build_engine_chain",
        lambda config: [config, replace(config, engine="piper", voice=None, model_path=None)],
    )

    creators = {
        "edge": lambda: DummyTTSEngine("edge", fail_times=1000),
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


def test_process_conversion_prioritizes_requested_chapter_first(tmp_path, monkeypatch):
    job_id = str(uuid4())

    _configure_server_paths(tmp_path, monkeypatch)
    _make_telemetry(tmp_path, monkeypatch)

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
        "priorityChapterIndex": 2,
    }

    class StubChapter:
        def __init__(self, name: str, text: str):
            self.name = name
            self.text = text
            self.speech_text = text
            self.source_path = f"{name}.xhtml"
            self.level = 1
            self.raw_html = None
            self.formatting_segments = None
            self.footnotes = None

    class StubReader:
        def __init__(self, *args, **kwargs):
            self.title = "Priority Book"
            self.author = "Tester"
            self.book = SimpleNamespace(chapters=[])

        def extract_cover_image(self):
            return None

        def get_chapter_structure(self, preserve_all=False):
            return []

        def get_chapters(self):
            return [
                StubChapter("Chapter 1", "Text 1" * 400),
                StubChapter("Chapter 2", "Text 2" * 400),
                StubChapter("Chapter 3", "Text 3" * 400),
                StubChapter("Chapter 4", "Text 4" * 400),
            ]

    conversion_order: list[str] = []

    async def mock_synthesize(self, text, output_path):
        conversion_order.append(Path(output_path).name)
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        payload = f"ID3-{Path(output_path).stem}-{text[:32]}".encode("utf-8") + MINIMAL_MP3
        output_path.write_bytes(payload)
        return output_path

    monkeypatch.setattr(server, "EbookReader", StubReader)
    monkeypatch.setattr(server.AudioProcessor, "convert_to_mp3", staticmethod(_fake_convert_to_mp3))
    monkeypatch.setattr("src.tts.edge_engine.EdgeTTSEngine.synthesize_async", mock_synthesize)

    asyncio.run(server.process_conversion(job_id))

    assert server.jobs[job_id]["state"] == "finished", (
        server.jobs[job_id].get("error"),
        server.jobs[job_id].get("events", [])[-10:],
    )
    assert conversion_order, "Expected at least one synthesized chapter."
    assert conversion_order[
        0
    ].startswith(
        "003 - "
    ), "Priority chapter index 2 (EPUB zero-based) must synthesize chapter 3 first in the remote path."

    server.jobs.pop(job_id, None)
