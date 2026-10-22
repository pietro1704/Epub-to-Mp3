# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_event_policy(_runtime):
    _runtime._sanitize_event_message = _runtime._bind_server_function(_runtime._server_server_job_events._sanitize_event_message, _runtime.sys.modules[_runtime.__name__])


    _runtime._segment_idle_watchdog = _runtime._bind_server_function(_runtime._server_server_job_events._segment_idle_watchdog, _runtime.sys.modules[_runtime.__name__])


    _runtime._update_job_activity = _runtime._bind_server_function(_runtime._server_server_job_events._update_job_activity, _runtime.sys.modules[_runtime.__name__])


    _runtime._append_event = _runtime._bind_server_function(_runtime._server_server_job_events._append_event, _runtime.sys.modules[_runtime.__name__])


    _runtime._apply_server_silence_padding = _runtime._bind_server_function(_runtime._server_server_job_events._apply_server_silence_padding, _runtime.sys.modules[_runtime.__name__])


    _runtime._SSE_RAW_LOG_CAP = 200  # Limit rawLog in SSE payloads to avoid large messages


    _runtime._broadcast_sse_event = _runtime._bind_server_function(_runtime._server_server_job_events._broadcast_sse_event, _runtime.sys.modules[_runtime.__name__])


    _runtime._schedule_job_broadcast = _runtime._bind_server_function(_runtime._server_server_job_events._schedule_job_broadcast, _runtime.sys.modules[_runtime.__name__])


    _runtime._broadcast_chapter_event = _runtime._bind_server_function(_runtime._server_server_job_events._broadcast_chapter_event, _runtime.sys.modules[_runtime.__name__])


    _runtime._schedule_chapter_broadcast = _runtime._bind_server_function(_runtime._server_server_job_events._schedule_chapter_broadcast, _runtime.sys.modules[_runtime.__name__])


    _runtime._job_status_payload = _runtime._bind_server_function(_runtime._server_server_job_events._job_status_payload, _runtime.sys.modules[_runtime.__name__])
