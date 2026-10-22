# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_retention(_runtime):
    _runtime._hf_keepalive = _runtime._bind_server_function(_runtime._server_server_retention._hf_keepalive, _runtime.sys.modules[_runtime.__name__])


    _runtime._periodic_job_cleanup = _runtime._bind_server_function(_runtime._server_server_retention._periodic_job_cleanup, _runtime.sys.modules[_runtime.__name__])


    _runtime._job_state_counts = _runtime._bind_server_function(_runtime._server_server_retention._job_state_counts, _runtime.sys.modules[_runtime.__name__])


    _runtime._has_active_jobs = _runtime._bind_server_function(_runtime._server_server_retention._has_active_jobs, _runtime.sys.modules[_runtime.__name__])


    _runtime._cleanup_telemetry_artifacts = _runtime._bind_server_function(_runtime._server_server_retention._cleanup_telemetry_artifacts, _runtime.sys.modules[_runtime.__name__])


    _runtime._latest_segment_summary = _runtime._bind_server_function(_runtime._server_server_retention._latest_segment_summary, _runtime.sys.modules[_runtime.__name__])


    _runtime._feature_ab_history_path = _runtime._bind_server_function(_runtime._server_server_retention._feature_ab_history_path, _runtime.sys.modules[_runtime.__name__])
