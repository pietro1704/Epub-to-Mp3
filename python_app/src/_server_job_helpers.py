"""Job persistence, cleanup, and purge helpers extracted from server.py.

All server-level globals (jobs, job_manager, _sse_clients, etc.) are accessed
via a lazy import inside each function to avoid circular imports.
"""

from __future__ import annotations

import contextlib
import shutil
import time
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Job persistence
# ---------------------------------------------------------------------------


def _persist_job(job_id: str, force: bool = True) -> None:
    """
    Helper to persist job state to disk.

    Args:
        job_id: Job ID to persist
        force: If True, persist immediately. If False, skip (use for non-critical updates)
    """
    import logging

    from python_app import server as _srv  # lazy to avoid circular import

    logger = logging.getLogger(__name__)

    job_data = _srv.jobs.get(job_id)
    if not job_data:
        logger.warning(f"Cannot persist job {job_id}: not found in memory")
        return

    if not force:
        _srv._schedule_job_broadcast(job_id, job_data)
        return  # Skip for non-critical updates

    # Trim event lists to prevent unbounded growth across many resume cycles.
    # The full log is preserved in _raw_log; events only need to be recent
    # enough for SSE replay and UI display.
    _MAX_EVENTS = 2000
    _MAX_RAW_LOG = 5000
    events = job_data.get("events")
    if isinstance(events, list) and len(events) > _MAX_EVENTS:
        job_data["events"] = events[-_MAX_EVENTS:]
    raw_log = job_data.get("_raw_log")
    if isinstance(raw_log, list) and len(raw_log) > _MAX_RAW_LOG:
        job_data["_raw_log"] = raw_log[-_MAX_RAW_LOG:]

    success = _srv.job_manager.save_job(job_id, job_data)
    if not success:
        logger.error(f"Failed to persist job {job_id} to disk")
    else:
        # Update index when job is persisted
        saved_at = _srv._determine_saved_at(job_data)
        book_title = job_data.get("bookTitle") or "Unknown"
        state = (job_data.get("state") or "").lower()
        if state == "cancelled":
            _srv._recent_jobs_index.pop(job_id, None)
        else:
            _srv._recent_jobs_index[job_id] = (saved_at, book_title)
    _srv._schedule_job_broadcast(job_id, job_data)


# ---------------------------------------------------------------------------
# Output / input cleanup
# ---------------------------------------------------------------------------


def _cleanup_job_output(job_id: str) -> None:
    """Remove the job output directory."""
    from python_app import server as _srv  # lazy to avoid circular import

    job_dir = _srv._job_output_dir(job_id)
    if job_dir.exists():
        shutil.rmtree(job_dir, ignore_errors=True)


def _remove_job_from_queue(job_id: str) -> None:
    """Remove a job from the worker queue if it is still queued."""
    import asyncio

    from python_app import server as _srv  # lazy to avoid circular import

    queue = _srv._job_queue
    if queue is None:
        return
    pending: list[str] = []
    while True:
        try:
            queued_id = queue.get_nowait()
            queue.task_done()
        except asyncio.QueueEmpty:
            break
        if queued_id != job_id:
            pending.append(queued_id)
    for queued_id in pending:
        queue.put_nowait(queued_id)
    _srv._jobs_in_queue.clear()
    _srv._jobs_in_queue.update(pending)


def _cleanup_job_inputs(job: dict) -> None:
    """Remove uploaded source files for a job."""
    source_path = Path(job.get("file_path") or "")
    with contextlib.suppress(OSError):
        source_path.unlink(missing_ok=True)
    upload_dir_path = Path(job.get("uploadDir") or "")
    if upload_dir_path.exists():
        shutil.rmtree(upload_dir_path, ignore_errors=True)


def _purge_job_data(job_id: str, job: Optional[dict] = None, *, purge_cache: bool = True) -> None:
    """Remove all persisted data and artifacts for a job."""
    from python_app import server as _srv  # lazy to avoid circular import

    _remove_job_from_queue(job_id)
    if job:
        if purge_cache:
            _clear_job_cache(job)
        _cleanup_job_inputs(job)
    _cleanup_job_output(job_id)
    _srv.job_manager.delete_job(job_id)
    _srv.jobs.pop(job_id, None)
    _srv._recent_jobs_index.pop(job_id, None)
    if job_id in _srv._sse_clients:
        _srv._sse_clients.pop(job_id, None)


def _purge_all_jobs(reason: str, *, keep_finished: bool = False, purge_cache: bool = True) -> int:
    """Remove all known jobs and their artifacts."""
    import logging

    from python_app import server as _srv  # lazy to avoid circular import

    logger = logging.getLogger(__name__)

    job_ids = set(_srv.jobs.keys()) | set(_srv.job_manager.list_all_jobs())
    purged_count = 0
    for job_id in list(job_ids):
        job_data = _srv.jobs.get(job_id) or _srv.job_manager.load_job(job_id)
        state = (job_data.get("state") or "").lower() if job_data else ""
        if keep_finished and state in {"finished", "success"}:
            continue
        if job_data:
            job_data["_purgeRequested"] = True
            job_data["cancelRequested"] = True
            job_data["resumeRequested"] = False
        _purge_job_data(job_id, job_data, purge_cache=purge_cache)
        purged_count += 1
    logger.warning("Purged %s job(s): %s", purged_count, reason)
    try:
        _srv.jobs.clear()
        _srv._recent_jobs_index.clear()
        # Clear in-memory cache of JobManager
        if hasattr(_srv.job_manager, "_memory_cache"):
            _srv.job_manager._memory_cache.clear()  # type: ignore[attr-defined]
    except Exception:
        pass
    return purged_count


