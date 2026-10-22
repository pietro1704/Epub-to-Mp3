# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_recovery(_runtime):
    _runtime._normalize_book_title = _runtime._bind_server_function(_runtime._server_server_job_recovery._normalize_book_title, _runtime.sys.modules[_runtime.__name__])


    _runtime._safe_file_size = _runtime._bind_server_function(_runtime._server_server_job_recovery._safe_file_size, _runtime.sys.modules[_runtime.__name__])


    _runtime._guess_image_mime = _runtime._bind_server_function(_runtime._server_server_job_recovery._guess_image_mime, _runtime.sys.modules[_runtime.__name__])


    _runtime._find_cover_asset = _runtime._bind_server_function(_runtime._server_server_job_recovery._find_cover_asset, _runtime.sys.modules[_runtime.__name__])


    _runtime._locate_job_output_dir_for_recovery = _runtime._bind_server_function(_runtime._server_server_job_recovery._locate_job_output_dir_for_recovery, _runtime.sys.modules[_runtime.__name__])


    _runtime._restore_job_from_outputs = _runtime._bind_server_function(_runtime._server_server_job_recovery._restore_job_from_outputs, _runtime.sys.modules[_runtime.__name__])


    _runtime._resolve_job_activity_timestamp = _runtime._bind_server_function(_runtime._server_server_job_recovery._resolve_job_activity_timestamp, _runtime.sys.modules[_runtime.__name__])


    _runtime._summarize_recent_job = _runtime._bind_server_function(_runtime._server_server_job_recovery._summarize_recent_job, _runtime.sys.modules[_runtime.__name__])


    _runtime._collect_recent_job_entries = _runtime._bind_server_function(_runtime._server_server_job_recovery._collect_recent_job_entries, _runtime.sys.modules[_runtime.__name__])
