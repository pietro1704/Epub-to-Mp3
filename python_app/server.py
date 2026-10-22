#!/usr/bin/env python3
"""FastAPI server for converting EPUBs into spoken MP3 chapters."""

from __future__ import annotations

# **PERFORMANCE**: Apply system optimizations BEFORE heavy imports
import os
import sys

# **CPU FIRST**: Force CPU mode in environments without GPU (HF Spaces zero-GPU)
from src.server_bootstrap_environment import _initialize_server_environment

_initialize_server_environment(sys.modules[__name__])

import asyncio
from src.server_runtime_binding import bind_server_function as _bind_server_function
import contextlib
import json as json
import logging
import random as random
import re as re
import shutil as shutil
import sys
import threading as threading
import time as time
import uuid as uuid
import zipfile as zipfile
from datetime import datetime as datetime, timezone as timezone
from pathlib import Path as Path
from typing import Dict as Dict, List as List, Optional as Optional

from fastapi import BackgroundTasks as BackgroundTasks, FastAPI, File as File, Form as Form, HTTPException as HTTPException, Request as Request, UploadFile as UploadFile
from fastapi.middleware.cors import CORSMiddleware as CORSMiddleware
from fastapi.responses import FileResponse as FileResponse, PlainTextResponse as PlainTextResponse, StreamingResponse as StreamingResponse
from main import ConverterApplication as ConverterApplication
from pydantic import BaseModel as BaseModel
from src._health_watchdog_mixin import _await_task_with_deadline as _await_task_with_deadline, _safe_cancel_task as _safe_cancel_task
from src.audio_postprocess import add_silence_padding as add_silence_padding
from src.auto_tuner import AutoTuner
from src.benchmark_profile import recommend_parallel_slots as recommend_parallel_slots
from src.cache_manager import CacheManager as CacheManager
from src.chapter_utils import deduplicate_chapters_by_content as deduplicate_chapters_by_content
from src.config import CACHE_DIR as CACHE_DIR, ConversionConfig as ConversionConfig
from src.ebook_reader import EbookReader as EbookReader, TextProcessor as TextProcessor
from src.engine_pool import JobEnginePool as JobEnginePool, ResourceSnapshot as ResourceSnapshot
from src.error_classifier import classify_error as classify_error
from src.hardware_detector import HardwareDetector as HardwareDetector
from src.job_manager import JobManager as JobManager
from src.language import LanguageProfile as LanguageProfile
from src.paths import JOB_INPUTS_DIR as JOB_INPUTS_DIR, JOBS_DIR as JOBS_DIR, OUTPUT_DIR as OUTPUT_DIR, PERSISTENT_ROOT as PERSISTENT_ROOT, SOURCE_BACKUPS_DIR as SOURCE_BACKUPS_DIR, UPLOADS_DIR as UPLOADS_DIR
from src.reader_sanitizer import chapter_html_fallback as chapter_html_fallback, sanitize_reader_css as sanitize_reader_css, sanitize_reader_html as sanitize_reader_html
from src.stream_attempt_observation import observe_synthesis as observe_synthesis
from src.stream_http_observation import ObservedFileResponse as ObservedFileResponse, stream_http_observations as stream_http_observations, validate_journey_id as validate_journey_id
from src.telemetry import TelemetryRecorder as TelemetryRecorder
from src.text_formatting import TextFormattingProcessor as TextFormattingProcessor
from src.tts.edge_engine import reset_adaptive_settings as reset_adaptive_settings
from src.tts.factory import TTSFactory as TTSFactory
from src.tts.piper_guard import is_piper_supported_environment as is_piper_supported_environment
from src.utils import AudioProcessor as AudioProcessor, FileManager as FileManager, TextValidator as TextValidator, TimeFormatter as TimeFormatter


from src import server_output_policy as _server_server_output_policy

_chapter_display_name = _bind_server_function(_server_server_output_policy._chapter_display_name, sys.modules[__name__])


def _detect_test_environment() -> bool:
    if os.environ.get("PYTEST_CURRENT_TEST"):
        return True
    try:
        argv = sys.argv
    except Exception:
        argv = []
    for arg in argv[:1]:
        if isinstance(arg, str) and arg and "pytest" in arg.lower():
            return True
    return False


_IS_TEST_ENV = _detect_test_environment()

logger = logging.getLogger(__name__)


