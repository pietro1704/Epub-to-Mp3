# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_job_index(_runtime):
    _runtime._ensure_job = _runtime._bind_server_function(_runtime._server_server_job_queue._ensure_job, _runtime.sys.modules[_runtime.__name__])


    _runtime._enqueue_job = _runtime._bind_server_function(_runtime._server_server_job_queue._enqueue_job, _runtime.sys.modules[_runtime.__name__])


    _runtime._schedule_job_conversion = _runtime._bind_server_function(_runtime._server_server_job_queue._schedule_job_conversion, _runtime.sys.modules[_runtime.__name__])


    _runtime._job_worker = _runtime._bind_server_function(_runtime._server_server_job_queue._job_worker, _runtime.sys.modules[_runtime.__name__])


    _runtime._resume_pending_jobs = _runtime._bind_server_function(_runtime._server_server_job_queue._resume_pending_jobs, _runtime.sys.modules[_runtime.__name__])


    # Load existing jobs from disk on startup
    _runtime.jobs: _runtime.Dict[str, dict] = _runtime.job_manager.load_all_jobs()
    _runtime.__dict__.setdefault("__annotations__", {})['jobs'] = 'Dict[str, dict]'
    _runtime.logger.info(f"Loaded {len(_runtime.jobs)} jobs from disk")

    # **OPTIMIZATION #1**: Create lightweight index for recent jobs API
    # Maps job_id -> (savedAt timestamp, bookTitle) for fast sorting without loading full job data
    _runtime._recent_jobs_index: _runtime.Dict[str, tuple[str, str]] = {}
    _runtime.__dict__.setdefault("__annotations__", {})['_recent_jobs_index'] = 'Dict[str, tuple[str, str]]'

    # **OPTIMIZATION #1**: Populate index from loaded jobs
    for _runtime.job_id, _runtime.job_data in _runtime.jobs.items():
        _runtime.state = (_runtime.job_data.get("state") or "").lower()
        if _runtime.state == "cancelled":
            continue
        _runtime.saved_at = _runtime._determine_saved_at(_runtime.job_data)
        _runtime.book_title = _runtime.job_data.get("bookTitle") or "Unknown"
        _runtime._recent_jobs_index[_runtime.job_id] = (_runtime.saved_at, _runtime.book_title)

    # **OPTIMIZATION #3**: Server-Sent Events (SSE) support
    # Maps job_id -> set of asyncio queues for SSE clients
    _runtime._sse_clients: _runtime.Dict[str, set[_runtime.asyncio.Queue]] = {}
    _runtime.__dict__.setdefault("__annotations__", {})['_sse_clients'] = 'Dict[str, set[asyncio.Queue]]'

    # Auto-detect hardware and optimize
    _runtime._hardware_profile = _runtime.HardwareDetector.detect()
    _runtime.HardwareDetector.apply_optimizations(_runtime._hardware_profile)