# ---------------------------------------------------------------------------
# Cache helpers
# ---------------------------------------------------------------------------


def _clear_job_cache(job: dict) -> None:
    """Clear cached chapters/audio for this job."""
    from python_app import server as _srv  # lazy to avoid circular import

    try:
        cache_manager = _srv.get_cache_manager()
        source_path = Path(job.get("file_path", "")) if job.get("file_path") else None
        book_title = job.get("bookTitle")
        if source_path and source_path.exists():
            cache_manager.clear_cache(source_path, title=book_title)
        elif book_title:
            cache_manager.clear_cache(title=book_title)
    except Exception:
        pass


def _clear_all_caches() -> None:
    """Clear global caches (chapters + covers) on restart purge."""
    from python_app import server as _srv  # lazy to avoid circular import

    try:
        _srv.get_cache_manager().clear_cache()
    except Exception:
        pass


def _clear_all_outputs(*, preserve_cache: bool) -> None:
    """Clear all outputs and persistent job artifacts for a clean restart."""
    from python_app import server as _srv  # lazy to avoid circular import

    def _safe_remove(path: Path) -> None:
        try:
            if path.is_dir():
                shutil.rmtree(path, ignore_errors=True)
            else:
                path.unlink(missing_ok=True)
        except Exception:
            pass

    def _should_preserve(entry: Path) -> bool:
        if not preserve_cache:
            return False
        try:
            return entry.resolve() == _srv.cover_cache_dir.resolve()
        except Exception:
            return False

    def _is_restart_marker(entry: Path) -> bool:
        try:
            return entry.resolve() == _srv._restart_marker_path.resolve()
        except Exception:
            return False

    if _srv.output_dir.exists():
        for entry in _srv.output_dir.iterdir():
            if _should_preserve(entry) or _is_restart_marker(entry):
                continue
            _safe_remove(entry)

    for entry in (_srv.uploads_dir, _srv.job_inputs_dir, _srv.jobs_state_dir):
        if entry.exists():
            _safe_remove(entry)
        entry.mkdir(parents=True, exist_ok=True)


def _clear_restart_staging_dirs() -> None:
    """Clear transient uploads/inputs without touching completed outputs."""
    from python_app import server as _srv  # lazy to avoid circular import

    for entry in (_srv.uploads_dir, _srv.job_inputs_dir):
        if entry.exists():
            shutil.rmtree(entry, ignore_errors=True)
        entry.mkdir(parents=True, exist_ok=True)
    try:
        if _srv.cover_cache_dir.exists():
            shutil.rmtree(_srv.cover_cache_dir, ignore_errors=True)
        _srv.cover_cache_dir.mkdir(exist_ok=True, parents=True)
        _srv.cover_cache_index.clear()
        _srv._save_cover_cache(_srv.cover_cache_index)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Cancel finalisation
# ---------------------------------------------------------------------------


def _finalize_cancel(job_id: str, job: dict, note: str) -> None:
    """Mark job as cancelled and cleanup files/cache."""
    from python_app import server as _srv  # lazy to avoid circular import

    if job.get("state") == "cancelled":
        return
    current_index = job.get("_currentChapterIndex")
    if current_index:
        _srv._set_chapter_status(job, current_index, "cancelled")
    if note:
        _srv._append_event(job, note)
    job["parallelActive"] = 0
    _srv._append_event(job, "🛑 Conversion cancelled by user")
    job["state"] = "cancelled"
    _srv._set_job_error(job, "Cancelled by user")
    job["cancelRequested"] = True
    job["resumeRequested"] = False
    job["currentChapter"] = None
    job["progressPercent"] = job.get("progressPercent") or 0.0
    job["completedAt"] = time.time()  # Timestamp for cleanup
    _persist_job(job_id, force=True)
    if job.get("_purgeRequested"):
        _purge_job_data(job_id, job)
        return
    # KEEP cancelled jobs in memory for a while (cleanup task will remove later)
    _srv._persist_job_log(job_id, job)


# ---------------------------------------------------------------------------
# Progress checkpoint
# ---------------------------------------------------------------------------