@contextlib.asynccontextmanager
async def _lifespan(app: FastAPI):
    """Manage FastAPI lifespan without deprecated on_event hooks."""
    global \
        _cleanup_task, \
        _job_queue, \
        _job_workers, \
        _job_watchdog_task, \
        _app_loop, \
        _skip_resume_on_startup
    _app_loop = asyncio.get_running_loop()
    os.environ.setdefault("SERVER_MODE", "1")

    if _IS_TEST_ENV or _detect_test_environment():
        logger.info("Test environment detected: using lightweight FastAPI lifespan")
        try:
            yield
        finally:
            return

    _job_queue = asyncio.Queue()
    _job_workers = [asyncio.create_task(_job_worker(idx + 1)) for idx in range(_JOB_WORKERS)]
    _cleanup_task = asyncio.create_task(_periodic_job_cleanup())
    restart_marker = _load_restart_marker()
    if restart_marker:
        keep_cache = bool(restart_marker.get("keep_cache"))
        keep_finished = bool(restart_marker.get("keep_finished"))
        _skip_resume_on_startup = True
        _purge_all_jobs(
            "restart cleanup",
            keep_finished=keep_finished,
            purge_cache=not keep_cache,
        )
        _clear_restart_staging_dirs()
        if not keep_finished:
            _clear_all_outputs(preserve_cache=keep_cache)
        if not keep_cache:
            _clear_all_caches()
        _clear_restart_marker()
    else:
        asyncio.create_task(_resume_pending_jobs())

    # Initialize auto-tuner (detects HW and network, sets performance flags automatically)
    global _auto_tuner
    if os.getenv("ENABLE_AUTO_TUNING", "1").lower() in ("1", "true", "yes"):
        _auto_tuner = AutoTuner(verbose=True)
        try:
            # Do not measure network at server startup (may block on timeout)
            await _auto_tuner.auto_configure(force=False, measure_network=False)
        except Exception as exc:
            logger.warning(f"Auto-tuning failed (using defaults): {exc}")

    if not _job_watchdog_task:
        _job_watchdog_task = asyncio.create_task(_job_watchdog())

    # On HF Spaces, ping the health endpoint every 10 minutes to prevent the
    # Space from hibernating and losing the in-memory job index.  The /data
    # directory is persistent, so completed outputs survive a restart, but a
    # sleeping Space means the user's browser gets no response when polling.
    if os.getenv("SPACE_ID"):
        _hf_keepalive_task = asyncio.create_task(_hf_keepalive())
        logger.info("✅ HF Space keep-alive task started (10 min interval)")

    try:
        from health_monitor import get_system_monitor_adapter

        global system_monitor
        system_monitor = get_system_monitor_adapter()
        system_monitor.start()
        logger.info("✅ Health Monitor started")
    except Exception as e:
        logger.warning(f"⚠️ Failed to start Health Monitor: {e}")

    if os.environ.get("DISABLE_AUTO_RECOVERY", "").lower() in {"1", "true", "yes", "on"}:
        logger.info("Auto-Recovery skipped (DISABLE_AUTO_RECOVERY)")
    else:
        try:
            from auto_recovery import start_auto_recovery

            recovery = start_auto_recovery()
            recovery.set_activity_provider(_has_active_jobs)
            logger.info("✅ Auto-Recovery System started")
        except Exception as e:
            logger.warning(f"⚠️ Failed to start Auto-Recovery: {e}")

    logger.info("Started periodic job cleanup task")
    try:
        yield
    finally:
        if _cleanup_task:
            _cleanup_task.cancel()
            try:
                await _cleanup_task
            except asyncio.CancelledError:
                pass
        logger.info("Stopped periodic job cleanup task")
        if _job_watchdog_task:
            _job_watchdog_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await _job_watchdog_task
            _job_watchdog_task = None
        for worker in list(_job_workers):
            worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker
        _job_workers.clear()
        _job_queue = None
        system_monitor.stop()


from src import server_form_values as _server_server_form_values
from src.server_bootstrap_http_application import _initialize_server_http_application

_initialize_server_http_application(sys.modules[__name__])


from src.server_bootstrap_form_queue_policy import _initialize_server_form_queue_policy

_initialize_server_form_queue_policy(sys.modules[__name__])


from src import server_cache_markers as _server_server_cache_markers

get_cache_manager = _bind_server_function(_server_server_cache_markers.get_cache_manager, sys.modules[__name__])


