# -*- coding: utf-8 -*-
"""Chapter synthesis fallback."""

from __future__ import annotations

from .conversion_control import ConversionControl as _ConversionControl


async def _chapter_synthesis_fallback(self, _state):
    from . import converter as _runtime
    if (
        _runtime.ENGINE_SLOW_FALLBACK_ENABLED
        and _state.is_auto_engine
        and _state.auto_order
        and len(_state.auto_order) > 1
    ):
        _state.network_hint = (
            str(
                getattr(
                    getattr(self, "hardware_profile", None),
                    "network_speed_estimate",
                    "",
                )
                or ""
            )
            .strip()
            .lower()
        )
        _state.avoid_edge_due_network = _state.network_hint in {
            "slow",
            "unknown",
            "unstable",
        }
        _state.current_is_local = (_state.current_engine_label or "").lower() in {
            "piper",
        }
        _state.skip_slow_switch = (
            _state.current_is_local
            and _state.chapter_chars >= _runtime.EDGE_PREDICTIVE_TIMEOUT_CHARS
            and _state.avoid_edge_due_network
        )

        async def _watch_slow_engine() -> None:
            min_slow = max(30, int(_runtime.ENGINE_SLOW_FALLBACK_MIN_SECONDS))
            timeout_ratio = float(_runtime.ENGINE_SLOW_FALLBACK_TIMEOUT_RATIO)
            timeout_ratio = max(0.15, min(timeout_ratio, 0.9))
            trigger_after = max(
                min_slow, int(_state.timeout_seconds * timeout_ratio)
            )
            # New guard: even with partial progress, switch engine if
            # no new segment/chunk arrives for too long.
            no_progress_ratio = float(
                _runtime.os.getenv("ENGINE_SLOW_NO_PROGRESS_RATIO", "0.22") or "0.22"
            )
            no_progress_ratio = max(0.10, min(no_progress_ratio, 0.75))
            no_progress_after = max(
                min_slow,
                int(_state.timeout_seconds * no_progress_ratio),
            )
            last_hits = int(_state.segment_progress_state["hits"])
            last_progress_at = _runtime.time.time()
            hard_elapsed_ratio = float(
                _runtime.os.getenv("ENGINE_SLOW_HARD_ELAPSED_RATIO", "0.55")
                or "0.55"
            )
            hard_elapsed_ratio = max(0.25, min(hard_elapsed_ratio, 0.95))
            hard_elapsed_limit = max(
                min_slow * 2,
                int(_state.timeout_seconds * hard_elapsed_ratio),
            )
            while True:
                await _runtime.asyncio.sleep(5)
                if _state.synthesis_task.done():
                    return
                elapsed_s = int(_runtime.time.time() - _state.start_synthesis)
                current_hits = int(_state.segment_progress_state["hits"])
                now_ts = _runtime.time.time()
                if current_hits > last_hits:
                    last_hits = current_hits
                    last_progress_at = now_ts
                idle_for = int(max(0.0, now_ts - last_progress_at))
                if elapsed_s < trigger_after:
                    continue
                # Original behavior: no segment progress at all.
                if current_hits <= 0:
                    _state.slow_switch_event.set()
                    with _runtime.contextlib.suppress(Exception):
                        _state.synthesis_task.cancel()
                    return
                # New behavior: progress exists but became too sparse/stalled.
                if idle_for >= no_progress_after:
                    _state.slow_switch_event.set()
                    with _runtime.contextlib.suppress(Exception):
                        _state.synthesis_task.cancel()
                    return
                # Safety valve for very long elapsed time with weak progress.
                if elapsed_s >= hard_elapsed_limit and current_hits < 4:
                    _state.slow_switch_event.set()
                    with _runtime.contextlib.suppress(Exception):
                        _state.synthesis_task.cancel()
                    return
        _state._watch_slow_engine = _watch_slow_engine

        if not _state.skip_slow_switch:
            _state.slow_task = _runtime.asyncio.create_task(_state._watch_slow_engine())
    try:
        _state.synthesis_result = await _runtime._await_task_with_deadline(
            _state.synthesis_task,
            timeout=_state.timeout_seconds,
            grace=15.0,
        )
    except _runtime.asyncio.CancelledError as exc:
        _state.exc = exc
        if _state.stall_event.is_set() or _state.slow_switch_event.is_set():
            raise _runtime.asyncio.TimeoutError() from _state.exc
        raise
    finally:
        # All cancellations use bounded grace so a
        # non-cooperative task cannot hang the chapter.
        await _runtime._safe_cancel_task(_state.stall_task, grace=5.0)
        await _runtime._safe_cancel_task(_state.segment_idle_task, grace=5.0)
        if _state.slow_task is not None:
            await _runtime._safe_cancel_task(_state.slow_task, grace=5.0)
    if _state.synthesis_result:
        return _ConversionControl("break")
    _state.waited = await _state.wait_edge_cooldown_if_needed(
        f"attempt {_state.attempt + 1}/{_state.max_attempts}",
        tracker=_state.engine_tracker,
        engine_ref=_state.engine_instance,
    )
    if not _state.waited:
        return _ConversionControl("break")
