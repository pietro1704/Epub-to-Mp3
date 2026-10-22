# -*- coding: utf-8 -*-
"""Chapter attempt preparation."""

from __future__ import annotations

from typing import List, Optional, Set

from .conversion_control import ConversionControl as _ConversionControl


async def _chapter_attempt_preparation(self, _state):
    from . import converter as _runtime
    _state.output_path = self._expected_output_path(_state.chapter, _state.chapter_num, _state.output_dir)

    # Check if MP3 already exists and is valid (size > 1KB)
    # Note: Cache validation already done by _validate_and_clean_cache()
    if _state.output_path.exists() and not _state.config.force_reprocess:
        _state.file_size = _state.output_path.stat().st_size
        if _state.file_size > 1000:  # Minimum 1KB for valid audio
            _state.cached_payload = (
                self._load_cached_payload(_state.chapter, _state.chapter_num, _state.output_dir)
                or _state.speech_text
            )
            _state.truncation_warning = self._detect_short_audio_output(
                _state.output_path,
                _state.cached_payload,
                _state.config,
                engine_label=_state.engine_tracker.get("label"),
            )
            if _state.truncation_warning:
                if self.verbose:
                    print(f"   ⚠️ Invalid cache detected: {_state.truncation_warning}")
                _state.output_path.unlink(missing_ok=True)
            else:
                _state.converted_files.append(_state.output_path)
                _state.chapter_success = True
                _state.chapter_cached = True
                self.progress.tick(f"✅ File already exists ({_state.file_size} bytes)")
                self.progress.complete_chapter("✅ Complete (cache)")
                self._retry_original_texts.pop(_state.chapter_label, None)
                return _ConversionControl("break")
        else:
            # Empty or corrupted file — remove and reconvert
            if self.verbose:
                print(
                    f"   🗑️ Removing invalid file ({_state.file_size} bytes): {_state.output_path}"
                )
            _state.output_path.unlink(missing_ok=True)
            _state.output_path.with_suffix(".wav").unlink(missing_ok=True)

    # Synthesize with heartbeat and timeout (optimized)
    _state.speech_text = _state.speech_text or ""
    _state.preview = self._chapter_preview(_state.speech_text)
    if _state.preview:
        print(f"   📝 Initial excerpt: {_state.preview}")
    _state.current_payload = _state.speech_text
    _state.estimated_seconds = _runtime.TextValidator.estimate_duration(_state.speech_text)
    if _state.estimated_seconds <= 0:
        _state.estimated_seconds = max(_state.chapter_chars / 15.0, 30.0)
    _state.switched_for_size = False
    _state.auto_order: Optional[List[str]] = None
    _state.attempted_auto: Set[str] = set()
    if _state.is_auto_engine:
        _state.pool_view = _state.available_auto_pool()
        if not _state.pool_view:
            _state.chapter_error = "No engine available in automatic mode"
            _state.errors.append(f"{_state.chapter.name}: {_state.chapter_error}")
            _state.chapter_error = _state._error_text(_state.chapter_error)
            self.progress.complete_chapter(f"❌ {_state.chapter_error}")
            return _ConversionControl("break")
        _state.must_try_edge_first = (
            "edge" in _state.pool_view
            and "edge" not in _state.blocked_engines_for_chapter
            and "edge" not in _state.attempted_auto
        )
        if _state.must_try_edge_first:
            _state.picked_engine = "edge"
            _state.auto_order = [
                name
                for name in self._preferred_auto_engine_order(_state.pool_view)
                if name not in _state.blocked_engines_for_chapter
            ]
            if self.verbose:
                print("   ⚡ AUTO: forcing first attempt on edge for this chapter")
        if _state.forced_auto_engine and _state.forced_auto_engine in _state.blocked_engines_for_chapter:
            _state.forced_auto_engine = None
        if (
            not _state.must_try_edge_first
            and _state.forced_auto_engine
            and _state.forced_auto_engine in _state.pool_view
        ):
            _state.picked_engine = _state.forced_auto_engine
            _state.auto_order = self._preferred_auto_engine_order(_state.pool_view)
            if _state.picked_engine in _state.auto_order:
                _state.auto_order = [_state.picked_engine] + [
                    name for name in _state.auto_order if name != _state.picked_engine
                ]
            _state.auto_order = [
                name
                for name in _state.auto_order
                if name not in _state.blocked_engines_for_chapter
            ]
            if self.verbose:
                print(f"   ⚡ AUTO: forcing engine {_state.picked_engine} for retry")
        else:
            _state.picked_engine, _state.auto_order = self._pick_auto_engine(
                _state.chapter_chars, _state.estimated_seconds, _state.pool_view
            )
            _state.auto_order = [
                name
                for name in (_state.auto_order or [])
                if name not in _state.blocked_engines_for_chapter
            ]
            if _state.picked_engine in _state.blocked_engines_for_chapter:
                _state.picked_engine = next(
                    (
                        candidate
                        for candidate in (_state.auto_order or [])
                        if candidate in _state.pool_view
                    ),
                    _state.picked_engine,
                )
        _state.attempted_auto.add(_state.picked_engine)
        _state.engine_tracker["label"] = _state.picked_engine
        # Record engine selection for future ranking
        if not self.speed_controller._current_engine:
            self.speed_controller.record_engine_switch(_state.picked_engine)
    else:
        _state.engine_tracker["label"] = (_state.config.engine or "").lower()

    _state.current_engine_label = (
        _state.engine_tracker.get("label") or (_state.config.engine or "").lower()
    )
    _state.tts_output_path, _state.needs_mp3_transcode = _state._resolve_tts_output_path(
        _state.output_path, _state.current_engine_label
    )

    if _state.current_engine_label == "edge" and not _state.is_auto_engine:
        _state.threshold_chars = max(getattr(_state.config, "edge_auto_offline_chars", 0), 0)
        _state.threshold_seconds = max(getattr(_state.config, "edge_auto_offline_seconds", 0), 0)
        _state.edge_reason = None
        if _state.threshold_chars and _state.chapter_chars >= _state.threshold_chars:
            _state.edge_reason = f"Chapter too large ({_state.chapter_chars} chars)"
        elif _state.threshold_seconds and _state.estimated_seconds >= _state.threshold_seconds:
            _state.edge_reason = f"Chapter estimated at {int(_state.estimated_seconds)}s"
        if _state.edge_reason and self.verbose:
            print(f"   ℹ️ Edge keeps engine even for large chapter: {_state.edge_reason}")
        elif _state.edge_force_offline:
            if self.verbose:
                print("   ℹ️ Edge marked as unstable, keeping engine (no fallback)")
            _state.edge_force_offline = False
            _state.edge_state["force_offline_after_trunc"] = False

    # Product decision: no predictive edge→offline switching before a real failure.

    while True:
        try:
            _state.engine_config, _state.engine_obj = await _state.engine_pool.acquire(
                _state.current_engine_label
            )
            _state.engine_instance["object"] = _state.engine_obj
            _state.restore_policy = getattr(
                _state.engine_obj, "restore_segment_policy_state", None
            )
            _state.saved_policy = self._segment_adaptive_state.get(
                "segment_duration_policy"
            )
            if callable(_state.restore_policy) and isinstance(_state.saved_policy, dict):
                _state.restore_policy(_state.saved_policy)
            _state.engine_name_used = _state.current_engine_label
            if _state.engine_config and _state.engine_config.engine:
                _state.engine_tracker["label"] = (
                    _state.engine_config.engine or _state.current_engine_label
                ).lower()
                _state.current_engine_label = _state.engine_tracker["label"]
            self.progress.set_active_engine(_state.current_engine_label)
            break
        except Exception as exc:
            _state.exc = exc
            _state.unavailable_engines.add(_state.current_engine_label)
            if _state.is_auto_engine and _state.auto_order:
                _state.candidate_order = [
                    name
                    for name in (_state.auto_order or [])
                    if name not in _state.blocked_engines_for_chapter
                ]
                _state.next_engine = self._next_auto_engine(
                    _state.candidate_order, _state.attempted_auto
                )
                if _state.next_engine:
                    _state.attempted_auto.add(_state.next_engine)
                    _state.engine_tracker["label"] = _state.next_engine
                    _state.current_engine_label = _state.next_engine
                    continue
            _state.chapter_error = f"Engine {_state.current_engine_label} unavailable: {_state.exc}"
            _state.errors.append(f"{_state.chapter.name}: {_state.chapter_error}")
            _state.chapter_error = _state._error_text(_state.chapter_error)
            self.progress.complete_chapter(f"❌ {_state.chapter_error}")
            _state.engine_obj = None
            break

    if _state.engine_obj is None:
        return _ConversionControl("break")

    _state.tts_engine = _state.engine_obj
    self._apply_persisted_engine_params(
        cfg=_state.engine_config,
        engine_label=_state.current_engine_label,
        engine_obj=_state.tts_engine,
    )
    await self._run_engine_warmup(
        engine_label=_state.current_engine_label,
        engine_obj=_state.tts_engine,
        cfg=_state.engine_config,
        output_dir=_state.output_dir,
    )
    if (_state.current_engine_label or "").lower() == "piper":
        with _runtime.contextlib.suppress(Exception):
            await self._maybe_run_piper_canary(
                tts_engine=_state.tts_engine,
                config=_state.engine_config,
                chapter_text=_state.speech_text,
                output_dir=_state.output_dir,
                chapter_index=_state.chapter_num,
            )
    try:
        if _state.current_engine_label == "edge":
            _state.plan_segments = self._load_segment_plan(
                getattr(
                    _state.engine_config, "cache_dir", getattr(_state.config, "cache_dir", None)
                ),
                _state.chapter_num,
                chunk_chars=getattr(_state.engine_config, "edge_chunk_chars", None),
            )
            setattr(_state.tts_engine, "_precomputed_segments", _state.plan_segments or None)
            if self.verbose and _state.plan_segments:
                print(f"   ♻️ Segment plan reused: {len(_state.plan_segments)} blocks")
        elif hasattr(_state.tts_engine, "_precomputed_segments"):
            setattr(_state.tts_engine, "_precomputed_segments", None)
    except Exception:
        pass

    _state.decision = self.speed_controller.before_chapter(
        _state.engine_tracker["label"],
        chapter_index=_state.chapter_num,
        chapter_name=_state.chapter_label,
        chapter_chars=_state.chapter_chars,
        tts_engine=_state.engine_instance["object"],
        config=_state.config,
        verbose=self.verbose,
    )
    if _state.decision.message:
        print(_state.decision.message)
    if (
        _state.edge_auto_enabled
        and _state.edge_state.get("slow_mode")
        and _state.current_engine_label == "edge"
    ):
        self._apply_edge_slow_mode(
            "safe mode enabled",
            engine_pool=_state.engine_pool,
            engine_obj=_state.tts_engine,
        )
    elif _state.current_engine_label == "edge" and _state.chapter_chars >= _runtime.EDGE_FORCE_SAFE_CHARS:
        self._apply_edge_slow_mode(
            f"chapter too large ({_state.chapter_chars} chars)",
            engine_pool=_state.engine_pool,
            engine_obj=_state.tts_engine,
        )
        with _runtime.contextlib.suppress(Exception):
            setattr(_state.tts_engine, "_auto_tune_enabled", False)

    # Optimized timeout: aggressive floor, larger ceiling for long Edge chapters
    # Base: duration estimada * 1.5 + 30s buffer
    _state.base_timeout = _state.estimated_seconds * 1.5 + 30.0
    _state.timeout_seconds = max(_state.base_timeout, 60.0)  # Minimum 60s
    _state.max_timeout = 600.0  # Default: up to 10 min
    if _state.current_engine_label == "edge":
        if _state.chapter_chars >= 80000:
            _state.max_timeout = 3600.0  # 1h for very large chapters
        elif _state.chapter_chars >= 50000:
            _state.max_timeout = 2400.0
        elif _state.chapter_chars >= 30000:
            _state.max_timeout = 1800.0
        if _state.edge_stable_mode:
            _state.max_timeout = max(_state.max_timeout, 3600.0)
    _state.timeout_seconds = min(_state.timeout_seconds, _state.max_timeout)
    if _state.decision.timeout_scale:
        _state.timeout_seconds = _state.timeout_seconds * _state.decision.timeout_scale
