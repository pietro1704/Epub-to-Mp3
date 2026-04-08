"""Health and system monitoring route handlers.

Extracted from server.py to reduce its line count.  All server-level globals
are accessed via lazy imports inside each handler to avoid circular imports.
"""

from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Request

router = APIRouter(prefix="/api", tags=["health"])


@router.get("/health")
async def health_check() -> dict:
    """Health check endpoint for monitoring."""
    from health_monitor import get_health_monitor

    import python_app.server as _srv

    monitor = get_health_monitor()
    latest = monitor.get_latest_snapshot()

    from python_app.version import __version__

    health_data = {
        "status": "healthy",
        "version": __version__,
        "storage": {
            "local_output_dir": str(_srv.output_dir),
        },
        "limits": {
            "max_upload_bytes": _srv.MAX_UPLOAD_BYTES,
            "max_upload_mb": _srv.MAX_UPLOAD_MB,
        },
    }

    if latest:
        health_data["monitor"] = {
            "heap_status": latest.heap_status,
            "memory_percent": latest.memory_percent,
            "cpu_percent": latest.cpu_percent,
            "gpu_available": latest.gpu_available,
            "thread_count": latest.thread_count,
        }

    return health_data


@router.get("/health/monitor")
async def health_monitor_status() -> dict:
    """Health Monitor Status — returns detailed health monitor statistics."""
    from health_monitor import get_health_monitor

    monitor = get_health_monitor()
    return monitor.get_stats_summary()


@router.get("/health/alerts")
async def health_monitor_alerts(max_count: int = 50) -> dict:
    """Health Monitor Alerts — returns recent alerts from the monitor."""
    from health_monitor import get_health_monitor

    monitor = get_health_monitor()
    alerts = monitor.get_recent_alerts(max_count=max_count)

    return {
        "alerts": [
            {
                "timestamp": a.timestamp,
                "severity": a.severity,
                "category": a.category,
                "message": a.message,
                "details": a.details,
            }
            for a in alerts
        ],
        "count": len(alerts),
    }


@router.get("/health/dashboard")
async def health_monitor_dashboard() -> dict:
    """Health Monitor Dashboard — returns full monitoring dashboard data."""
    from health_monitor import get_health_monitor

    monitor = get_health_monitor()

    latest = monitor.get_latest_snapshot()
    summary = monitor.get_stats_summary()
    recent_alerts = monitor.get_recent_alerts(max_count=10)

    return {
        "summary": summary,
        "current": {
            "timestamp": latest.timestamp if latest else 0,
            "cpu_percent": latest.cpu_percent if latest else 0,
            "memory_mb": latest.memory_mb if latest else 0,
            "memory_percent": latest.memory_percent if latest else 0,
            "gpu_available": latest.gpu_available if latest else False,
            "gpu_memory_used_mb": latest.gpu_memory_used_mb if latest else 0,
            "gpu_memory_total_mb": latest.gpu_memory_total_mb if latest else 0,
            "gpu_utilization": latest.gpu_utilization if latest else 0,
            "heap_status": latest.heap_status if latest else "unknown",
            "thread_count": latest.thread_count if latest else 0,
        }
        if latest
        else {},
        "recent_alerts": [
            {
                "timestamp": a.timestamp,
                "severity": a.severity,
                "category": a.category,
                "message": a.message,
            }
            for a in recent_alerts
        ],
    }


@router.get("/health/recovery")
async def health_recovery_stats() -> dict:
    """Auto-Recovery Statistics — returns auto-recovery system statistics."""
    from auto_recovery import get_auto_recovery

    recovery = get_auto_recovery()

    stats = recovery.get_stats()
    recent_actions = recovery.get_recent_actions(max_count=20)

    return {
        "stats": stats,
        "recent_actions": [
            {
                "timestamp": datetime.fromtimestamp(a.timestamp).isoformat(),
                "problem": a.problem,
                "action": a.action,
                "success": a.success,
                "details": a.details,
            }
            for a in recent_actions
        ],
    }


@router.get("/system/stats")
async def system_stats() -> dict:
    """Return current hardware usage and scheduler recommendations."""
    import python_app.server as _srv

    return _srv._build_system_stats_payload()


@router.post("/system/restart")
async def restart_backend(request: Request) -> dict:
    """Request a backend restart. Interrupts all conversions in progress."""
    import asyncio

    from src._server_job_helpers import (
        _clear_all_caches,
        _clear_all_outputs,
        _purge_all_jobs,
    )

    import python_app.server as _srv

    keep_cache = False
    keep_finished = False
    try:
        body = await request.json()
        if body:
            keep_cache = bool(body.get("keep_cache", False))
            keep_finished = bool(body.get("keep_finished", False))
    except Exception:
        pass  # No body or invalid JSON — use defaults

    _srv._write_restart_marker(keep_cache=keep_cache, keep_finished=keep_finished)
    _srv.logger.warning(
        "Restart requested via API (keep_cache=%s, keep_finished=%s)",
        keep_cache,
        keep_finished,
    )
    purged = _purge_all_jobs(
        "restart requested",
        keep_finished=keep_finished,
        purge_cache=not keep_cache,
    )
    if not keep_finished:
        _clear_all_outputs(preserve_cache=keep_cache)
    if not keep_cache:
        _clear_all_caches()
    asyncio.create_task(_srv._schedule_restart())
    return {
        "status": "restarting",
        "purgedJobs": purged,
        "keptCache": keep_cache,
        "keptFinished": keep_finished,
    }
