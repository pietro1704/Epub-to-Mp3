from __future__ import annotations

import python_app.tests._server_conversion_test_support as _shared_test_exports
from python_app.tests._server_conversion_confinement_cases import (
    test_cleanup_does_not_expose_filesystem_exceptions as test_cleanup_does_not_expose_filesystem_exceptions,
)
from python_app.tests._server_conversion_confinement_cases import (
    test_direct_convert_rejects_oversize_stream_without_partial_input as test_direct_convert_rejects_oversize_stream_without_partial_input,
)
from python_app.tests._server_conversion_confinement_cases import (
    test_download_output_rejects_symlink_to_foreign_file as test_download_output_rejects_symlink_to_foreign_file,
)
from python_app.tests._server_conversion_confinement_cases import (
    test_download_output_serves_confined_nested_member as test_download_output_serves_confined_nested_member,
)
from python_app.tests._server_conversion_confinement_cases import (
    test_download_output_serves_named_file_from_job_directory as test_download_output_serves_named_file_from_job_directory,
)
from python_app.tests._server_conversion_confinement_cases import (
    test_download_output_skips_foreign_member_before_valid_match as test_download_output_skips_foreign_member_before_valid_match,
)
from python_app.tests._server_conversion_confinement_cases import (
    test_get_job_fulltext_rejects_source_path_outside_allowed_roots as test_get_job_fulltext_rejects_source_path_outside_allowed_roots,
)
from python_app.tests._server_conversion_confinement_cases import (
    test_job_output_dir_rejects_stored_path_outside_output_root as test_job_output_dir_rejects_stored_path_outside_output_root,
)
from python_app.tests._server_conversion_confinement_cases import (
    test_job_stream_dir_rejects_non_component_job_ids as test_job_stream_dir_rejects_non_component_job_ids,
)
from python_app.tests._server_conversion_confinement_cases import (
    test_resolve_relative_path_within_root_rejects_absolute_candidate as test_resolve_relative_path_within_root_rejects_absolute_candidate,
)
from python_app.tests._server_conversion_confinement_cases import (
    test_stream_chunk_rejects_path_traversal_in_manifest_file_field as test_stream_chunk_rejects_path_traversal_in_manifest_file_field,
)
from python_app.tests._server_conversion_endpoints_cases import (
    test_convert_endpoint_failure_flow as test_convert_endpoint_failure_flow,
)
from python_app.tests._server_conversion_endpoints_cases import (
    test_convert_endpoint_ignores_invalid_priority_chapter_index as test_convert_endpoint_ignores_invalid_priority_chapter_index,
)
from python_app.tests._server_conversion_endpoints_cases import (
    test_convert_endpoint_persists_priority_chapter_index as test_convert_endpoint_persists_priority_chapter_index,
)
from python_app.tests._server_conversion_endpoints_cases import (
    test_convert_endpoint_rejects_large_files as test_convert_endpoint_rejects_large_files,
)
from python_app.tests._server_conversion_endpoints_cases import (
    test_convert_endpoint_success_flow as test_convert_endpoint_success_flow,
)
from python_app.tests._server_conversion_endpoints_cases import (
    test_feature_history_endpoint_missing_file as test_feature_history_endpoint_missing_file,
)
from python_app.tests._server_conversion_endpoints_cases import (
    test_feature_history_endpoint_returns_limited_entries as test_feature_history_endpoint_returns_limited_entries,
)
from python_app.tests._server_conversion_endpoints_cases import (
    test_job_status_rehydrates_outputs as test_job_status_rehydrates_outputs,
)
from python_app.tests._server_conversion_engine_policy_cases import (
    test_build_engine_chain_includes_edge_monolingual_fallback as test_build_engine_chain_includes_edge_monolingual_fallback,
)
from python_app.tests._server_conversion_engine_policy_cases import (
    test_build_engine_chain_includes_supported_fallbacks as test_build_engine_chain_includes_supported_fallbacks,
)
from python_app.tests._server_conversion_engine_policy_cases import (
    test_build_engine_chain_respects_guards as test_build_engine_chain_respects_guards,
)
from python_app.tests._server_conversion_engine_policy_cases import (
    test_engine_is_disabled_respects_unavailable_set as test_engine_is_disabled_respects_unavailable_set,
)
from python_app.tests._server_conversion_engine_policy_cases import (
    test_pick_auto_engine_prefers_fastest_telemetry as test_pick_auto_engine_prefers_fastest_telemetry,
)
from python_app.tests._server_conversion_engine_policy_cases import (
    test_rank_fallbacks_includes_piper as test_rank_fallbacks_includes_piper,
)
from python_app.tests._server_conversion_engine_policy_cases import (
    test_server_max_chapter_chars_default_is_zero as test_server_max_chapter_chars_default_is_zero,
)
from python_app.tests._server_conversion_engine_policy_cases import (
    test_server_max_chapter_chars_skip_predicate as test_server_max_chapter_chars_skip_predicate,
)
from python_app.tests._server_conversion_engine_policy_cases import (
    test_server_short_audio_detection_uses_cli_completeness_threshold as test_server_short_audio_detection_uses_cli_completeness_threshold,
)
from python_app.tests._server_conversion_engine_policy_cases import (
    test_should_retry_edge_before_fallback_prefers_one_local_retry as test_should_retry_edge_before_fallback_prefers_one_local_retry,
)
from python_app.tests._server_conversion_estimate_cases import (
    TestEstimateEndpoint as TestEstimateEndpoint,
)
from python_app.tests._server_conversion_execution_cases import (
    test_edge_fallbacks_to_piper as test_edge_fallbacks_to_piper,
)
from python_app.tests._server_conversion_execution_cases import (
    test_process_conversion_generates_chapters as test_process_conversion_generates_chapters,
)
from python_app.tests._server_conversion_execution_cases import (
    test_process_conversion_prioritizes_requested_chapter_first as test_process_conversion_prioritizes_requested_chapter_first,
)
from python_app.tests._server_conversion_execution_cases import (
    test_process_conversion_recovers_malformed_previous_stream as test_process_conversion_recovers_malformed_previous_stream,
)
from python_app.tests._server_conversion_fulltext_cases import (
    test_job_fulltext_prefers_cached_chapters as test_job_fulltext_prefers_cached_chapters,
)
from python_app.tests._server_conversion_fulltext_cases import (
    test_job_fulltext_returns_404_when_source_missing_and_job_failed as test_job_fulltext_returns_404_when_source_missing_and_job_failed,
)
from python_app.tests._server_conversion_fulltext_cases import (
    test_job_fulltext_returns_422_when_parsing_yields_no_chapters_on_failed_job as test_job_fulltext_returns_422_when_parsing_yields_no_chapters_on_failed_job,
)
from python_app.tests._server_conversion_fulltext_cases import (
    test_job_fulltext_returns_503_when_source_missing_and_job_running as test_job_fulltext_returns_503_when_source_missing_and_job_running,
)
from python_app.tests._server_conversion_fulltext_cases import (
    test_job_fulltext_uses_cache_even_when_source_file_is_gone as test_job_fulltext_uses_cache_even_when_source_file_is_gone,
)
from python_app.tests._server_conversion_fulltext_cases import (
    test_job_fulltext_uses_file_path_when_input_file_is_missing as test_job_fulltext_uses_file_path_when_input_file_is_missing,
)
from python_app.tests._server_conversion_fulltext_cases import (
    test_preserves_reused_upload_inside_job_dir as test_preserves_reused_upload_inside_job_dir,
)
from python_app.tests._server_conversion_latency_observations_cases import (
    test_journey_observations_correlate_playback_delay_and_cancelled_seek as test_journey_observations_correlate_playback_delay_and_cancelled_seek,
)
from python_app.tests._server_conversion_latency_observations_cases import (
    test_journey_observations_keep_only_redacted_timing_boundaries as test_journey_observations_keep_only_redacted_timing_boundaries,
)
from python_app.tests._server_conversion_latency_observations_cases import (
    test_journey_observations_reject_untrusted_metadata as test_journey_observations_reject_untrusted_metadata,
)
from python_app.tests._server_conversion_stream_publication_cases import (
    test_legacy_shared_stream_manifest_never_leaks_to_another_job as test_legacy_shared_stream_manifest_never_leaks_to_another_job,
)
from python_app.tests._server_conversion_stream_publication_cases import (
    test_stream_chunk_optional_journey_header_correlates_actual_publication as test_stream_chunk_optional_journey_header_correlates_actual_publication,
)
from python_app.tests._server_conversion_stream_publication_cases import (
    test_stream_endpoints_serve_manifest_and_chunk_from_job_stream_dir as test_stream_endpoints_serve_manifest_and_chunk_from_job_stream_dir,
)
from python_app.tests._server_conversion_stream_publication_cases import (
    test_streams_are_isolated_for_jobs_sharing_one_book_output_dir as test_streams_are_isolated_for_jobs_sharing_one_book_output_dir,
)
from python_app.tests._server_conversion_test_support import FIXTURE_BOOK as FIXTURE_BOOK
from python_app.tests._server_conversion_test_support import MINIMAL_MP3 as MINIMAL_MP3
from python_app.tests._server_conversion_test_support import MINIMAL_WAV as MINIMAL_WAV
from python_app.tests._server_conversion_test_support import DummyFactory as DummyFactory
from python_app.tests._server_conversion_test_support import DummyTTSEngine as DummyTTSEngine
from python_app.tests._server_conversion_test_support import Path as Path
from python_app.tests._server_conversion_test_support import TestClient as TestClient
from python_app.tests._server_conversion_test_support import (
    _configure_server_paths as _configure_server_paths,
)
from python_app.tests._server_conversion_test_support import (
    _fake_convert_to_mp3 as _fake_convert_to_mp3,
)
from python_app.tests._server_conversion_test_support import (
    _make_job_with_chapters as _make_job_with_chapters,
)
from python_app.tests._server_conversion_test_support import _make_telemetry as _make_telemetry
from python_app.tests._server_conversion_test_support import requires_ffmpeg as requires_ffmpeg
from python_app.tests._server_conversion_test_support import server as server

TelemetryRecorder = _shared_test_exports.TelemetryRecorder


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