cover_cache_dir = output_dir / ".cover_cache"
cover_cache_dir.mkdir(exist_ok=True, parents=True)
cover_index_path = cover_cache_dir / "index.json"


# Helpers to resolve per-book/per-engine paths (supports legacy job-id layout)
from src import server_job_paths as _server_server_job_paths

from src.server_bootstrap_job_paths import _initialize_server_job_paths

_initialize_server_job_paths(sys.modules[__name__])


from src import server_stream_index as _server_server_stream_index

from src.server_bootstrap_stream_cache_policy import _initialize_server_stream_cache_policy

_initialize_server_stream_cache_policy(sys.modules[__name__])


from src import server_pending_uploads as _server_server_pending_uploads

from src.server_bootstrap_upload_policy import _initialize_server_upload_policy

_initialize_server_upload_policy(sys.modules[__name__])


from src import server_resume_summary as _server_server_resume_summary

from src.server_bootstrap_resume_policy import _initialize_server_resume_policy

_initialize_server_resume_policy(sys.modules[__name__])


from src import server_job_events as _server_server_job_events

from src.server_bootstrap_event_policy import _initialize_server_event_policy

_initialize_server_event_policy(sys.modules[__name__])


from src import server_job_recovery as _server_server_job_recovery

from src.server_bootstrap_recovery import _initialize_server_recovery

_initialize_server_recovery(sys.modules[__name__])


from src import server_job_queue as _server_server_job_queue

from src.server_bootstrap_job_index import _initialize_server_job_index

_initialize_server_job_index(sys.modules[__name__])


from src._server_engine_helpers import _apply_perf_defaults as _apply_perf_defaults, _auto_tune_engine_pool as _auto_tune_engine_pool, _build_engine_chain as _build_engine_chain, _build_multi_engine_slot_map as _build_multi_engine_slot_map, _infer_perf_profile as _infer_perf_profile, _next_auto_engine as _next_auto_engine, _pick_auto_engine as _pick_auto_engine, _prepare_auto_engine_pool as _prepare_auto_engine_pool, _resolve_auto_preferred_engine as _resolve_auto_preferred_engine, degrade_edge_chunk_chars as degrade_edge_chunk_chars

# Performance profile (auto = HF-safe on Spaces, local otherwise)
from src.server_bootstrap_hardware_policy import _initialize_server_hardware_policy

_initialize_server_hardware_policy(sys.modules[__name__])


# Fallback mock for system_monitor when health_monitor is not available
class _FallbackSystemMonitor:
    """Fallback system monitor for tests or when health_monitor fails to load."""

    def latest(self):
        """Return empty stats."""
        return {}

    def start(self):
        """No-op start."""
        pass

    def stop(self):
        """No-op stop."""
        pass


from src.server_bootstrap_monitor_state import _initialize_server_monitor_state

_initialize_server_monitor_state(sys.modules[__name__])


from src import server_retention as _server_server_retention

from src.server_bootstrap_retention import _initialize_server_retention

_initialize_server_retention(sys.modules[__name__])


from src import server_runtime_health as _server_server_runtime_health

from src.server_bootstrap_runtime_health import _initialize_server_runtime_health

_initialize_server_runtime_health(sys.modules[__name__])


# Engine helpers imported from src/_server_engine_helpers.py (at top of file)


from src.server_models import JobStatus as JobStatus


from src.server_models import JourneyObservationInput as JourneyObservationInput


from src.server_bootstrap_journey_policy import _initialize_server_journey_policy

_initialize_server_journey_policy(sys.modules[__name__])


from src.server_models import RestartOptions as RestartOptions


from src import server_convert_route as _server_server_convert_route

convert_ebook = app.post("/api/convert")(_bind_server_function(_server_server_convert_route.convert_ebook, sys.modules[__name__]))


from src import server_job_routes as _server_server_job_routes

from src.server_bootstrap_job_routes import _initialize_server_job_routes

_initialize_server_job_routes(sys.modules[__name__])


# GET + HEAD: mobile clients (iOS background URLSession, Flutter
# offline cache) issue HEAD to learn `Content-Length` + `Accept-Ranges`
# before scheduling a resumable, ranged background download. Starlette's
# FileResponse already short-circuits the body on HEAD — we only need
# the route to accept the verb.
from src import server_download_routes as _server_server_download_routes

from src.server_bootstrap_download_routes import _initialize_server_download_routes

_initialize_server_download_routes(sys.modules[__name__])


