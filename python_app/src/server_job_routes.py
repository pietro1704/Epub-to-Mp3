# -*- coding: utf-8 -*-
"""Job cancellation, observations, resume, deletion and log access."""

from __future__ import annotations


from .server_models import JourneyObservationInput


async def cancel_job(_runtime, job_id: str) -> dict:
    _runtime._validate_job_id(job_id)
    job = _runtime.jobs.get(job_id)
    if job is None:
        job_data = _runtime.job_manager.load_job(job_id)
        if not job_data:
            raise _runtime.HTTPException(status_code=404, detail="Job not found")
        _runtime.jobs[job_id] = job_data
        job = job_data

    state = job.get("state", "queued")
    if state in {"finished", "failed", "interrupted", "cancelled"}:
        return {"status": state}

    job["cancelRequested"] = True

    if state == "queued":
        _runtime._finalize_cancel(job_id, job, "🛑 Conversion cancelled before start")
        return {"status": "cancelled"}

    if state != "cancelling":
        job["state"] = "cancelling"
        _runtime._append_event(job, "🛑 Cancellation requested. Finishing current chapter...")
        _runtime._persist_job(job_id, force=True)

    return {"status": job["state"]}


async def record_journey_observation(_runtime,
    job_id: str, observation: JourneyObservationInput
) -> dict[str, str]:
    """Persist one redacted listener-visible timing boundary for a job.

    The client owns its monotonic clock, while this endpoint only associates
    its random short-lived journey identifier with the server conversion job.
    It deliberately rejects arbitrary metadata so book content, listener
    identity, URLs, and audio payloads cannot enter diagnostics.
    """
    _runtime._validate_job_id(job_id)
    job = _runtime.jobs.get(job_id) or _runtime.job_manager.load_job(job_id)
    if not job:
        raise _runtime.HTTPException(status_code=404, detail="Job not found")
    _runtime.jobs[job_id] = job

    try:
        journey_id = str(_runtime.uuid.UUID(observation.journeyId))
    except (ValueError, AttributeError):
        raise _runtime.HTTPException(status_code=422, detail="journeyId must be a UUID")
    if observation.transition not in _runtime._JOURNEY_TRANSITIONS:
        raise _runtime.HTTPException(status_code=422, detail="Unsupported journey transition")
    if observation.elapsedNanoseconds < 0:
        raise _runtime.HTTPException(status_code=422, detail="elapsedNanoseconds must be non-negative")

    records = job.setdefault("journeyObservations", [])
    records.append(
        {
            "journeyId": journey_id,
            "transition": observation.transition,
            "elapsedNanoseconds": observation.elapsedNanoseconds,
            "recordedAt": _runtime.time.time(),
        }
    )
    if len(records) > _runtime._JOURNEY_OBSERVATION_LIMIT:
        del records[:-_runtime._JOURNEY_OBSERVATION_LIMIT]
    _runtime._persist_job(job_id)
    return {"status": "recorded"}


async def resume_job(_runtime, job_id: str) -> dict:
    """Requeue an interrupted/failed job so it can continue conversion."""
    _runtime._validate_job_id(job_id)
    job = _runtime._ensure_job(job_id)
    state = job.get("state", "")
    if state == "finished":
        return {"status": "finished"}
    try:
        source_path = _runtime._resolve_job_source_path(job.get("file_path") or "", must_exist=True)
    except ValueError:
        raise _runtime.HTTPException(status_code=409, detail="Source file is no longer available")
    if not source_path.exists():
        raise _runtime.HTTPException(status_code=409, detail="Source file is no longer available")
    job["cancelRequested"] = False
    job.pop("_purgeRequested", None)
    job["resumeRequested"] = True
    job["state"] = "queued"
    _runtime._append_event(job, "♻️ Resuming conversion at user request")
    _runtime._persist_job(job_id, force=True)
    if not _runtime._enqueue_job(job_id):
        raise _runtime.HTTPException(status_code=503, detail="Processing queue is currently unavailable")
    return {"status": "queued"}


async def delete_job(_runtime, job_id: str) -> dict:
    """Remove a job and its artifacts from disk."""
    _runtime._validate_job_id(job_id)
    job = _runtime.jobs.get(job_id) or _runtime.job_manager.load_job(job_id)
    if not job:
        raise _runtime.HTTPException(status_code=404, detail="Job not found")
    if job_id not in _runtime.jobs:
        _runtime.jobs[job_id] = job

    state = job.get("state", "queued")
    if state in {"queued", "running", "cancelling"}:
        job["_purgeRequested"] = True
        job["cancelRequested"] = True
        if state == "queued":
            _runtime._finalize_cancel(job_id, job, "🗑️ Conversion removed before start")
            return {"status": "deleted"}
        if state != "cancelling":
            job["state"] = "cancelling"
            _runtime._append_event(job, "🗑️ Removal requested. Finishing current chapter...")
        _runtime._persist_job(job_id, force=True)
        return {"status": "cancelling"}

    _runtime._purge_job_data(job_id, job)
    return {"status": "deleted"}


async def get_job_log(_runtime, job_id: str):
    """Return the persistent conversion log for a job.

    The SwiftUI macOS client calls this endpoint from LogsView. Prefer the
    on-disk conversion.log so completed jobs remain inspectable after memory
    trimming, then fall back to the in-memory raw log/events for active jobs
    that have not flushed a log file yet.
    """
    try:
        _runtime._validate_job_id(job_id)
    except ValueError:
        raise _runtime.HTTPException(status_code=400, detail="Invalid job id")
    job_data = _runtime.jobs.get(job_id) or _runtime.job_manager.load_job(job_id)
    if not job_data:
        raise _runtime.HTTPException(status_code=404, detail="Job not found")

    # Re-anchor the resolved output dir inside `output_dir` at the sink
    # site so CodeQL's data-flow recognises the containment check that
    # `_job_output_dir` already performs internally. Without this the
    # `.resolve()` below trips py/path-injection alert #80.
    try:
        base_dir = _runtime._resolve_path_within_root(
            _runtime.output_dir, _runtime._job_output_dir(job_id, job_data), must_exist=False
        )
    except ValueError:
        raise _runtime.HTTPException(status_code=400, detail="Invalid job id")
    legacy_base = _runtime._resolve_relative_path_within_root(_runtime.output_dir, job_id, must_exist=False)
    for candidate_root in (base_dir, legacy_base):
        log_path = candidate_root / "conversion.log"
        if not (log_path.exists() and log_path.is_file()):
            continue
        try:
            resolved_log = _runtime._resolve_path_within_root(
                candidate_root, "conversion.log", must_exist=False
            )
        except ValueError:
            # Symlink resolves outside the candidate root — skip and
            # fall back to the raw log path. Matches the original
            # `is_relative_to(root)` guard.
            continue
        if resolved_log == log_path.resolve():
            return _runtime.FileResponse(
                path=log_path,
                media_type="text/plain; charset=utf-8",
                filename="conversion.log",
            )

    raw_log = job_data.get("_raw_log")
    if isinstance(raw_log, list) and raw_log:
        lines = [str(line) for line in raw_log]
    else:
        events = job_data.get("events")
        lines = (
            [_runtime._sanitize_event_message(str(event)) for event in events]
            if isinstance(events, list)
            else []
        )
    body = "\n".join(lines)
    if body:
        body += "\n"
    return _runtime.PlainTextResponse(body)
