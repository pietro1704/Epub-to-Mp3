# -*- coding: utf-8 -*-
"""Server chapter scheduler."""

from __future__ import annotations

from pathlib import Path
from typing import Optional


async def _server_chapter_scheduler(_runtime, _state):
    _state.chapter_attempts: dict[int, int] = {}
    _state.retry_forever = _runtime._CHAPTER_RETRY_FOREVER
    _state.max_retry_rounds = _runtime._CHAPTER_RETRY_ROUNDS
    _state.max_chapter_attempts = max(1, 1 + _state.max_retry_rounds)
    _state.max_retry_rounds_label = "unlimited" if _state.retry_forever else str(_state.max_retry_rounds)
    _state.max_chapter_attempts_label = "unlimited" if _state.retry_forever else str(_state.max_chapter_attempts)
    _state.retrying_failed_chapters = False

    def _note_chapter_attempt(chapter_index: int) -> int:
        return _runtime.note_chapter_attempt(_state.chapter_attempts, chapter_index)
    _state._note_chapter_attempt = _note_chapter_attempt

    def _chapter_can_retry(chapter_index: int) -> bool:
        return _runtime.chapter_can_retry(
            _state.chapter_attempts,
            chapter_index,
            retry_forever=_state.retry_forever,
            max_chapter_attempts=_state.max_chapter_attempts,
            retry_forever_max=_runtime._CHAPTER_RETRY_FOREVER_MAX,
        )
    _state._chapter_can_retry = _chapter_can_retry

    def _reset_chapter_progress_tracking(chapter_index: int) -> None:
        _runtime.reset_chapter_progress_tracking(_state.job, chapter_index, len(_state.chapters))
    _state._reset_chapter_progress_tracking = _reset_chapter_progress_tracking

    def _collect_failed_chapters() -> list[tuple[int, object]]:
        return _runtime.collect_failed_chapters(_state.job, _state.chapters)
    _state._collect_failed_chapters = _collect_failed_chapters

    def _expected_output_path(chapter_index: int, chapter_obj) -> Path:
        return _runtime.expected_output_path(_state.job_output_dir, chapter_index, chapter_obj)
    _state._expected_output_path = _expected_output_path

    def _chapter_requires_audio(chapter_obj) -> bool:
        return _runtime.chapter_requires_audio(chapter_obj)
    _state._chapter_requires_audio = _chapter_requires_audio

    def _collect_missing_chapters() -> list[tuple[int, object]]:
        return _runtime.collect_missing_chapters(_state.chapters, _state.job_output_dir)
    _state._collect_missing_chapters = _collect_missing_chapters

    def _sync_soft_failures(failed_indices: set[int]) -> None:
        _runtime.sync_soft_failures(_state.job, failed_indices)
    _state._sync_soft_failures = _sync_soft_failures

    def _mark_retry_round(round_number: int, total_failed: int) -> None:
        _state.requested_slots, _state.parallel_slots, _state.retrying_failed_chapters = _runtime.mark_retry_round(
            _state.job,
            _state.job_id,
            round_number,
            total_failed,
            _state.max_retry_rounds_label,
            _state.edge_configs,
            _state.engine_pool,
        )
        _state._apply_edge_slow_mode("retry for failed chapters")
    _state._mark_retry_round = _mark_retry_round

    async def convert_chapter(
        idx: int, chapter_obj, *, preferred_engine: Optional[str] = None
    ) -> None:
        from src.server_chapter_state import ServerChapterState
        from src.server_chapter_run import _server_chapter_run

        chapter_state = ServerChapterState(
            idx=idx,
            chapter_obj=chapter_obj,
            preferred_engine=preferred_engine,
        )
        flow = await _server_chapter_run(_runtime, _state, chapter_state)
        return flow.value if flow is not None else None
    _state.convert_chapter = convert_chapter

    _runtime._append_event(_state.job, "")
    _runtime._append_event(_state.job, "🚀 Starting chapter conversion...")
    _runtime._persist_job(_state.job_id, force=True)  # Persist before starting conversion

    _state.last_parallel_update = 0.0
    _state.last_health_check = 0.0
    _state.health_check_interval = float(
        _state.job.get("healthCheckIntervalSeconds") or _runtime._HEALTHCHECK_INTERVAL_SECONDS
    )
    _state.health_check_interval = max(10.0, min(300.0, _state.health_check_interval))
    _state.health_slow_edge_cps = float(
        _state.job.get("healthCheckSlowEdgeCps") or _runtime._HEALTHCHECK_SLOW_EDGE_CPS
    )
    _state.health_slow_cps = float(_state.job.get("healthCheckSlowCps") or _runtime._HEALTHCHECK_SLOW_CPS)
    _state.health_high_cpu = float(_state.job.get("healthCheckHighCpu") or _runtime._HEALTHCHECK_HIGH_CPU)
    _state.health_high_mem = float(_state.job.get("healthCheckHighMem") or _runtime._HEALTHCHECK_HIGH_MEM)
    _state.health_ok_cpu = float(_state.job.get("healthCheckOkCpu") or _runtime._HEALTHCHECK_OK_CPU)
    _state.health_ok_mem = float(_state.job.get("healthCheckOkMem") or _runtime._HEALTHCHECK_OK_MEM)
    _state.health_slow_streak_limit = int(_state.job.get("healthCheckSlowStreak") or _runtime._HEALTHCHECK_SLOW_STREAK)
    _state.health_slow_streak_limit = max(1, min(6, _state.health_slow_streak_limit))
    if _state.health_ok_cpu >= _state.health_high_cpu:
        _state.health_ok_cpu = max(10.0, _state.health_high_cpu - 5.0)
    if _state.health_ok_mem >= _state.health_high_mem:
        _state.health_ok_mem = max(10.0, _state.health_high_mem - 5.0)
    _state.slow_streak = 0

    def _compute_parallel_slots() -> int:
        return _runtime.compute_parallel_slots(
            force_sequential=_state.force_sequential,
            retrying_failed_chapters=_state.retrying_failed_chapters,
            requested_slots=_state.requested_slots,
            edge_cap=_state.edge_cap,
            parallel_slots_cap=_state.parallel_slots_cap,
            jobs=_runtime.jobs,
        )
    _state._compute_parallel_slots = _compute_parallel_slots

    def _maybe_adjust_parallel_slots(force: bool = False) -> None:
        now = _runtime.time.time()
        if not force and (now - _state.last_parallel_update) < 3:
            return
        new_slots = _state._compute_parallel_slots()
        if new_slots != _state.parallel_slots:
            _runtime._append_event(_state.job, f"⚙️ Adjusting parallelism {_state.parallel_slots}→{new_slots}")
            _state.parallel_slots = new_slots
            _state.job["parallelSlots"] = new_slots
            _state.engine_pool.update_parallel_slots(new_slots)
            _runtime._persist_job(_state.job_id, force=False)
        _state.last_parallel_update = now
    _state._maybe_adjust_parallel_slots = _maybe_adjust_parallel_slots

    def _resolve_recent_speed(engine_name: str) -> float:
        return _runtime.resolve_recent_speed(_state.job, engine_name)
    _state._resolve_recent_speed = _resolve_recent_speed

    def _maybe_health_check(force: bool = False) -> None:
        now = _runtime.time.time()
        if not force and (now - _state.last_health_check) < _state.health_check_interval:
            return
        _state.last_health_check = now
        stats = _runtime.system_monitor.latest() or {}
        cpu_percent = float((stats.get("cpu") or {}).get("percent") or 0.0)
        mem_percent = float((stats.get("memory") or {}).get("percent") or 0.0)
        engine_label = (
            (_state.active_config.engine if _state.active_config else _state.config.engine)
            or _state.job.get("engine")
            or "auto"
        ).lower()
        recent_speed = _state._resolve_recent_speed(engine_label)
        slow_threshold = _state.health_slow_edge_cps if engine_label == "edge" else _state.health_slow_cps
        is_slow = recent_speed > 0 and slow_threshold > 0 and recent_speed < slow_threshold

        if is_slow:
            _state.slow_streak += 1
        else:
            _state.slow_streak = max(0, _state.slow_streak - 1)

        if _state.slow_streak >= _state.health_slow_streak_limit and engine_label == "edge":
            if not _state.edge_slow_mode:
                _state._apply_edge_slow_mode(f"healthcheck low speed ({recent_speed:.1f} chars/s)")
            else:
                # Keep Edge in safe mode on speed-only regressions. Permanent
                # disable is reserved for consecutive hard failures such as
                # timeouts, so the job can continue benefiting from Edge when
                # the slowdown is transient or chapter-specific.
                if not _state.job.get("_edgePersistentSlowNoted"):
                    _state.job["_edgePersistentSlowNoted"] = True
                    _runtime._append_event(
                        _state.job,
                        f"🐢 Edge still slow in safe mode ({recent_speed:.1f} chars/s)"
                        " — keeping Edge enabled until a hard timeout proves it unhealthy",
                    )
        elif (
            _state.slow_streak >= _state.health_slow_streak_limit
            and _state.parallel_slots > 1
            and (cpu_percent > _state.health_high_cpu or mem_percent > _state.health_high_mem)
        ):
            new_slots = max(1, _state.parallel_slots - 1)
            if new_slots != _state.parallel_slots:
                _runtime._append_event(
                    _state.job, f"🧪 Healthcheck: reducing parallelism {_state.parallel_slots}→{new_slots}"
                )
                _state.parallel_slots = new_slots
                _state.job["parallelSlots"] = new_slots
                _state.engine_pool.update_parallel_slots(new_slots)

        # Only raise parallelism when not in a slow period and enough time has
        # passed since the last adjustment (shared cooldown with
        # _maybe_adjust_parallel_slots to prevent oscillation).
        _PARALLEL_RAISE_COOLDOWN = 30.0
        if (
            _state.slow_streak == 0
            and cpu_percent < _state.health_ok_cpu
            and mem_percent < _state.health_ok_mem
            and not _state.force_sequential
            and (now - _state.last_parallel_update) >= _PARALLEL_RAISE_COOLDOWN
        ):
            desired = _state._compute_parallel_slots()
            if desired != _state.parallel_slots:
                _runtime._append_event(
                    _state.job, f"🧪 Healthcheck: adjusting parallelism {_state.parallel_slots}→{desired}"
                )
                _state.parallel_slots = desired
                _state.job["parallelSlots"] = desired
                _state.engine_pool.update_parallel_slots(desired)
                _state.last_parallel_update = now
        _runtime._persist_job(_state.job_id, force=False)
    _state._maybe_health_check = _maybe_health_check

    _state.pending_chapters = [
        (idx, chapter)
        for idx, chapter in enumerate(_state.chapters, 1)
        if idx not in _state.completed_indices
    ]
    _state.priority_chapter_index = _state.job.get("priorityChapterIndex")
    if isinstance(_state.priority_chapter_index, int) and _state.priority_chapter_index >= 0:
        _state.priority_one_based = _state.priority_chapter_index + 1
        if any(idx == _state.priority_one_based for idx, _ in _state.pending_chapters):
            _state.pivot = next(
                i for i, (idx, _) in enumerate(_state.pending_chapters) if idx == _state.priority_one_based
            )
            _state.pending_chapters = _state.pending_chapters[_state.pivot:] + _state.pending_chapters[:_state.pivot]

    # Compute multi-engine slot affinity for the first pass.
    # Affinity maps each physical slot to an engine so Edge and a local engine
    # run simultaneously from chapter 1 rather than waiting for fallback.
    if _state._multi_engine_requested and not _state.auto_mode and not _state.force_sequential:
        _state._me_raw = [
            (candidate.engine or "").lower()
            for candidate in _state.engine_chain
            if (candidate.engine or "").lower() in _state.registered_engines
            and (candidate.engine or "").lower() not in _state.unavailable_engines
        ]
        _state._me_seen: set[str] = set()
        _state._me_engines: list[str] = []
        for _state._e in _state._me_raw:
            if _state._e and _state._e not in _state._me_seen:
                _state._me_seen.add(_state._e)
                _state._me_engines.append(_state._e)
        # Dynamic edge fraction: proportional to relative telemetry speed so
        # the faster engine gets more slots automatically.
        _state._edge_spd = float(
            (_runtime.telemetry.summary().get("edge") or {}).get("avg_chars_per_second") or 0.0
        )
        _state._local_spds = [
            float((_runtime.telemetry.summary().get(e) or {}).get("avg_chars_per_second") or 0.0)
            for e in _state._me_engines[1:]
        ]
        _state._best_local = max(_state._local_spds) if _state._local_spds else 0.0
        if _state._edge_spd > 0 and _state._best_local > 0:
            _state._edge_frac = _state._edge_spd / (_state._edge_spd + _state._best_local)
            _state._edge_frac = max(0.50, min(0.85, _state._edge_frac))
        else:
            _state._edge_frac = float(_runtime.os.getenv("MULTI_ENGINE_EDGE_FRACTION", "0.67"))
        _state.slot_affinity = _runtime._build_multi_engine_slot_map(
            _state.parallel_slots,
            _state._me_engines,
            edge_fraction=_state._edge_frac,
        )
        if _state.slot_affinity:
            _state.counts = {e: _state.slot_affinity.count(e) for e in dict.fromkeys(_state.slot_affinity)}
            _runtime._append_event(
                _state.job,
                "⚡ Multi-engine parallel: " + ", ".join(f"{e}×{n}" for e, n in _state.counts.items()),
            )

    _state.retry_round = 0
