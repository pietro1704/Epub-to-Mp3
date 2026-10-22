# -*- coding: utf-8 -*-
"""Server chapter audio acceptance."""

from __future__ import annotations


from .conversion_control import ConversionControl as _ConversionControl


async def _server_chapter_audio_acceptance(_runtime, _state, _chapter):
    _chapter.duration_seconds = await _runtime._get_audio_duration(_chapter.output_file)
    _chapter.chapter_elapsed = _runtime.time.time() - _chapter.start_time

    _chapter.engine_label = (
        (_chapter.local_active_config.engine if _chapter.local_active_config else None)
        or _chapter.engine_name
        or "auto"
    )
    _chapter.truncation_warning = _runtime._detect_short_audio_output(
        _chapter.clean_text,
        _chapter.output_file,
        engine_label=_chapter.engine_label,
    )
    if _chapter.truncation_warning:
        _runtime._append_event(_state.job, f"⚠️ {_chapter.truncation_warning}")
        if hasattr(_chapter.engine_obj, "last_error"):
            setattr(_chapter.engine_obj, "last_error", "short_output")
        with _runtime.contextlib.suppress(OSError):
            _chapter.output_file.unlink(missing_ok=True)
        if await _chapter._maybe_retry(
            reason="truncated audio",
            engine_label=_chapter.engine_label,
            engine_obj=_chapter.engine_obj,
            engine_config=_chapter.engine_config,
        ):
            return _ConversionControl("continue")
        if _state.auto_mode:
            _chapter.available_auto = _state._available_auto_pool()
            _chapter.next_engine = _runtime._next_auto_engine(
                _chapter.auto_order, _chapter.attempted_auto, _chapter.available_auto
            )
            if _chapter.next_engine:
                _chapter.attempted_auto.add(_chapter.next_engine)
                _chapter.local_engine_name = _chapter.next_engine
                _chapter.local_active_config = _chapter.available_auto[_chapter.next_engine]
                _runtime._append_event(
                    _state.job,
                    "   ↳ AUTO: truncated audio; trying another engine",
                )
                return _ConversionControl("continue")
        if _state._switch_to_next_engine("Truncated audio"):
            _chapter.local_active_config = _state.active_config
            _chapter.local_engine_name = (
                _state.active_config.engine if _state.active_config else _state.config.engine
            ) or "auto"
            return _ConversionControl("continue")
        if _runtime._record_chapter_failure(
            _state.job,
            _chapter.engine_obj,
            _chapter.chapter_name,
            _chapter.truncation_warning,
            chapter_index=_chapter.idx,
            fatal=False,
        ):
            _state.job_failed["value"] = True
        return _ConversionControl("return", None)
    _chapter.duplicate_entry = None
    try:
        _chapter.duplicate_entry = await _state.audio_duplicate_tracker.check_duplicate(
            _chapter.output_file, _chapter.clean_text, _chapter.idx, _chapter.chapter_name
        )
    except Exception as exc:
        _chapter.exc = exc
        _runtime._append_event(
            _state.job,
            f"⚠️ Failed to validate duplicate audio: {_chapter.exc}",
        )

    if _chapter.duplicate_entry:
        _chapter.duplicate_msg = (
            "Duplicate audio detected: "
            f"same content as chapter {_chapter.duplicate_entry.get('index')} "
            f"({_chapter.duplicate_entry.get('name')})"
        )
        _runtime._append_event(_state.job, f"⚠️ {_chapter.duplicate_msg}")
        with _runtime.contextlib.suppress(OSError):
            _chapter.output_file.unlink(missing_ok=True)
        if await _chapter._maybe_retry(
            reason="duplicate audio",
            engine_label=_chapter.engine_label,
            engine_obj=_chapter.engine_obj,
            engine_config=_chapter.engine_config,
        ):
            return _ConversionControl("continue")
        if _state.auto_mode:
            _chapter.available_auto = _state._available_auto_pool()
            _chapter.next_engine = _runtime._next_auto_engine(
                _chapter.auto_order, _chapter.attempted_auto, _chapter.available_auto
            )
            if _chapter.next_engine:
                _chapter.attempted_auto.add(_chapter.next_engine)
                _chapter.local_engine_name = _chapter.next_engine
                _chapter.local_active_config = _chapter.available_auto[_chapter.next_engine]
                _runtime._append_event(
                    _state.job,
                    "   ↳ AUTO: duplicate audio; trying another engine",
                )
                return _ConversionControl("continue")
        if _state._switch_to_next_engine("Duplicate audio detected"):
            _chapter.local_active_config = _state.active_config
            _chapter.local_engine_name = (
                _state.active_config.engine if _state.active_config else _state.config.engine
            ) or "auto"
            return _ConversionControl("continue")
        if _runtime._record_chapter_failure(
            _state.job,
            _chapter.engine_obj,
            _chapter.chapter_name,
            _chapter.duplicate_msg,
            chapter_index=_chapter.idx,
            fatal=False,
        ):
            _state.job_failed["value"] = True
        return _ConversionControl("return", None)
    return _ConversionControl("break")
