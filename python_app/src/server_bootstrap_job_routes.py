# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_job_routes(_runtime):
    _runtime.cancel_job = _runtime.app.post("/api/jobs/{job_id}/cancel")(_runtime._bind_server_function(_runtime._server_server_job_routes.cancel_job, _runtime.sys.modules[_runtime.__name__]))


    _runtime.record_journey_observation = _runtime.app.post("/api/jobs/{job_id}/journey-observations")(_runtime._bind_server_function(_runtime._server_server_job_routes.record_journey_observation, _runtime.sys.modules[_runtime.__name__]))


    _runtime.resume_job = _runtime.app.post("/api/jobs/{job_id}/resume")(_runtime._bind_server_function(_runtime._server_server_job_routes.resume_job, _runtime.sys.modules[_runtime.__name__]))


    _runtime.delete_job = _runtime.app.delete("/api/jobs/{job_id}")(_runtime._bind_server_function(_runtime._server_server_job_routes.delete_job, _runtime.sys.modules[_runtime.__name__]))


    _runtime.get_job_log = _runtime.app.get("/api/jobs/{job_id}/log")(_runtime._bind_server_function(_runtime._server_server_job_routes.get_job_log, _runtime.sys.modules[_runtime.__name__]))
