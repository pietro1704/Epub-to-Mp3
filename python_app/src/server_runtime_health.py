# -*- coding: utf-8 -*-
"""System load snapshots, stalled jobs and worker scaling."""

from __future__ import annotations

from typing import Optional


def _estimate_recommendations(_runtime, stats: Optional[dict]) -> dict:
    if not stats:
        return {
            "parallelSlots": _runtime._PARALLEL_SLOTS_DEFAULT,
            "jobWorkers": _runtime._JOB_WORKERS,
        }
    cpu_info = stats.get("cpu") or {}
    mem_info = stats.get("memory") or {}
    cpu_idle = max(0.0, 100.0 - float(cpu_info.get("percent") or 0.0))
    logical = cpu_info.get("logical") or cpu_info.get("physical") or 1
    available_mem = mem_info.get("available") or 0
    available_gb = available_mem / (1024**3)

    slots = _runtime._PARALLEL_SLOTS_DEFAULT
    if cpu_idle > 55 and available_gb > 6:
        slots += 2
    elif cpu_idle > 30 and available_gb > 3:
        slots += 1
    elif cpu_idle < 12 or available_gb < 1.5:
        slots = max(1, slots - 1)
    slots = max(1, min(int(slots), min(_runtime._CHAPTER_PARALLEL_MAX, logical)))

    job_workers = _runtime._JOB_WORKERS
    if cpu_idle > 65 and available_gb > 8:
        job_workers = min(job_workers + 1, max(1, logical))
    elif cpu_idle < 15 or available_gb < 2:
        job_workers = max(1, job_workers - 1)
    job_workers = max(1, min(job_workers, _runtime._WORKER_CAP))

    return {
        "parallelSlots": slots,
        "jobWorkers": job_workers,
    }


def _determine_parallel_slots(_runtime, requested: int) -> int:
    stats = _runtime.system_monitor.latest() if _runtime.system_monitor else {}
    recommendation = _runtime._estimate_recommendations(stats)
    target = recommendation["parallelSlots"]
    if _runtime.FORCE_TURBO:
        return min(_runtime._CHAPTER_PARALLEL_MAX, max(requested, target, _runtime._CHAPTER_PARALLEL_MAX))
    if requested > target:
        return requested
    return target


def _build_system_stats_payload(_runtime, ) -> dict:
    stats = _runtime.system_monitor.latest() or {}
    job_counts = _runtime._job_state_counts()
    telemetry_summary = _runtime.telemetry.summary()
    queue_depth = 0
    if _runtime._job_queue is not None:
        try:
            queue_depth = _runtime._job_queue.qsize()
        except Exception:
            queue_depth = 0
    stats_payload = {
        "timestamp": stats.get("timestamp", _runtime.time.time()),
        "uptimeSeconds": stats.get("uptimeSeconds"),
        "cpu": stats.get("cpu"),
        "memory": stats.get("memory"),
        "swap": stats.get("swap"),
        "disk": stats.get("disk"),
        "network": stats.get("network"),
        "gpus": stats.get("gpus", []),
        "jobs": {
            **job_counts,
            "queueDepth": queue_depth,
            "inFlight": sum(1 for job in _runtime.jobs.values() if job.get("state") == "running"),
            "workers": {
                "current": len(_runtime._job_workers),
                "target": _runtime._JOB_WORKERS,
            },
        },
        "recommendations": _runtime._estimate_recommendations(stats),
        "telemetry": telemetry_summary,
    }
    return stats_payload


def _handle_stalled_job(_runtime, job_id: str, job: dict, inactivity_seconds: float) -> bool:
    """
    Handle stalled job. Returns True when conversion should be scheduled inline.
    """
    now = _runtime.time.time()
    job["_stallHandledAt"] = now
    stage_label = job.get("_lastStage") or job.get("statusHint") or "process"
    inactivity_label = _runtime.TimeFormatter.format_time(inactivity_seconds)
    attempts = job.get("_stallRestartCount", 0)
    job["_run_token"] = str(_runtime.uuid.uuid4())
    message_prefix = f"⚠️ No progress for {inactivity_label} (stage: {stage_label}). "
    if attempts < _runtime._STALL_MAX_AUTO_RETRIES:
        job["_stallRestartCount"] = attempts + 1
        job["state"] = "queued"
        job["resumeRequested"] = True
        job["cancelRequested"] = False
        job["statusHint"] = "Restarting after stall detection"
        _runtime._append_event(
            job,
            f"{message_prefix}Retrying automatically "
            f"({job['_stallRestartCount']}/{_runtime._STALL_MAX_AUTO_RETRIES}).",
        )
        _runtime._persist_job(job_id, force=True)
        if not _runtime._enqueue_job(job_id):
            return True
        return False

    job["state"] = "interrupted"
    job["resumeRequested"] = False
    job["cancelRequested"] = False
    job["statusHint"] = "Conversion interrupted (no progress)"
    _runtime._set_job_error(
        job,
        "Conversion automatically interrupted after repeated failures. "
        "Retry the job or choose another voice engine.",
    )
    job["completedAt"] = now
    _runtime._append_event(
        job,
        f"{message_prefix}Stopped to avoid a permanent stall. Try again with different settings.",
    )
    _runtime._persist_job(job_id, force=True)
    _runtime._persist_job_log(job_id, job)
    return False


