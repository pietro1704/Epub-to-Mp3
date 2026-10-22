# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_monitor_state(_runtime):
    _runtime.system_monitor = _runtime._FallbackSystemMonitor()  # Will be replaced with real monitor on startup

    if _runtime.FORCE_TURBO:
        # Turbo scales parallelism within a job, not simultaneous books.
        # Cap job workers at MAX_CONCURRENT_BOOKS (default 1).
        _runtime.desired_workers = min(max(2, _runtime._hardware_profile.cpu_physical or 1), _runtime.MAX_CONCURRENT_BOOKS)
        if _runtime.desired_workers > _runtime._JOB_WORKERS:
            _runtime.logger.warning(
                f"Turbo mode: increasing job workers from {_runtime._JOB_WORKERS} to {_runtime.desired_workers}"
            )
            _runtime._JOB_WORKERS = _runtime.desired_workers
