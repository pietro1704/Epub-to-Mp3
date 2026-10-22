# -*- coding: utf-8 -*-
"""Enqueue, schedule and resume conversion workers."""

from __future__ import annotations

import asyncio


def _ensure_job(_runtime, job_id: str) -> dict:
    job = _runtime.jobs.get(job_id)
    if job:
        return job
    job_data = _runtime.job_manager.load_job(job_id)
    if not job_data:
        raise _runtime.HTTPException(status_code=404, detail="Job not found")
    _runtime.jobs[job_id] = job_data
    return job_data


def _enqueue_job(_runtime, job_id: str) -> bool:
    """Queue a job for processing via workers. Returns False if queue unavailable."""
    queue = _runtime._job_queue
    if queue is None:
        return False
    if job_id in _runtime._jobs_in_queue:
        return True
    try:
        queue.put_nowait(job_id)
        _runtime._jobs_in_queue.add(job_id)
        return True
    except _runtime.asyncio.QueueFull:  # pragma: no cover - defensive
        _runtime.logger.warning("Job queue is full, cannot enqueue %s", job_id)
        return False


def _schedule_job_conversion(_runtime, job_id: str) -> bool:
    """Start at most one in-process conversion task for a job."""
    task = _runtime._job_tasks.get(job_id)
    if task is not None and not task.done():
        return False
    task = _runtime.asyncio.create_task(_runtime.process_conversion(job_id))
    _runtime._job_tasks[job_id] = task

    def _clear(done: asyncio.Task, *, expected: asyncio.Task = task) -> None:
        if _runtime._job_tasks.get(job_id) is expected:
            _runtime._job_tasks.pop(job_id, None)

    task.add_done_callback(_clear)
    return True


async def _job_worker(_runtime, worker_id: int) -> None:
    """Dedicated worker that processes jobs from the global queue."""
    assert _runtime._job_queue is not None
    while True:
        job_id = await _runtime._job_queue.get()
        _runtime._jobs_in_queue.discard(job_id)
        try:
            job = _runtime.jobs.get(job_id) or _runtime.job_manager.load_job(job_id)
            if not job:
                continue
            _runtime.jobs[job_id] = job
            state = job.get("state", "")
            if state in {"finished", "cancelled"}:
                continue
            _runtime.logger.info("Worker %s converting job %s (%s)", worker_id, job_id, state or "queued")
            _runtime._schedule_job_conversion(job_id)
            task = _runtime._job_tasks.get(job_id)
            if task is not None:
                await task
        except Exception as exc:  # pragma: no cover - defensive
            _runtime.logger.error(
                "Worker %s failed processing job %s: %s", worker_id, job_id, exc, exc_info=True
            )
            try:
                job = _runtime.jobs.get(job_id) or _runtime.job_manager.load_job(job_id)
                if job is not None:
                    job["state"] = "failed"
                    _runtime._set_job_error(job, str(exc))
                    job["resumeRequested"] = False
                    job["cancelRequested"] = False
                    job["parallelActive"] = 0
                    job["completedAt"] = _runtime.time.time()
                    _runtime._append_event(job, f"❌ Internal failure during conversion: {exc}")
                    _runtime._persist_job(job_id, force=True)
                    _runtime.jobs[job_id] = job
            except Exception:  # pragma: no cover - defensive
                _runtime.logger.exception("Failed to mark job %s as failed after worker crash", job_id)
        finally:
            _runtime._job_queue.task_done()


async def _resume_pending_jobs(_runtime, ) -> None:
    """Re-enqueue jobs that were running/queued before a restart."""
    if _runtime._skip_resume_on_startup:
        return
    await _runtime.asyncio.sleep(0.1)
    for job_id, job in list(_runtime.jobs.items()):
        state = job.get("state", "")
        if state not in {"queued", "running", "cancelling"}:
            continue
        file_path = _runtime.Path(job.get("file_path") or "")
        if not file_path.exists():
            job["state"] = "interrupted"
            _runtime._set_job_error(job, "Source file was lost after server restart")
            _runtime._append_event(job, "❌ Temporary source file not found - upload the EPUB again")
            _runtime._persist_job(job_id, force=True)
            continue
        job["state"] = "queued"
        job["resumeRequested"] = True
        # Reset chapters stuck in "processing" back to "pending" so they are
        # re-attempted by the resumed run instead of remaining orphaned.
        for entry in job.get("chapterProgress") or []:
            if entry.get("status") == "processing":
                entry["status"] = "pending"
        _runtime._append_event(job, "♻️ Conversion resumed after server restart")
        _runtime._persist_job(job_id, force=True)
        # Clean up orphaned Edge-TTS/Piper segment temp files left by the
        # previous server run before re-enqueuing.
        try:
            _runtime._cleanup_output_directory(_runtime._job_output_dir(job_id, job))
        except Exception:
            pass
        if not _runtime._enqueue_job(job_id):
            _runtime.logger.warning("Job queue unavailable during resume, executing inline for %s", job_id)
            _runtime._schedule_job_conversion(job_id)