from src import server_fulltext_route as _server_server_fulltext_route

_build_fulltext_chapters_from_cache = _bind_server_function(_server_server_fulltext_route._build_fulltext_chapters_from_cache, sys.modules[__name__])


get_job_fulltext = app.get("/api/jobs/{job_id}/fulltext")(_bind_server_function(_server_server_fulltext_route.get_job_fulltext, sys.modules[__name__]))


from src import server_history_routes as _server_server_history_routes

from src.server_bootstrap_history_routes import _initialize_server_history_routes

_initialize_server_history_routes(sys.modules[__name__])


from src import server_voice_routes as _server_server_voice_routes

from src.server_bootstrap_voice_policy import _initialize_server_voice_policy

_initialize_server_voice_policy(sys.modules[__name__])


from src import server_telemetry_routes as _server_server_telemetry_routes

from src.server_bootstrap_telemetry_routes import _initialize_server_telemetry_routes

_initialize_server_telemetry_routes(sys.modules[__name__])


from src._server_conversion_helpers import advance_chapter_progress as advance_chapter_progress, broadcast_progress as broadcast_progress, chapter_can_retry as chapter_can_retry, chapter_requires_audio as chapter_requires_audio, collect_failed_chapters as collect_failed_chapters, collect_missing_chapters as collect_missing_chapters, complete_chapter_progress as complete_chapter_progress, compute_parallel_slots as compute_parallel_slots, count_completed_chapters as count_completed_chapters, count_words as count_words, detect_reusable_existing_output as detect_reusable_existing_output, edge_retry_adjustments as edge_retry_adjustments, expected_output_path as expected_output_path, mark_retry_round as mark_retry_round, note_chapter_attempt as note_chapter_attempt, preflight_language_check as preflight_language_check, recalculate_progress as recalculate_progress, refresh_chapter_completion as refresh_chapter_completion, reset_chapter_progress_tracking as reset_chapter_progress_tracking, resolve_recent_speed as resolve_recent_speed, resolve_tts_output as resolve_tts_output, sync_soft_failures as sync_soft_failures, update_estimated_chapter_progress as update_estimated_chapter_progress, update_job_progress as update_job_progress
from src._server_job_helpers import _cleanup_job_output as _cleanup_job_output, _cleanup_output_directory as _cleanup_output_directory, _clear_all_caches, _clear_all_outputs, _clear_job_cache as _clear_job_cache, _clear_restart_staging_dirs, _extract_chapter_details as _extract_chapter_details, _finalize_cancel as _finalize_cancel, _persist_job as _persist_job, _purge_all_jobs, _purge_job_data as _purge_job_data, _record_chapter_failure as _record_chapter_failure, _write_progress_checkpoint as _write_progress_checkpoint


from src.server_bootstrap_output_policy import _initialize_server_output_policy

_initialize_server_output_policy(sys.modules[__name__])


async def process_conversion(job_id: str) -> None:
    import sys
    from src.server_conversion_state import ServerConversionState
    from src.server_conversion_run import _server_conversion_run

    state = ServerConversionState(
        job_id=job_id,
    )
    flow = await _server_conversion_run(sys.modules[__name__], state)
    return flow.value if flow is not None else None


from src._server_audio_helpers import AudioDuplicateTracker as AudioDuplicateTracker, _apply_priority_order as _apply_priority_order, _build_text_preview as _build_text_preview, _detect_short_audio_output as _detect_short_audio_output, _get_audio_duration as _get_audio_duration, _guess_media_type as _guess_media_type, _preload_existing_outputs as _preload_existing_outputs, _set_chapter_status as _set_chapter_status, _set_engine_status as _set_engine_status, _set_job_error as _set_job_error, _sort_output_entries as _sort_output_entries

_PROGRESS_CHECKPOINT_NAME = "_progress_checkpoint.json"


download_sample_epub = app.get("/sample.epub")(_bind_server_function(_server_server_download_routes.download_sample_epub, sys.modules[__name__]))


from src.routes_health import router as _health_router
from src.routes_sessions import router as _sessions_router
from src.routes_telemetry import router as _telemetry_router
from src.routes_uploads import router as _uploads_router

app.include_router(_health_router)
app.include_router(_sessions_router)
app.include_router(_telemetry_router)
app.include_router(_uploads_router)


if __name__ == "__main__":  # pragma: no cover - manual execution helper
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
