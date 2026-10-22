# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_history_routes(_runtime):
    _runtime.cleanup_old_files = _runtime.app.post("/api/cleanup")(_runtime._bind_server_function(_runtime._server_server_history_routes.cleanup_old_files, _runtime.sys.modules[_runtime.__name__]))


    _runtime.get_resumable_jobs = _runtime.app.get("/api/jobs/resumable")(_runtime._bind_server_function(_runtime._server_server_history_routes.get_resumable_jobs, _runtime.sys.modules[_runtime.__name__]))


    _runtime.get_recent_jobs = _runtime.app.get("/api/jobs/recent")(_runtime._bind_server_function(_runtime._server_server_history_routes.get_recent_jobs, _runtime.sys.modules[_runtime.__name__]))


    _runtime.get_job_status = _runtime.app.get("/api/jobs/{job_id}")(_runtime._bind_server_function(_runtime._server_server_history_routes.get_job_status, _runtime.sys.modules[_runtime.__name__]))


    _runtime.stream_job_status = _runtime.app.get("/api/jobs/{job_id}/stream")(_runtime._bind_server_function(_runtime._server_server_history_routes.stream_job_status, _runtime.sys.modules[_runtime.__name__]))
