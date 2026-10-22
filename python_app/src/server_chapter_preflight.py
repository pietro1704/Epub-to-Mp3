# -*- coding: utf-8 -*-
"""Server chapter preflight."""

from __future__ import annotations


from .conversion_control import ConversionControl as _ConversionControl


async def _server_chapter_preflight(_runtime, _state, _chapter):
    if _state._should_abort_current_run(
        f"🛑 Conversion cancelled during chapter {_chapter.chapter_name}"
    ):
        return _ConversionControl("return", None)

    _chapter.engine_name = (
        _chapter.local_engine_name
        or (_chapter.local_active_config.engine if _chapter.local_active_config else _state.config.engine)
        or "auto"
    ).lower()
    # If the current engine was flagged unavailable job-wide (e.g. Edge
    # after the timeout threshold), switch before spending another
    # chapter_timeout on it. Without this guard, each remaining chapter
    # would time out on the dead engine before the retry layer gave up.
    if _runtime._engine_is_disabled(_chapter.engine_name, _state.unavailable_engines):
        if _state._switch_to_next_engine(f"{_chapter.engine_name.upper()} disabled job-wide"):
            _chapter.local_active_config = _state.active_config
            _chapter.local_engine_name = (
                _state.active_config.engine if _state.active_config else _state.config.engine
            ) or "auto"
            return _ConversionControl("continue")
        if _runtime._record_chapter_failure(
            _state.job,
            None,
            _chapter.chapter_name,
            f"{_chapter.engine_name} disabled and no fallback engine available",
            chapter_index=_chapter.idx,
            fatal=False,
        ):
            _state.job_failed["value"] = True
        return _ConversionControl("return", None)
    _chapter.synth_started = _runtime.time.time()
    _chapter.last_stage_timestamp = _chapter.synth_started
    _chapter.chapter_timeout = _runtime._resolve_chapter_timeout(
        _chapter.estimated_seconds, text_chars=len(_chapter.clean_text)
    )
    if _state.edge_slow_mode and _chapter.engine_name == "edge":
        _chapter.safe_max = float(_state.edge_safe_profile["timeout_max"])
        # Scale the slow-mode cap with chapter size so large
        # chapters (50-70 K chars) are not cut off prematurely.
        # Conservative slow-mode Edge speed on HF: 30 chars/s.
        if len(_chapter.clean_text) > 0:
            _chapter.safe_max = max(_chapter.safe_max, len(_chapter.clean_text) / 30.0 * 1.5)
        _chapter.chapter_timeout = min(_chapter.chapter_timeout, _chapter.safe_max)
