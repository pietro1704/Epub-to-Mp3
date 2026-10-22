# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_resume_policy(_runtime):
    _runtime._summarize_resume_job = _runtime._bind_server_function(_runtime._server_server_resume_summary._summarize_resume_job, _runtime.sys.modules[_runtime.__name__])


    _runtime._resolve_completed_iso = _runtime._bind_server_function(_runtime._server_server_resume_summary._resolve_completed_iso, _runtime.sys.modules[_runtime.__name__])


    _runtime._determine_saved_at = _runtime._bind_server_function(_runtime._server_server_resume_summary._determine_saved_at, _runtime.sys.modules[_runtime.__name__])


    _runtime._resolve_chapter_timeout = _runtime._bind_server_function(_runtime._server_server_resume_summary._resolve_chapter_timeout, _runtime.sys.modules[_runtime.__name__])


    _runtime._collect_resumable_job_entries = _runtime._bind_server_function(_runtime._server_server_resume_summary._collect_resumable_job_entries, _runtime.sys.modules[_runtime.__name__])


    _runtime._EVENT_PREFIXES = (
        "⚠️",
        "✅",
        "🔄",
        "🔗",
        "🎯",
        "📝",
        "🚀",
        "🔧",
        "📚",
        "📜",
        "✍️",
        "🔁",
        "🖼️",
        "📦",
        "☁️",
        "ℹ️",
        "⏱️",
        "🔁",
        "🛑",
        "❌",
        "📊",
        "🎙️",
        "🗣️",
        "🔄",
        "⚡",
        "↳",
        "🔒",
        "📦",
        "📁",
    )
