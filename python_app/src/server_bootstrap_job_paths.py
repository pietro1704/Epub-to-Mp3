# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_job_paths(_runtime):
    _runtime._book_slug = _runtime._bind_server_function(_runtime._server_server_job_paths._book_slug, _runtime.sys.modules[_runtime.__name__])


    _runtime._VALID_JOB_ID_RE = _runtime.re.compile(r"^[a-zA-Z0-9_\-]{1,64}$")


    _runtime._validate_job_id = _runtime._bind_server_function(_runtime._server_server_job_paths._validate_job_id, _runtime.sys.modules[_runtime.__name__])


    _runtime._resolve_path_within_root = _runtime._bind_server_function(_runtime._server_server_job_paths._resolve_path_within_root, _runtime.sys.modules[_runtime.__name__])


    _runtime._resolve_relative_path_within_root = _runtime._bind_server_function(_runtime._server_server_job_paths._resolve_relative_path_within_root, _runtime.sys.modules[_runtime.__name__])


    _runtime._job_source_roots = _runtime._bind_server_function(_runtime._server_server_job_paths._job_source_roots, _runtime.sys.modules[_runtime.__name__])


    _runtime._resolve_job_source_path = _runtime._bind_server_function(_runtime._server_server_job_paths._resolve_job_source_path, _runtime.sys.modules[_runtime.__name__])


    _runtime._server_dedup_chapter_outputs = _runtime._bind_server_function(_runtime._server_server_output_policy._server_dedup_chapter_outputs, _runtime.sys.modules[_runtime.__name__])


    _runtime._safe_leaf_name = _runtime._bind_server_function(_runtime._server_server_job_paths._safe_leaf_name, _runtime.sys.modules[_runtime.__name__])


    _runtime._job_output_dir = _runtime._bind_server_function(_runtime._server_server_job_paths._job_output_dir, _runtime.sys.modules[_runtime.__name__])


    _runtime._job_stream_dir = _runtime._bind_server_function(_runtime._server_server_job_paths._job_stream_dir, _runtime.sys.modules[_runtime.__name__])