def _detect_stalled_jobs(_runtime, now: Optional[float] = None) -> list[str]:
    """Identify stalled running jobs and trigger automatic recovery."""
    if now is None:
        now = _runtime.time.time()
    inline: list[str] = []
    for job_id, job in _runtime.jobs.items():
        if not job or job.get("state") != "running":
            continue
        if job.get("cancelRequested"):
            continue
        last_activity = _runtime._resolve_job_activity_timestamp(job)
        if not last_activity:
            continue
        if job.get("_stallHandledAt") and now - job["_stallHandledAt"] < _runtime._STALL_RECHECK_SECONDS:
            continue
        if now - last_activity < _runtime._STALL_THRESHOLD_SECONDS:
            continue
        if _runtime._handle_stalled_job(job_id, job, now - last_activity):
            inline.append(job_id)
    return inline


async def _job_watchdog(_runtime, ):
    """Ensure queued jobs are enqueued and detect stalled queues."""
    while True:
        await _runtime.asyncio.sleep(5)
        try:
            if _runtime._job_queue is None:
                continue
            queued_ids = [job_id for job_id, job in _runtime.jobs.items() if job.get("state") == "queued"]
            for job_id in queued_ids:
                if job_id in _runtime._jobs_in_queue:
                    continue
                _runtime._enqueue_job(job_id)

            stats = _runtime.system_monitor.latest() if _runtime.system_monitor else {}
            recommendation = _runtime._estimate_recommendations(stats)
            queue_depth = _runtime._job_queue.qsize()
            target_workers = recommendation["jobWorkers"]
            if _runtime.FORCE_TURBO:
                target_workers = max(
                    target_workers,
                    (_runtime._hardware_profile.cpu_physical or 1) * _runtime.TURBO_SLOT_MULTIPLIER,
                )
            elif queue_depth > 0:
                target_workers = max(target_workers, min(queue_depth + 1, _runtime.WORKER_MAX))
            target_workers = max(1, min(target_workers, _runtime._WORKER_CAP))
            await _runtime._scale_worker_pool(target_workers)
            stalled_inline = _runtime._detect_stalled_jobs()
            for stalled_id in stalled_inline:
                _runtime._schedule_job_conversion(stalled_id)
        except Exception as exc:  # pragma: no cover - defensive
            _runtime.logger.error("Job watchdog encountered an error: %s", exc, exc_info=True)


async def _scale_worker_pool(_runtime, target: int) -> None:
    target = max(1, min(target, _runtime.WORKER_MAX, _runtime._WORKER_CAP, _runtime.MAX_CONCURRENT_BOOKS))
    async with _runtime._worker_scale_lock:
        current = len(_runtime._job_workers)
        if target == current:
            _runtime._JOB_WORKERS = target
            return
        if target > current:
            for _ in range(target - current):
                worker_id = len(_runtime._job_workers) + 1
                task = _runtime.asyncio.create_task(_runtime._job_worker(worker_id))
                _runtime._job_workers.append(task)
            _runtime.logger.info("Scaled worker pool up to %s workers", len(_runtime._job_workers))
        else:
            for _ in range(current - target):
                task = _runtime._job_workers.pop()
                task.cancel()
                with _runtime.contextlib.suppress(_runtime.asyncio.CancelledError):
                    await task
            _runtime.logger.info("Scaled worker pool down to %s workers", len(_runtime._job_workers))
        _runtime._JOB_WORKERS = target


async def _schedule_restart(_runtime, delay: float = 0.5) -> None:
    await _runtime.asyncio.sleep(delay)
    _runtime.logger.warning("Restarting backend process now")
    _runtime.os._exit(0)
