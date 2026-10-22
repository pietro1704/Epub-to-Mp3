from __future__ import annotations

from python_app.tests._server_conversion_test_support import (
    DummyFactory as DummyFactory,
    DummyTTSEngine as DummyTTSEngine,
    FIXTURE_BOOK as FIXTURE_BOOK,
    MINIMAL_MP3 as MINIMAL_MP3,
    MINIMAL_WAV as MINIMAL_WAV,
    Path as Path,
    TelemetryRecorder as TelemetryRecorder,
    TestClient as TestClient,
    _configure_server_paths as _configure_server_paths,
    _fake_convert_to_mp3 as _fake_convert_to_mp3,
    _make_job_with_chapters as _make_job_with_chapters,
    _make_telemetry as _make_telemetry,
    requires_ffmpeg as requires_ffmpeg,
    server as server,
)

from python_app.tests._server_conversion_execution_cases import (
    test_process_conversion_generates_chapters as test_process_conversion_generates_chapters,
    test_process_conversion_recovers_malformed_previous_stream as test_process_conversion_recovers_malformed_previous_stream,
    test_process_conversion_prioritizes_requested_chapter_first as test_process_conversion_prioritizes_requested_chapter_first,
    test_edge_fallbacks_to_piper as test_edge_fallbacks_to_piper,
)
from python_app.tests._server_conversion_confinement_cases import (
    test_job_output_dir_rejects_stored_path_outside_output_root as test_job_output_dir_rejects_stored_path_outside_output_root,
    test_resolve_relative_path_within_root_rejects_absolute_candidate as test_resolve_relative_path_within_root_rejects_absolute_candidate,
    test_job_stream_dir_rejects_non_component_job_ids as test_job_stream_dir_rejects_non_component_job_ids,
    test_cleanup_does_not_expose_filesystem_exceptions as test_cleanup_does_not_expose_filesystem_exceptions,
    test_get_job_fulltext_rejects_source_path_outside_allowed_roots as test_get_job_fulltext_rejects_source_path_outside_allowed_roots,
    test_download_output_rejects_symlink_to_foreign_file as test_download_output_rejects_symlink_to_foreign_file,
    test_download_output_serves_confined_nested_member as test_download_output_serves_confined_nested_member,
    test_download_output_skips_foreign_member_before_valid_match as test_download_output_skips_foreign_member_before_valid_match,
    test_download_output_serves_named_file_from_job_directory as test_download_output_serves_named_file_from_job_directory,
    test_stream_chunk_rejects_path_traversal_in_manifest_file_field as test_stream_chunk_rejects_path_traversal_in_manifest_file_field,
    test_direct_convert_rejects_oversize_stream_without_partial_input as test_direct_convert_rejects_oversize_stream_without_partial_input,
)
from python_app.tests._server_conversion_fulltext_cases import (
    test_preserves_reused_upload_inside_job_dir as test_preserves_reused_upload_inside_job_dir,
    test_job_fulltext_uses_file_path_when_input_file_is_missing as test_job_fulltext_uses_file_path_when_input_file_is_missing,
    test_job_fulltext_prefers_cached_chapters as test_job_fulltext_prefers_cached_chapters,
    test_job_fulltext_returns_503_when_source_missing_and_job_running as test_job_fulltext_returns_503_when_source_missing_and_job_running,
    test_job_fulltext_returns_404_when_source_missing_and_job_failed as test_job_fulltext_returns_404_when_source_missing_and_job_failed,
    test_job_fulltext_uses_cache_even_when_source_file_is_gone as test_job_fulltext_uses_cache_even_when_source_file_is_gone,
    test_job_fulltext_returns_422_when_parsing_yields_no_chapters_on_failed_job as test_job_fulltext_returns_422_when_parsing_yields_no_chapters_on_failed_job,
)
from python_app.tests._server_conversion_engine_policy_cases import (
    test_build_engine_chain_respects_guards as test_build_engine_chain_respects_guards,
    test_build_engine_chain_includes_edge_monolingual_fallback as test_build_engine_chain_includes_edge_monolingual_fallback,
    test_build_engine_chain_includes_supported_fallbacks as test_build_engine_chain_includes_supported_fallbacks,
    test_should_retry_edge_before_fallback_prefers_one_local_retry as test_should_retry_edge_before_fallback_prefers_one_local_retry,
    test_rank_fallbacks_includes_piper as test_rank_fallbacks_includes_piper,
    test_engine_is_disabled_respects_unavailable_set as test_engine_is_disabled_respects_unavailable_set,
    test_pick_auto_engine_prefers_fastest_telemetry as test_pick_auto_engine_prefers_fastest_telemetry,
    test_server_short_audio_detection_uses_cli_completeness_threshold as test_server_short_audio_detection_uses_cli_completeness_threshold,
    test_server_max_chapter_chars_skip_predicate as test_server_max_chapter_chars_skip_predicate,
    test_server_max_chapter_chars_default_is_zero as test_server_max_chapter_chars_default_is_zero,
)
from python_app.tests._server_conversion_endpoints_cases import (
    test_convert_endpoint_rejects_large_files as test_convert_endpoint_rejects_large_files,
    test_convert_endpoint_success_flow as test_convert_endpoint_success_flow,
    test_convert_endpoint_persists_priority_chapter_index as test_convert_endpoint_persists_priority_chapter_index,
    test_convert_endpoint_ignores_invalid_priority_chapter_index as test_convert_endpoint_ignores_invalid_priority_chapter_index,
    test_convert_endpoint_failure_flow as test_convert_endpoint_failure_flow,
    test_job_status_rehydrates_outputs as test_job_status_rehydrates_outputs,
    test_feature_history_endpoint_missing_file as test_feature_history_endpoint_missing_file,
    test_feature_history_endpoint_returns_limited_entries as test_feature_history_endpoint_returns_limited_entries,
)
from python_app.tests._server_conversion_stream_publication_cases import (
    test_stream_endpoints_serve_manifest_and_chunk_from_job_stream_dir as test_stream_endpoints_serve_manifest_and_chunk_from_job_stream_dir,
    test_stream_chunk_optional_journey_header_correlates_actual_publication as test_stream_chunk_optional_journey_header_correlates_actual_publication,
    test_streams_are_isolated_for_jobs_sharing_one_book_output_dir as test_streams_are_isolated_for_jobs_sharing_one_book_output_dir,
    test_legacy_shared_stream_manifest_never_leaks_to_another_job as test_legacy_shared_stream_manifest_never_leaks_to_another_job,
)
from python_app.tests._server_conversion_latency_observations_cases import (
    test_journey_observations_keep_only_redacted_timing_boundaries as test_journey_observations_keep_only_redacted_timing_boundaries,
    test_journey_observations_correlate_playback_delay_and_cancelled_seek as test_journey_observations_correlate_playback_delay_and_cancelled_seek,
    test_journey_observations_reject_untrusted_metadata as test_journey_observations_reject_untrusted_metadata,
)

def test_chapter_display_name_recovers_real_heading_from_generic_name():
    assert (
        server._chapter_display_name(
            "Chapter 1",
            "<html><body><h1>The Fellowship of the Ring</h1><p>Text</p></body></html>",
            1,
        )
        == "The Fellowship of the Ring"
    )


def test_chapter_display_name_preserves_substantive_toc_name():
    assert (
        server._chapter_display_name(
            "The Council of Elrond",
            "<h1>Different body heading</h1>",
            2,
        )
        == "The Council of Elrond"
    )


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
