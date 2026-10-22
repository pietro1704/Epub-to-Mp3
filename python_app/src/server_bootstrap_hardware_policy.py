# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_hardware_policy(_runtime):
    _runtime._perf_profile_env = (_runtime.os.getenv("PERF_PROFILE") or "auto").strip().lower()
    if _runtime._perf_profile_env not in {"auto", "hf", "local", "cli"}:
        _runtime._perf_profile_env = "auto"
    _runtime._perf_profile = _runtime._infer_perf_profile(
        _runtime._hardware_profile, _runtime._perf_profile_env, bool(_runtime.os.getenv("SPACE_ID"))
    )
    _runtime._apply_perf_defaults(_runtime._perf_profile, _runtime._hardware_profile)

    # Research-based: 4 concurrent default (safe: 2-4, >8 causes 403)
    _runtime.edge_recommended = max(2, min(6, int(_runtime._hardware_profile.recommended_concurrency or 4)))
    if _runtime._perf_profile == "hf":
        _runtime.edge_recommended = min(_runtime.edge_recommended, 3)
    elif _runtime._perf_profile == "cli":
        _runtime.edge_recommended = min(8, max(_runtime.edge_recommended, (_runtime._hardware_profile.cpu_physical or 2) * 2))
    if _runtime.FORCE_TURBO:
        _runtime.edge_recommended = max(
            _runtime.edge_recommended, (_runtime._hardware_profile.cpu_physical or 2) * _runtime.TURBO_SLOT_MULTIPLIER
        )
    if not _runtime.os.getenv("EDGE_MAX_CONCURRENCY"):
        _runtime.os.environ["EDGE_MAX_CONCURRENCY"] = str(_runtime.edge_recommended)
    _runtime.logger.info(
        f"Hardware auto-detected: {_runtime._hardware_profile.performance_tier} tier, "
        f"EDGE_MAX_CONCURRENCY={_runtime.os.getenv('EDGE_MAX_CONCURRENCY')} "
        f"{'(turbo mode)' if _runtime.FORCE_TURBO else ''} (perf_profile={_runtime._perf_profile})"
    )

    try:
        _runtime._PARALLEL_SLOTS_DEFAULT = max(
            1,
            int(
                _runtime.os.getenv("CHAPTER_PARALLEL_COUNT")
                or getattr(_runtime._hardware_profile, "recommended_chapter_parallel", 1)
                or 1
            ),
        )
    except (TypeError, ValueError):
        _runtime._PARALLEL_SLOTS_DEFAULT = max(
            1, getattr(_runtime._hardware_profile, "recommended_chapter_parallel", 1) or 1
        )
    if _runtime.FORCE_TURBO:
        _runtime.turbo_parallel = max(
            _runtime._PARALLEL_SLOTS_DEFAULT,
            (_runtime._hardware_profile.cpu_physical or 1) * _runtime.TURBO_SLOT_MULTIPLIER,
            4,
        )
        _runtime._PARALLEL_SLOTS_DEFAULT = _runtime.turbo_parallel

    _runtime._CHAPTER_PARALLEL_MAX = max(
        _runtime._PARALLEL_SLOTS_DEFAULT,
        int(_runtime.os.getenv("CHAPTER_PARALLEL_MAX", str(max(4, _runtime._PARALLEL_SLOTS_DEFAULT))))
        or _runtime._PARALLEL_SLOTS_DEFAULT,
    )
    if _runtime.FORCE_TURBO:
        _runtime._CHAPTER_PARALLEL_MAX = max(
            _runtime._CHAPTER_PARALLEL_MAX,
            (_runtime._hardware_profile.cpu_physical or 1) * (_runtime.TURBO_SLOT_MULTIPLIER + 1),
            6,
        )

    _runtime._WORKER_CAP = max(
        1,
        min(
            _runtime.WORKER_MAX,
            _runtime.MAX_CONCURRENT_BOOKS,
            max(2, (_runtime._hardware_profile.cpu_physical or 1) * _runtime.TURBO_SLOT_MULTIPLIER),
        ),
    )

    # Apply profile-specific caps after base calculations to avoid starvation on HF
    if _runtime._perf_profile == "hf":
        _runtime._PARALLEL_SLOTS_DEFAULT = min(_runtime._PARALLEL_SLOTS_DEFAULT, 2)
        _runtime._CHAPTER_PARALLEL_MAX = min(_runtime._CHAPTER_PARALLEL_MAX, 3)
        _runtime._WORKER_CAP = min(_runtime._WORKER_CAP, max(2, (_runtime._hardware_profile.cpu_physical or 1)))
        _runtime.os.environ.setdefault("EDGE_MAX_CONCURRENCY_CAP", "4")
    elif _runtime._perf_profile == "cli":
        _runtime._PARALLEL_SLOTS_DEFAULT = max(
            _runtime._PARALLEL_SLOTS_DEFAULT, min(4, (_runtime._hardware_profile.cpu_physical or 1) * 2)
        )
        _runtime._CHAPTER_PARALLEL_MAX = max(_runtime._CHAPTER_PARALLEL_MAX, min(6, _runtime._PARALLEL_SLOTS_DEFAULT + 1))
        _runtime._WORKER_CAP = min(max(_runtime._WORKER_CAP, (_runtime._hardware_profile.cpu_physical or 1) * 2), _runtime.WORKER_MAX)

    # Background task for periodic job cleanup
    _runtime._cleanup_task: _runtime.Optional[_runtime.asyncio.Task] = None
    _runtime.__dict__.setdefault("__annotations__", {})['_cleanup_task'] = 'Optional[asyncio.Task]'
    _runtime._job_watchdog_task: _runtime.Optional[_runtime.asyncio.Task] = None
    _runtime.__dict__.setdefault("__annotations__", {})['_job_watchdog_task'] = 'Optional[asyncio.Task]'
    _runtime._auto_tuner: _runtime.Optional[_runtime.AutoTuner] = None  # Will be initialized on startup
    _runtime.__dict__.setdefault("__annotations__", {})['_auto_tuner'] = 'Optional[AutoTuner]'
