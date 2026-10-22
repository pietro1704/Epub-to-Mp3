# -*- coding: utf-8 -*-
"""Coordinate server conversion phases and original control flow."""

from __future__ import annotations

from typing import Optional


from .server_conversion_preparation import _server_conversion_preparation
from .server_metadata_preparation import _server_metadata_preparation
from .server_engine_preparation import _server_engine_preparation
from .server_engine_pool_preparation import _server_engine_pool_preparation
from .server_chapter_scheduler import _server_chapter_scheduler
from .server_retry_scheduler import _server_retry_scheduler
from .server_conversion_completion import _server_conversion_completion

async def _server_conversion_run(_runtime, _state):
    _state.job = _runtime.jobs[_state.job_id]
    _state.zip_archive: Optional[_runtime.zipfile.ZipFile] = None
    _state.zip_open = False
    _state.conversion_started = _runtime.time.time()
    if not _state.job.get("startedAt"):
        _state.job["startedAt"] = _runtime._utcnow_iso()
    _state.run_token = str(_runtime.uuid.uuid4())
    _state.job["_run_token"] = _state.run_token
    _runtime._update_job_activity(_state.job, stage="starting")

    def _should_abort_current_run(note: Optional[str] = None) -> bool:
        if _state.job.get("cancelRequested"):
            _runtime._finalize_cancel(_state.job_id, _state.job, note or "🛑 Conversion cancelled before start")
            return True
        if _state.job.get("_run_token") != _state.run_token:
            _runtime._append_event(_state.job, "⏹️ Current run replaced by a newer attempt.")
            return True
        return False
    _state._should_abort_current_run = _should_abort_current_run

    try:
        _phase_flow = await _server_conversion_preparation(_runtime, _state)
        if _phase_flow is not None:
            return _phase_flow
        _phase_flow = await _server_metadata_preparation(_runtime, _state)
        if _phase_flow is not None:
            return _phase_flow
        _phase_flow = await _server_engine_preparation(_runtime, _state)
        if _phase_flow is not None:
            return _phase_flow
        _phase_flow = await _server_engine_pool_preparation(_runtime, _state)
        if _phase_flow is not None:
            return _phase_flow
        _phase_flow = await _server_chapter_scheduler(_runtime, _state)
        if _phase_flow is not None:
            return _phase_flow
        _phase_flow = await _server_retry_scheduler(_runtime, _state)
        if _phase_flow is not None:
            return _phase_flow
        _phase_flow = await _server_conversion_completion(_runtime, _state)
        if _phase_flow is not None:
            return _phase_flow

    except Exception as exc:  # pragma: no cover - defensive handling
        _state.exc = exc
        _runtime.logger.exception("Job %s failed with unhandled error", _state.job_id)
        _state.job["state"] = "failed"
        _runtime._set_job_error(_state.job, str(_state.exc))
        _state.job["completedAt"] = _runtime.time.time()  # Timestamp for cleanup
        _state.job["completedAtIso"] = _runtime._utcnow_iso()
        _runtime._update_job_activity(_state.job, stage="failed")
        _runtime._append_event(_state.job, f"❌ Error: {_state.exc}")
        _state.job["parallelActive"] = 0
        _runtime._persist_job(_state.job_id)
        _runtime._persist_job_log(_state.job_id, _state.job)

        # Persistent conversion session log
        try:
            from src.session_logger import log_session
            _state.log_session = log_session

            _state._elapsed = _runtime.time.time() - _state.conversion_started
            _state._ch_total = _state.job.get("chaptersTotal") or 0
            _state._cp = _state.job.get("chapterProgress") or []
            if _state._cp:
                _state._ch_done = sum(1 for c in _state._cp if c.get("status") == "completed")
                _state._ch_failed = sum(1 for c in _state._cp if c.get("status") in {"failed", "skipped"})
            else:
                _state._ch_done = _state.job.get("chaptersCompleted") or 0
                _state._ch_failed = _state._ch_total - _state._ch_done
            _state._outcome = "failed" if _state._ch_done == 0 else "partial"
            _state._chapter_details = _runtime._extract_chapter_details(_state.job)
            _state.log_session(
                book_title=_state.job.get("bookTitle", ""),
                book_author=_state.job.get("bookAuthor", ""),
                language=_state.job.get("detectedLanguage", ""),
                engine=_state.job.get("engine", ""),
                voice=_state.job.get("voice", ""),
                chapters_total=_state._ch_total,
                chapters_converted=_state._ch_done,
                chapters_failed=_state._ch_failed,
                duration_seconds=_state._elapsed,
                outcome=_state._outcome,
                job_id=_state.job_id,
                output_dir=str(_state.job.get("outputDir", "")),
                started_at=_state.job.get("startedAt", ""),
                chapter_details=_state._chapter_details or None,
                extra={"error": str(_state.exc)},
            )
        except Exception:
            pass  # Never let logging break a conversion

    finally:
        with _runtime.contextlib.suppress(Exception):
            if _state.zip_archive:
                _state.zip_archive.close()
        _state.temp_path_str = _state.job.get("file_path")
        if _state.temp_path_str and _state.job.get("state") in {"finished", "cancelled"}:
            _state.temp_path = _runtime.Path(_state.temp_path_str)
            with _runtime.contextlib.suppress(FileNotFoundError):
                _state.temp_path.unlink()
