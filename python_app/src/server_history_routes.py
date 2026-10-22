# -*- coding: utf-8 -*-
"""Retention and current/recent job status endpoints."""

from __future__ import annotations


from fastapi import Request

from .server_models import JobStatus


async def cleanup_old_files(_runtime, max_age_hours: int = 48) -> dict:
    """
    Cleanup old files from local storage.

    This endpoint should be called periodically (e.g., via cron job).
    """
    result = {"local_deleted": 0, "errors": 0}

    # Cleanup local files
    import time

    cutoff_time = time.time() - (max_age_hours * 3600)

    for job_dir in _runtime.output_dir.iterdir():
        if not job_dir.is_dir():
            continue

        # Check directory age
        dir_mtime = job_dir.stat().st_mtime
        if dir_mtime < cutoff_time:
            try:
                import shutil

                shutil.rmtree(job_dir)
                result["local_deleted"] += 1
                _runtime.logger.info(f"Deleted old job directory: {job_dir.name}")
            except Exception:
                result["errors"] += 1
                _runtime.logger.exception("Failed to delete old job directory: %s", job_dir.name)

    # Cleanup old job state files
    jobs_deleted = _runtime.job_manager.cleanup_old_jobs(max_age_hours=max_age_hours)
    result["jobs_deleted"] = jobs_deleted
    result["telemetry_deleted"] = _runtime._cleanup_telemetry_artifacts(
        max_age_hours=max(max_age_hours, _runtime.TELEMETRY_RETENTION_HOURS)
    )

    _runtime.logger.info(f"Cleanup completed: {result}")
    return result


async def get_resumable_jobs(_runtime, ) -> dict:
    """Get list of jobs that can be resumed."""
    resumable = _runtime._collect_resumable_job_entries()
    return {"resumable_jobs": resumable, "count": len(resumable)}


async def get_recent_jobs(_runtime, limit: int = 10) -> dict:
    """Return recently saved jobs (finished or resumable)."""
    entries = _runtime._collect_recent_job_entries(limit=limit)
    return {
        "jobs": entries,
        "count": len(entries),
    }


async def get_job_status(_runtime, job_id: str) -> JobStatus:
    # Check in-memory jobs first
    if job_id in _runtime.jobs:
        return _runtime.JobStatus(**_runtime._job_status_payload(_runtime.jobs[job_id]))

    # Try to load from disk if not in memory
    _runtime.logger.info(f"Job {job_id} not in memory, attempting to load from disk")
    job_data = _runtime.job_manager.load_job(job_id)
    if job_data:
        # Add back to memory cache for future requests
        _runtime.jobs[job_id] = job_data
        _runtime.logger.info(f"Job {job_id} loaded from disk successfully")
        return _runtime.JobStatus(**_runtime._job_status_payload(job_data))

    # Attempt to rebuild metadata from the existing outputs on disk
    recovered_job = _runtime._restore_job_from_outputs(job_id)
    if recovered_job:
        _runtime.jobs[job_id] = recovered_job
        if _runtime.job_manager.save_job(job_id, recovered_job):
            saved_at = _runtime._determine_saved_at(recovered_job)
            book_title = recovered_job.get("bookTitle") or "Unknown"
            _runtime._recent_jobs_index[job_id] = (saved_at, book_title)
            _runtime.logger.warning("Job %s rehydrated from outputs directory", job_id)
        else:
            _runtime.logger.error("Failed to persist reconstructed job %s", job_id)
        _runtime._schedule_job_broadcast(job_id, recovered_job)
        return _runtime.JobStatus(**_runtime._job_status_payload(recovered_job))

    # Log all available jobs for debugging
    available_jobs = list(_runtime.jobs.keys())
    _runtime.logger.error(f"Job {job_id} not found! Available jobs in memory: {available_jobs[:5]}...")
    raise _runtime.HTTPException(status_code=404, detail=f"Job {job_id} not found")


async def stream_job_status(_runtime, job_id: str, request: Request):
    """**OPTIMIZATION #3**: Server-Sent Events endpoint for real-time job updates.

    Usage from frontend:
        const eventSource = new EventSource(`/api/jobs/${jobId}/stream`);
        eventSource.onmessage = (event) => {
            const jobData = JSON.parse(event.data);
            // Update UI with jobData
        };
    """
    # Verify job exists
    if job_id not in _runtime.jobs and not _runtime.job_manager.load_job(job_id):
        raise _runtime.HTTPException(status_code=404, detail=f"Job {job_id} not found")

    # Create queue for this client
    client_queue: _runtime.asyncio.Queue[dict] = _runtime.asyncio.Queue(maxsize=50)

    # Register client
    if job_id not in _runtime._sse_clients:
        _runtime._sse_clients[job_id] = set()
    _runtime._sse_clients[job_id].add(client_queue)

    _terminal_states = {"finished", "failed", "interrupted", "cancelled"}

    async def event_stream():
        try:
            # Send initial state immediately
            if job_id in _runtime.jobs:
                initial_data = _runtime._job_status_payload(_runtime.jobs[job_id])
                yield f"data: {_runtime.json.dumps(initial_data)}\n\n"
                if initial_data.get("state") in _terminal_states:
                    return

            # Stream updates
            while True:
                # Check if client disconnected
                if await request.is_disconnected():
                    break

                try:
                    # Wait for next update (with timeout to allow disconnect check)
                    job_data = await _runtime.asyncio.wait_for(client_queue.get(), timeout=1.0)
                    sse_event = job_data.get("_sse_event")
                    if sse_event:
                        clean = {k: v for k, v in job_data.items() if k != "_sse_event"}
                        yield f"event: {sse_event}\ndata: {_runtime.json.dumps(clean)}\n\n"
                    else:
                        yield f"data: {_runtime.json.dumps(job_data)}\n\n"
                    # Close stream once a terminal state is delivered
                    if job_data.get("state") in _terminal_states:
                        break
                except _runtime.asyncio.TimeoutError:
                    # On each heartbeat, check if the job reached a terminal state.
                    # This recovers from the case where the queue was full and the
                    # terminal broadcast was dropped, leaving the stream open forever.
                    current_job = _runtime.jobs.get(job_id)
                    if current_job and current_job.get("state") in _terminal_states:
                        final_data = _runtime._job_status_payload(current_job)
                        yield f"data: {_runtime.json.dumps(final_data)}\n\n"
                        break
                    yield ": heartbeat\n\n"

        finally:
            # Unregister client
            if job_id in _runtime._sse_clients and client_queue in _runtime._sse_clients[job_id]:
                _runtime._sse_clients[job_id].remove(client_queue)
                if not _runtime._sse_clients[job_id]:
                    del _runtime._sse_clients[job_id]

    return _runtime.StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",  # Disable nginx buffering
        },
    )
