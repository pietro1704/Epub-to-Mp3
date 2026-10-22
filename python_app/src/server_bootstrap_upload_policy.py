# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_upload_policy(_runtime):
    _runtime._env_float = _runtime._bind_server_function(_runtime._server_server_pending_uploads._env_float, _runtime.sys.modules[_runtime.__name__])


    _runtime._env_int = _runtime._bind_server_function(_runtime._server_server_pending_uploads._env_int, _runtime.sys.modules[_runtime.__name__])


    _runtime._HEALTHCHECK_INTERVAL_SECONDS = _runtime._env_float("JOB_HEALTHCHECK_INTERVAL_SECONDS", 15.0)  # was 30s
    _runtime._HEALTHCHECK_SLOW_EDGE_CPS = _runtime._env_float("JOB_HEALTHCHECK_SLOW_EDGE_CPS", _runtime.EDGE_MIN_CHARS_PER_SECOND)
    _runtime._HEALTHCHECK_SLOW_CPS = _runtime._env_float("JOB_HEALTHCHECK_SLOW_CPS", 30.0)
    _runtime._HEALTHCHECK_HIGH_CPU = _runtime._env_float("JOB_HEALTHCHECK_HIGH_CPU_PERCENT", 85.0)
    _runtime._HEALTHCHECK_HIGH_MEM = _runtime._env_float("JOB_HEALTHCHECK_HIGH_MEM_PERCENT", 85.0)
    _runtime._HEALTHCHECK_OK_CPU = _runtime._env_float("JOB_HEALTHCHECK_OK_CPU_PERCENT", 75.0)
    _runtime._HEALTHCHECK_OK_MEM = _runtime._env_float("JOB_HEALTHCHECK_OK_MEM_PERCENT", 80.0)
    _runtime._HEALTHCHECK_SLOW_STREAK = max(1, _runtime._env_int("JOB_HEALTHCHECK_SLOW_STREAK", 1))  # was 2
    _runtime._app_loop: _runtime.Optional[_runtime.asyncio.AbstractEventLoop] = None
    _runtime.__dict__.setdefault("__annotations__", {})['_app_loop'] = 'Optional[asyncio.AbstractEventLoop]'


    _runtime._resolve_max_chapter_limit = _runtime._bind_server_function(_runtime._server_server_pending_uploads._resolve_max_chapter_limit, _runtime.sys.modules[_runtime.__name__])


    _runtime.MAX_CHAPTERS_PER_JOB = _runtime._resolve_max_chapter_limit()
    # Skip chapters larger than this (0 = disabled). Prevents footnote-container files
    # that embed the entire book text from blocking conversion for hours.
    _runtime.MAX_CHAPTER_CHARS = _runtime._env_int("MAX_CHAPTER_CHARS", 0)


    _runtime._cleanup_pending_uploads = _runtime._bind_server_function(_runtime._server_server_pending_uploads._cleanup_pending_uploads, _runtime.sys.modules[_runtime.__name__])


    _runtime._write_pending_upload_metadata = _runtime._bind_server_function(_runtime._server_server_pending_uploads._write_pending_upload_metadata, _runtime.sys.modules[_runtime.__name__])


    _runtime._load_pending_upload_from_disk = _runtime._bind_server_function(_runtime._server_server_pending_uploads._load_pending_upload_from_disk, _runtime.sys.modules[_runtime.__name__])


    _runtime._enforce_chapter_limit = _runtime._bind_server_function(_runtime._server_server_pending_uploads._enforce_chapter_limit, _runtime.sys.modules[_runtime.__name__])
