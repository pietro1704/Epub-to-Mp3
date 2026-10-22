# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_runtime_health(_runtime):
    _runtime._estimate_recommendations = _runtime._bind_server_function(_runtime._server_server_runtime_health._estimate_recommendations, _runtime.sys.modules[_runtime.__name__])


    _runtime._determine_parallel_slots = _runtime._bind_server_function(_runtime._server_server_runtime_health._determine_parallel_slots, _runtime.sys.modules[_runtime.__name__])


    _runtime._build_system_stats_payload = _runtime._bind_server_function(_runtime._server_server_runtime_health._build_system_stats_payload, _runtime.sys.modules[_runtime.__name__])


    _runtime._handle_stalled_job = _runtime._bind_server_function(_runtime._server_server_runtime_health._handle_stalled_job, _runtime.sys.modules[_runtime.__name__])


    _runtime._detect_stalled_jobs = _runtime._bind_server_function(_runtime._server_server_runtime_health._detect_stalled_jobs, _runtime.sys.modules[_runtime.__name__])


    _runtime._job_watchdog = _runtime._bind_server_function(_runtime._server_server_runtime_health._job_watchdog, _runtime.sys.modules[_runtime.__name__])


    _runtime._scale_worker_pool = _runtime._bind_server_function(_runtime._server_server_runtime_health._scale_worker_pool, _runtime.sys.modules[_runtime.__name__])


    _runtime._schedule_restart = _runtime._bind_server_function(_runtime._server_server_runtime_health._schedule_restart, _runtime.sys.modules[_runtime.__name__])


    # Mark jobs as interrupted if they were running/queued (server restart)
    # IMPORTANT: On HF Spaces, /tmp is cleared on restart, so source files are lost.
    # Jobs that were in progress cannot be resumed without the source file.
    # Future enhancement: Save EPUB to R2 for resume capability.
    if not _runtime._skip_resume_on_startup:
        for _runtime.job_id, _runtime.job_data in _runtime.jobs.items():
            _runtime.state = _runtime.job_data.get("state", "")
            _runtime.job_data.setdefault("cancelRequested", False)
            if _runtime.state in ("queued", "running"):
                # Check if the source file still exists
                _runtime.file_path = _runtime.job_data.get("file_path")
                if _runtime.file_path and not _runtime.Path(_runtime.file_path).exists():
                    # Source file was lost (server restart), mark as interrupted
                    _runtime.job_data["state"] = "interrupted"
                    _runtime.job_data["error"] = (
                        "Conversion interrupted (server restarted and temporary source file was lost)"
                    )
                    _runtime.job_data["events"] = _runtime.job_data.get("events", []) + [
                        "",
                        "⚠️ Conversion interrupted due to server restart",
                        "❌ Source file was lost - resume is not possible",
                        "ℹ️ To avoid this, wait for conversion to finish before leaving",
                    ]
                    _runtime.job_manager.save_job(_runtime.job_id, _runtime.job_data)
                    _runtime.logger.warning(f"Job {_runtime.job_id} marked as interrupted (source file lost)")

    _runtime.tts_factory = _runtime.TTSFactory()
    _runtime.telemetry = _runtime.TelemetryRecorder()
    _runtime.MAX_UPLOAD_MB = int(_runtime.os.getenv("MAX_UPLOAD_MB", "100"))
    _runtime.MAX_UPLOAD_BYTES = _runtime.MAX_UPLOAD_MB * 1024 * 1024
