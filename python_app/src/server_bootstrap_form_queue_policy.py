# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_form_queue_policy(_runtime):
    _runtime._parse_form_bool = _runtime._bind_server_function(_runtime._server_server_form_values._parse_form_bool, _runtime.sys.modules[_runtime.__name__])


    _runtime._parse_form_optional_bool = _runtime._bind_server_function(_runtime._server_server_form_values._parse_form_optional_bool, _runtime.sys.modules[_runtime.__name__])


    _runtime._parse_form_int = _runtime._bind_server_function(_runtime._server_server_form_values._parse_form_int, _runtime.sys.modules[_runtime.__name__])


    _runtime._parse_form_float = _runtime._bind_server_function(_runtime._server_server_form_values._parse_form_float, _runtime.sys.modules[_runtime.__name__])


    _runtime._normalize_locale = _runtime._bind_server_function(_runtime._server_server_form_values._normalize_locale, _runtime.sys.modules[_runtime.__name__])


    _runtime._utcnow_iso = _runtime._bind_server_function(_runtime._server_server_form_values._utcnow_iso, _runtime.sys.modules[_runtime.__name__])


    _runtime.output_dir = _runtime.OUTPUT_DIR
    _runtime.persistent_root = _runtime.PERSISTENT_ROOT

    _runtime.uploads_dir = _runtime.UPLOADS_DIR
    _runtime.job_inputs_dir = _runtime.JOB_INPUTS_DIR
    _runtime.source_backups_dir = _runtime.SOURCE_BACKUPS_DIR

    # Persistent cache for extracted chapter texts — survives restarts
    _runtime.persistent_cache_dir = _runtime.CACHE_DIR
    _runtime.persistent_cache_dir.mkdir(exist_ok=True, parents=True)

    # CacheManager singleton with persistent directory
    _runtime._persistent_cache_manager: _runtime.Optional[_runtime.CacheManager] = None
    _runtime.__dict__.setdefault("__annotations__", {})['_persistent_cache_manager'] = 'Optional[CacheManager]'
