# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_output_policy(_runtime):
    _runtime._store_cover_in_cache = _runtime._bind_server_function(_runtime._server_server_output_policy._store_cover_in_cache, _runtime.sys.modules[_runtime.__name__])


    _runtime._should_retry_edge_before_fallback = _runtime._bind_server_function(_runtime._server_server_output_policy._should_retry_edge_before_fallback, _runtime.sys.modules[_runtime.__name__])


    _runtime._engine_is_disabled = _runtime._bind_server_function(_runtime._server_server_output_policy._engine_is_disabled, _runtime.sys.modules[_runtime.__name__])


    _runtime._persist_job_log = _runtime._bind_server_function(_runtime._server_server_output_policy._persist_job_log, _runtime.sys.modules[_runtime.__name__])
