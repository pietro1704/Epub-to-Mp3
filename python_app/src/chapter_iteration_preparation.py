# -*- coding: utf-8 -*-
"""Chapter iteration preparation."""

from __future__ import annotations

from typing import Optional, Set

from .conversion_control import ConversionControl as _ConversionControl


async def _chapter_iteration_preparation(self, _state):
    from . import converter as _runtime
    if (_state.config.engine or "").lower() == "edge" and _state.idx > 0:
        await _state._maybe_apply_edge_fallback()

        # Calculate delay based on failure rate
        if _state.edge_consecutive_failures > 0:
            # Exponential backoff: double delay for each consecutive failure
            _state.delay = min(_state.base_delay * (2**_state.edge_consecutive_failures), _state.max_delay)
            if self.verbose:
                print(
                    f"   ⏱️  Edge-TTS adaptive delay: {_state.delay:.1f}s (failures: {_state.edge_consecutive_failures})"
                )
            await _runtime.asyncio.sleep(_state.delay)
        elif _state.edge_failure_count > 5:
            # If we've had failures (but not consecutive), use small delay
            await _runtime.asyncio.sleep(_state.base_delay * 2)

    # Use chapter's original index if available (important for parallel mode)
    # where each task receives a single-chapter list
    _state.chapter_num = self._chapter_number(_state.chapter, _state.idx + 1)
    _state.progress_index = getattr(_state.chapter, "_progress_index", None) or (_state.idx + 1)
    _state.chapter_label = self._chapter_display_name(_state.chapter, _state.chapter_num)
    if _state.stage_pipeline_enabled and _state.stage_pipeline_queue is not None:
        if _state.idx in _state.stage_pipeline_buffer:
            _state.speech_text, _state.pre_tts_path, _state.payload_locked = _state.stage_pipeline_buffer.pop(_state.idx)
        else:
            while True:
                _state.queue_idx, _state.queue_payload, _state.queue_error = await _state.stage_pipeline_queue.get()
                if _state.queue_idx == -1:
                    _state.stage_pipeline_done = True
                    break
                if _state.queue_error is not None:
                    if _state.queue_idx == _state.idx:
                        _state.queue_payload = self._resolve_pre_tts_payload(
                            _state.chapter, _state.chapter_num, _state.output_dir, _state.config
                        )
                    else:
                        continue
                if _state.queue_payload is None:
                    continue
                if _state.queue_idx == _state.idx:
                    _state.speech_text, _state.pre_tts_path, _state.payload_locked = _state.queue_payload
                    break
                _state.stage_pipeline_buffer[_state.queue_idx] = _state.queue_payload
            if _state.stage_pipeline_done and _state.idx not in _state.stage_pipeline_buffer:
                _state.speech_text, _state.pre_tts_path, _state.payload_locked = self._resolve_pre_tts_payload(
                    _state.chapter, _state.chapter_num, _state.output_dir, _state.config
                )
    else:
        _state.used_prefetch = False
        if _state.prefetch_task is not None and _state.prefetch_for_idx == _state.idx:
            try:
                _state.speech_text, _state.pre_tts_path, _state.payload_locked = await _state.prefetch_task
                _state.used_prefetch = True
                self._append_runtime_metric(
                    {
                        "event": "prefetch_hit",
                        "chapter": _state.chapter_num,
                        **self._chapter_identity_fields(_state.chapter, _state.idx + 1),
                    },
                    output_dir=_state.output_dir,
                )
            except Exception:
                _state.used_prefetch = False
                self._append_runtime_metric(
                    {
                        "event": "prefetch_fallback",
                        "chapter": _state.chapter_num,
                        **self._chapter_identity_fields(_state.chapter, _state.idx + 1),
                    },
                    output_dir=_state.output_dir,
                )
            _state.prefetch_task = None
            _state.prefetch_for_idx = None
        if not _state.used_prefetch:
            _state.speech_text, _state.pre_tts_path, _state.payload_locked = self._resolve_pre_tts_payload(
                _state.chapter, _state.chapter_num, _state.output_dir, _state.config
            )
        _state._launch_prefetch(_state.idx + 1)
    _state.current_payload: Optional[str] = _state.speech_text
    _state.chapter_chars = len(_state.speech_text or "")
    # Skip chapters that exceed the configured size limit (e.g. footnote-container
    # files that hold the entire book text as annotation content).
    if _runtime.MAX_CHAPTER_CHARS > 0 and _state.chapter_chars > _runtime.MAX_CHAPTER_CHARS:
        print(
            f"\n⏭️  Skipping chapter {_state.chapter_num} ({_state.chapter_chars:,} chars >"
            f" MAX_CHAPTER_CHARS={_runtime.MAX_CHAPTER_CHARS:,}): {_state.chapter.name[:60]}"
        )
        self.progress.complete_chapter(f"⏭️ Skipped ({_state.chapter_chars:,} chars, oversized)")
        _state.converted_files.append(None)  # placeholder so indices stay aligned
        return _ConversionControl("continue")
    _state.deferred_safe_pass = bool(getattr(_state.chapter, "_deferred_safe_pass", False))
    _state.remaining_chars_estimate = max(
        0,
        int(_state.chapter_chars)
        + sum(max(0, int(v or 0)) for v in _state.chapter_char_estimates[_state.idx + 1 :]),
    )
    _state.recent_cps = 0.0
    if self._eta_recent_cps:
        _state.recent_tail = self._eta_recent_cps[-6:]
        _state.recent_cps = sum(_state.recent_tail) / max(1, len(_state.recent_tail))
    with _runtime.contextlib.suppress(Exception):
        self.progress.update_eta_hint(
            remaining_chars=_state.remaining_chars_estimate,
            chars_per_second=_state.recent_cps,
        )
    _state.progress_started = False
    _state.chapter_attempt = 0
    _state.configured_max_attempts = None
    if getattr(_state.config, "extra", None):
        _state.raw_max_attempts = _state.config.extra.get("max_chapter_attempts")
        if _state.raw_max_attempts is not None:
            try:
                _state.configured_max_attempts = max(1, min(6, int(_state.raw_max_attempts)))
            except (TypeError, ValueError):
                _state.configured_max_attempts = None
    _state.max_chapter_attempts = _state.configured_max_attempts or (4 if _state.deferred_safe_pass else 6)
    _state.forced_auto_engine: Optional[str] = None
    _state.blocked_engines_for_chapter: Set[str] = set()
    _state.edge_connectivity_recorded = False
    if _state.edge_globally_blocked or "__ALL__" in _state.edge_blocked_chapters_global:
        _state.blocked_engines_for_chapter.add("edge")
    if str(_state.chapter_num) in _state.edge_blocked_chapters_global:
        _state.blocked_engines_for_chapter.add("edge")
    if _state.chapter_label in _state.edge_blocked_chapters_global:
        _state.blocked_engines_for_chapter.add("edge")
    _state.chapter_name_raw = str(getattr(_state.chapter, "name", "") or "").strip()
    if _state.chapter_name_raw in _state.edge_blocked_chapters_global:
        _state.blocked_engines_for_chapter.add("edge")
    # Product decision: keep Edge available as the first attempt even on weak networks.
    if _state.deferred_safe_pass:
        _state.blocked_engines_for_chapter.add("edge")
