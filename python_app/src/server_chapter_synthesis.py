# -*- coding: utf-8 -*-
"""Server chapter synthesis."""

from __future__ import annotations

from typing import Optional

from .conversion_control import ConversionControl as _ConversionControl
from .ebook_reader import Chapter as Chapter


async def _server_chapter_synthesis(_runtime, _state, _chapter):
    try:
        async with _state.engine_pool.use(_chapter.engine_name) as (_chapter.engine_config, _chapter.engine_obj):
            _chapter.local_active_config = _chapter.engine_config
            _chapter.local_engine_name = (_chapter.engine_config.engine or _chapter.engine_name).lower()
            if _state.auto_mode and _chapter.local_engine_name == "edge" and not _state.edge_slow_mode:
                _state._apply_auto_edge_profile(_chapter.engine_obj)
            if (
                _state.edge_slow_mode
                and (_chapter.engine_config.engine or _chapter.engine_name).lower() == "edge"
            ):
                if hasattr(_chapter.engine_obj, "apply_speed_profile"):
                    try:
                        _chapter.engine_obj.apply_speed_profile(
                            chunk_char_limit=_state.edge_safe_profile["chunk_chars"],
                            max_segment_seconds=_state.edge_safe_profile[
                                "max_segment_seconds"
                            ],
                            words_per_minute=160,
                        )
                    except Exception:
                        pass
                if hasattr(_chapter.engine_obj, "_enable_parallel"):
                    with _runtime.contextlib.suppress(Exception):
                        setattr(_chapter.engine_obj, "_enable_parallel", False)
                        setattr(_chapter.engine_obj, "_parallel_slots", 1)
            _chapter.tts_path, _chapter.needs_transcode = _state._resolve_tts_output(
                _chapter.output_file, _chapter.engine_config.engine
            )
            try:
                def invoke(observed_callback):
                    try:
                        return _chapter.engine_obj.synthesize_async(
                            _chapter.clean_text,
                            _chapter.tts_path,
                            progress_callback=_chapter._progress_callback,
                            chunk_callback=observed_callback,
                        )
                    except TypeError:
                        # Fallback for engines that don't support callbacks
                        return _chapter.engine_obj.synthesize_async(_chapter.clean_text, _chapter.tts_path)
                _chapter.invoke = invoke

                _chapter.synth_coro = _runtime.observe_synthesis(_chapter.invoke, _chapter._chunk_callback)
                _chapter.synth_task = _runtime.asyncio.ensure_future(_chapter.synth_coro)
                # Per-chapter idle watchdog — aborts when the
                # engine goes silent mid-synthesis even if the
                # outer wait_for still has runway.  Uses the
                # local segment-hit counter so sibling chapters
                # cannot keep it alive.
                try:
                    _chapter._seg_idle_seconds = float(
                        _runtime.os.getenv("CHAPTER_SEGMENT_IDLE_SECONDS", "180") or "180"
                    )
                except ValueError:
                    _chapter._seg_idle_seconds = 180.0
                _chapter._segment_progress_state["hits"] = 0
                _chapter.idle_task: Optional[_runtime.asyncio.Task] = None
                if _chapter._seg_idle_seconds > 0:
                    _chapter.idle_task = _runtime.asyncio.create_task(
                        _runtime._segment_idle_watchdog(
                            _chapter.synth_task,
                            _chapter._segment_progress_state,
                            _chapter._seg_idle_seconds,
                            _chapter.idx,
                        )
                    )
                try:
                    _chapter.synth_result = await _runtime._await_task_with_deadline(
                        _chapter.synth_task,
                        timeout=_chapter.chapter_timeout,
                        grace=15.0,
                    )
                finally:
                    await _runtime._safe_cancel_task(_chapter.idle_task, grace=5.0)
                _chapter.last_stage_timestamp = _runtime.time.time()
                # Engines that write WAV (Piper) return None on
                # failure instead of raising.  Raise here so the
                # exception handler can trigger the proper fallback chain
                # rather than reaching the WAV→MP3 step with no input.
                if _chapter.needs_transcode and _chapter.synth_result is None:
                    raise RuntimeError(
                        f"{_chapter.engine_config.engine or _chapter.engine_name} synthesis returned no output"
                    )
            except _runtime.asyncio.TimeoutError:
                _chapter.use_engine = _chapter.engine_config.engine or _chapter.engine_name or "unknown"
                _runtime._append_event(
                    _state.job,
                    f"   ⚠️ {_chapter.chapter_name}: timeout of  {int(_chapter.chapter_timeout)}s exceeded on {_chapter.use_engine}",
                )
                _state.job["statusHint"] = (
                    f"Chapter {_chapter.idx}/{len(_state.chapters)} delayed on {_chapter.use_engine.upper()} (timeout)"
                )
                # Track consecutive Edge timeouts job-wide so subsequent
                # chapters skip the 60s wait if Edge is consistently broken.
                if _chapter.use_engine == "edge":
                    _state.edge_chapter_timeouts[0] += 1
                    _runtime.telemetry.record_failure("edge")
                    if _state.edge_chapter_timeouts[0] >= _state._EDGE_TIMEOUT_DISABLE_THRESHOLD:
                        _state.unavailable_engines.add("edge")
                        _runtime._append_event(
                            _state.job,
                            f"🚫 Edge disabled for job after "
                            f"{_state.edge_chapter_timeouts[0]} consecutive timeouts "
                            f"— remaining chapters skip Edge",
                        )
                if await _chapter._maybe_retry(
                    reason=f"timeout on {_chapter.use_engine}",
                    engine_label=_chapter.use_engine,
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
                            f"   ↳ AUTO: switching to {_chapter.next_engine.upper()} after timeout",
                        )
                        return _ConversionControl("continue")
                # If Edge hasn't hit the permanent-disable threshold,
                # fall back locally for THIS chapter only — next chapter
                # retries Edge.  Only permanently switch after
                # _EDGE_TIMEOUT_DISABLE_THRESHOLD consecutive stalls.
                if (
                    _chapter.use_engine == "edge"
                    and _state.edge_chapter_timeouts[0] < _state._EDGE_TIMEOUT_DISABLE_THRESHOLD
                    and _state.engine_index + 1 < len(_state.engine_chain)
                ):
                    _chapter.fallback_cfg = _state.engine_chain[_state.engine_index + 1]
                    _chapter.local_active_config = _chapter.fallback_cfg
                    _chapter.local_engine_name = (_chapter.fallback_cfg.engine or "auto").lower()
                    _runtime._append_event(
                        _state.job,
                        f"   ↳ Chapter-local fallback to {_chapter.local_engine_name.upper()} "
                        f"(Edge below disable threshold — next chapter retries Edge)",
                    )
                    return _ConversionControl("continue")
                if _state._switch_to_next_engine(
                    f"Synthesizer {_chapter.use_engine.upper()} stalled for {int(_chapter.chapter_timeout)}s"
                ):
                    _chapter.local_active_config = _state.active_config
                    _chapter.local_engine_name = (
                        _state.active_config.engine if _state.active_config else _state.config.engine
                    ) or "auto"
                    return _ConversionControl("continue")
                if _runtime._record_chapter_failure(
                    _state.job,
                    _chapter.engine_obj,
                    _chapter.chapter_name,
                    "timeout exceeded",
                    chapter_index=_chapter.idx,
                    fatal=False,
                ):
                    _state.job_failed["value"] = True
                return _ConversionControl("return", None)
            except Exception as exc:
                _chapter.exc = exc
                if await _chapter._maybe_retry(
                    reason=f"error in {_chapter.engine_config.engine if _chapter.engine_config else 'engine'}",
                    engine_label=(
                        _chapter.engine_config.engine if _chapter.engine_config else _chapter.engine_name
                    ),
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
                            f"   ↳ AUTO: switching to {_chapter.next_engine.upper()} after error ({_chapter.exc})",
                        )
                        return _ConversionControl("continue")
                if _state._switch_to_next_engine(
                    f"Engine {_chapter.engine_config.engine if _chapter.engine_config else _state.config.engine} failed ({_chapter.exc})"
                ):
                    _chapter.local_active_config = _state.active_config
                    _chapter.local_engine_name = (
                        _state.active_config.engine if _state.active_config else _state.config.engine
                    ) or "auto"
                    return _ConversionControl("continue")
                if _runtime._record_chapter_failure(
                    _state.job,
                    _chapter.engine_obj,
                    _chapter.chapter_name,
                    _chapter.exc,
                    chapter_index=_chapter.idx,
                    fatal=False,
                ):
                    _state.job_failed["value"] = True
                return _ConversionControl("return", None)

            _chapter.target_file = _chapter.output_file
            if _chapter.needs_transcode:
                _chapter.converted = await _runtime.AudioProcessor.convert_to_mp3(
                    _chapter.tts_path,
                    _chapter.output_file,
                    bitrate=_state.config.bitrate,
                )
                if not _chapter.converted:
                    with _runtime.contextlib.suppress(OSError):
                        _chapter.tts_path.unlink(missing_ok=True)
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
                                f"   ↳ AUTO: switching to {_chapter.next_engine.upper()} after WAV→MP3 conversion failure",
                            )
                            return _ConversionControl("continue")
                    if _state._switch_to_next_engine("WAV→MP3 conversion failed"):
                        _chapter.local_active_config = _state.active_config
                        _chapter.local_engine_name = (
                            _state.active_config.engine if _state.active_config else _state.config.engine
                        ) or "auto"
                        return _ConversionControl("continue")
                    if _runtime._record_chapter_failure(
                        _state.job,
                        _chapter.engine_obj,
                        _chapter.chapter_name,
                        "failed to convert WAV to MP3",
                        chapter_index=_chapter.idx,
                        fatal=False,
                    ):
                        _state.job_failed["value"] = True
                    return _ConversionControl("return", None)
                with _runtime.contextlib.suppress(OSError):
                    _chapter.tts_path.unlink(missing_ok=True)
                _chapter.target_file = _chapter.converted
                _chapter.last_stage_timestamp = _runtime.time.time()

            if not _chapter.target_file.exists() or _chapter.target_file.stat().st_size == 0:
                with _runtime.contextlib.suppress(OSError):
                    _chapter.target_file.unlink(missing_ok=True)
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
                            _state.job, "   ↳ AUTO: empty audio; trying another engine"
                        )
                        return _ConversionControl("continue")
                if _state._switch_to_next_engine("Empty or missing audio"):
                    _chapter.local_active_config = _state.active_config
                    _chapter.local_engine_name = (
                        _state.active_config.engine if _state.active_config else _state.config.engine
                    ) or "auto"
                    return _ConversionControl("continue")
                if _runtime._record_chapter_failure(
                    _state.job,
                    _chapter.engine_obj,
                    _chapter.chapter_name,
                    "audio was not generated by the voice service",
                    chapter_index=_chapter.idx,
                    fatal=False,
                ):
                    _state.job_failed["value"] = True
                return _ConversionControl("return", None)
    except Exception as exc:
        _chapter.exc = exc
        if _chapter.engine_name:
            _state.unavailable_engines.add(_chapter.engine_name)
            _runtime.telemetry.record_failure(_chapter.engine_name)
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
                    f"   ↳ AUTO: switching to {_chapter.next_engine.upper()} after failed to start ({_chapter.exc})",
                )
                return _ConversionControl("continue")
        if _state._switch_to_next_engine(f"Engine unavailable ({_chapter.exc})"):
            _chapter.local_active_config = _state.active_config
            _chapter.local_engine_name = (
                _state.active_config.engine if _state.active_config else _state.config.engine
            ) or "auto"
            return _ConversionControl("continue")
        if _runtime._record_chapter_failure(
            _state.job,
            None,
            _chapter.chapter_name,
            _chapter.exc,
            chapter_index=_chapter.idx,
            fatal=False,
        ):
            _state.job_failed["value"] = True
        return _ConversionControl("return", None)
