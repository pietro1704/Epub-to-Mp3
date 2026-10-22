# -*- coding: utf-8 -*-
"""Keep-alive, old-job retention and telemetry artifact cleanup."""

from __future__ import annotations

from pathlib import Path
from typing import List, Optional


async def _hf_keepalive(_runtime, interval_seconds: float = 600.0) -> None:
    """Ping the local health endpoint periodically to prevent HF Space hibernation.

    HF free-tier Spaces sleep after ~15 min of inactivity. This keeps the
    process alive so users can still download completed conversions hours later.
    Only started when SPACE_ID env var is set (i.e. running on HF Spaces).
    """
    import httpx

    # Use localhost only — pinging the public URL from within the Space causes
    # HF's proxy to count those requests against the rate limit, blocking users.
    # Localhost keeps the Python process and event loop alive without going
    # through HF's proxy.
    port = int(_runtime.os.getenv("PORT", "7860"))
    url = f"http://localhost:{port}/api/health"
    initial_delay = max(1, int(_runtime.os.getenv("HF_KEEPALIVE_INITIAL_DELAY", "10") or "10"))
    await _runtime.asyncio.sleep(initial_delay)
    while True:
        try:
            async with httpx.AsyncClient(timeout=15.0, follow_redirects=True) as client:
                resp = await client.get(url)
                _runtime.logger.debug("HF keep-alive ping → %s (%s)", resp.status_code, url)
        except Exception as exc:
            _runtime.logger.debug("HF keep-alive ping failed: %s", exc)
        await _runtime.asyncio.sleep(interval_seconds)


async def _periodic_job_cleanup(_runtime, ):
    """Periodically clean up old completed jobs."""
    while True:
        try:
            await _runtime.asyncio.sleep(_runtime.get_cleanup_interval_seconds())

            current_time = _runtime.time.time()
            jobs_to_remove = []

            for job_id, job_data in list(_runtime.jobs.items()):
                state = job_data.get("state")
                completed_at = job_data.get("completedAt")

                # Only cleanup finished/failed jobs
                if state in ("finished", "failed", "cancelled"):
                    if completed_at:
                        # Check if job is older than TTL
                        age_hours = (current_time - completed_at) / 3600
                        if age_hours > _runtime.COMPLETED_JOB_TTL_HOURS:
                            jobs_to_remove.append(job_id)
                    elif state == "finished":
                        # Old finished jobs without timestamp - remove after 1 hour since server start
                        # This handles jobs from before this fix
                        jobs_to_remove.append(job_id)

            if jobs_to_remove:
                _runtime.logger.info(f"Cleaning up {len(jobs_to_remove)} old jobs")
                for job_id in jobs_to_remove:
                    # Remove from memory
                    _runtime.jobs.pop(job_id, None)
                    # Remove from disk
                    _runtime.job_manager.delete_job(job_id)
                    # Cleanup output files
                    _runtime._cleanup_job_output(job_id)
                    _runtime.logger.info(f"Cleaned up job {job_id}")

            telemetry_deleted = _runtime._cleanup_telemetry_artifacts(
                max_age_hours=_runtime.TELEMETRY_RETENTION_HOURS
            )
            if telemetry_deleted > 0:
                _runtime.logger.info("Telemetry cleanup removed %s stale file(s)", telemetry_deleted)

            # Combined .cache/ + output/ budget eviction (LRU + TTL).
            # Skip dirs that belong to currently active jobs.
            try:
                from src.storage_budget import (
                    CACHE_OUTPUT_MAX_BYTES,
                    CACHE_OUTPUT_TTL_HOURS,
                    evict_storage_budget,
                )

                active_dirs: list[Path] = []
                for _jid, _jdata in list(_runtime.jobs.items()):
                    if _jdata.get("state") in {"queued", "running", "cancelling"}:
                        active_dirs.append(_runtime._job_output_dir(_jid, _jdata))
                        # Also protect the corresponding .cache/ book dir
                        _slug = _jdata.get("bookSlug") or _jdata.get("bookTitle") or ""
                        if _slug:
                            active_dirs.append(_runtime.persistent_cache_dir / _slug)

                evict_storage_budget(
                    _runtime.persistent_cache_dir,
                    _runtime.output_dir,
                    max_bytes=CACHE_OUTPUT_MAX_BYTES,
                    ttl_hours=CACHE_OUTPUT_TTL_HOURS,
                    active_book_dirs=active_dirs,
                )
            except Exception as _budget_exc:
                _runtime.logger.warning("storage_budget eviction failed: %s", _budget_exc)

        except Exception as e:
            _runtime.logger.error(f"Error in periodic job cleanup: {e}", exc_info=True)


def _job_state_counts(_runtime, ) -> dict:
    counts = {
        "total": len(_runtime.jobs),
        "queued": 0,
        "running": 0,
        "finished": 0,
        "failed": 0,
        "cancelled": 0,
    }
    for job in _runtime.jobs.values():
        state = job.get("state")
        if not state:
            continue
        state_lower = state.lower()
        if state_lower in counts:
            counts[state_lower] += 1
        elif state_lower == "success":
            counts["finished"] += 1
    return counts


def _has_active_jobs(_runtime, ) -> bool:
    for job in _runtime.jobs.values():
        if job.get("state") in {"queued", "running", "cancelling"}:
            return True
    queue = _runtime._job_queue
    if queue is not None:
        try:
            return queue.qsize() > 0
        except Exception:
            return False
    return False


def _cleanup_telemetry_artifacts(_runtime, max_age_hours: int = 720) -> int:
    """Delete stale telemetry artifacts older than retention window."""
    retention_h = max(24, int(max_age_hours or 720))
    cutoff = _runtime.time.time() - (retention_h * 3600)
    telemetry_dir = _runtime.CACHE_DIR / "telemetry"
    if not telemetry_dir.exists():
        return 0

    keep_names = {
        "feature-ab-history.json",
        "ci-speed-baseline-nightly.json",
        "benchmark_profiles.json",
        "engine_samples.json",
        "performance-profiles.json",
        "engine-warm-start.json",
    }
    deleted = 0
    for path in telemetry_dir.rglob("*"):
        if not path.is_file():
            continue
        if path.name in keep_names:
            continue
        with _runtime.contextlib.suppress(OSError):
            if path.stat().st_mtime >= cutoff:
                continue
            path.unlink(missing_ok=True)
            deleted += 1
    return deleted


def _latest_segment_summary(_runtime, limit_scan: int = 300) -> Optional[Path]:
    """Find newest segment-metrics-summary.json across output tree."""
    candidates: List[Path] = []
    try:
        for idx, path in enumerate(_runtime.output_dir.rglob("segment-metrics-summary.json")):
            if idx >= max(1, int(limit_scan)):
                break
            if path.is_file():
                candidates.append(path)
    except Exception:
        return None
    if not candidates:
        return None
    try:
        return max(candidates, key=lambda p: p.stat().st_mtime)
    except Exception:
        return candidates[-1]


def _feature_ab_history_path(_runtime, ) -> Path:
    """Return canonical path for rolling feature A/B history cache."""
    return _runtime.CACHE_DIR / "telemetry" / "feature-ab-history.json"