def _write_progress_checkpoint(job_id: str, job: dict, job_output_dir: Path) -> None:
    """Persist a lightweight checkpoint with completed chapter indices.

    Written every N chapters (same cadence as _persist_job) so that
    _preload_existing_outputs can recover instantly without scanning MP3 files.
    """
    import json

    from python_app import server as _srv  # lazy to avoid circular import

    try:
        entries = job.get("chapterProgress") or []
        completed = [
            e.get("index")
            for e in entries
            if isinstance(e, dict)
            and e.get("status") in ("completed", "skipped")
            and e.get("index") is not None
        ]
        record = {
            "job_id": job_id,
            "timestamp": _srv._utcnow_iso(),
            "completed_indices": completed,
            "last_completed": max(completed) if completed else 0,
            "total_chapters": job.get("chaptersTotal") or 0,
            "engine": job.get("engine", ""),
            "voice": job.get("voice", ""),
        }
        checkpoint_path = job_output_dir / _srv._PROGRESS_CHECKPOINT_NAME
        checkpoint_path.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass  # Checkpoint is best-effort; never break a conversion


# ---------------------------------------------------------------------------
# Chapter failure recording
# ---------------------------------------------------------------------------


def _extract_chapter_details(job: dict) -> list[dict]:
    """Extract per-chapter timing/engine data from job chapterProgress for session log."""
    entries = job.get("chapterProgress")
    if not isinstance(entries, list):
        return []
    details = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        detail: dict = {
            "index": entry.get("index"),
            "name": entry.get("name", ""),
            "status": entry.get("status", ""),
            "engine": entry.get("engine", ""),
            "chars": entry.get("textLength") or entry.get("chars"),
        }
        if entry.get("charsProcessed") is not None:
            detail["charsProcessed"] = entry["charsProcessed"]
        if entry.get("progressRatio") is not None:
            detail["progressRatio"] = entry["progressRatio"]
        if entry.get("wordCount") is not None:
            detail["wordCount"] = entry["wordCount"]
        if entry.get("startedAt"):
            detail["startedAt"] = entry["startedAt"]
        if entry.get("completedAt"):
            detail["completedAt"] = entry["completedAt"]
        if entry.get("elapsedSeconds") is not None:
            detail["elapsedSeconds"] = entry["elapsedSeconds"]
        if entry.get("charsPerSecond") is not None:
            detail["charsPerSecond"] = entry["charsPerSecond"]
        if entry.get("engineSequence"):
            detail["engineSequence"] = entry["engineSequence"]
        if entry.get("retryCount"):
            detail["retryCount"] = entry["retryCount"]
        if entry.get("retryReason"):
            detail["retryReason"] = entry["retryReason"]
        if entry.get("errorCategory"):
            detail["errorCategory"] = entry["errorCategory"]
        if entry.get("errorMessage"):
            detail["errorMessage"] = entry["errorMessage"]
        # Remove None values to keep log compact
        details.append({k: v for k, v in detail.items() if v is not None})
    return details


def _record_chapter_failure(
    job: dict,
    tts_engine,
    chapter_name: str,
    error: object,
    chapter_index: Optional[int] = None,
    fatal: bool = True,
) -> bool:
    from python_app import server as _srv  # lazy to avoid circular import

    last_error = getattr(tts_engine, "last_error", None)
    error_message = str(error) if error else "unknown error"
    if isinstance(error, FileNotFoundError):
        failure_detail = last_error or "Edge TTS did not create an audio file"
    else:
        failure_detail = last_error or error_message
    _srv._set_chapter_status(job, chapter_index, "failed", error_message=failure_detail)
    _srv._append_event(job, "")
    _srv._append_event(job, f"❌ Chapter synthesis failed for '{chapter_name}': {failure_detail}")
    if error:
        error_type = getattr(error, "__class__", type(error)).__name__
    else:
        error_type = "UnknownError"

    if last_error and error_message and last_error != error_message:
        _srv._append_event(job, f"   ↳ Internal error ({error_type}): {error_message}")
    elif not last_error and error_message:
        _srv._append_event(job, f"   ↳ Internal error ({error_type}): {error_message}")
    failure_payload = {
        "chapter": chapter_name,
        "index": chapter_index,
        "detail": failure_detail,
    }
    if fatal:
        job["state"] = "failed"
        _srv._set_job_error(job, f"Chapter synthesis failed for '{chapter_name}': {failure_detail}")
        job.setdefault("outputs", [])

        job_id = job.get("jobId")
        if job_id:
            _srv._persist_job_log(job_id, job)

        _clear_job_cache(job)
    else:
        soft_failures = job.setdefault("softFailures", [])
        if isinstance(soft_failures, list):
            soft_failures.append(failure_payload)
        _srv._append_event(job, "   ↳ Chapter marked as failed; moving to the next one.")
    return fatal


# ---------------------------------------------------------------------------
# Output directory cleanup
# ---------------------------------------------------------------------------


def _cleanup_output_directory(job_output_dir: Path) -> None:
    """Remove leftover temp artifacts (Edge segments, partial files, etc.)."""
    from src.utils import FileManager

    try:
        FileManager.cleanup_temp_files(job_output_dir, "tmp*.mp3")
        FileManager.cleanup_temp_files(job_output_dir, "tmp*.wav")
        FileManager.cleanup_temp_files(job_output_dir, "*.tmp")
    except Exception:
        pass
