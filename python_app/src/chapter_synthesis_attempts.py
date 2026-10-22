# -*- coding: utf-8 -*-
"""Chapter synthesis attempts."""

from __future__ import annotations


from .conversion_control import ConversionControl as _ConversionControl


from .chapter_engine_acquisition import _chapter_engine_acquisition
from .chapter_synthesis_fallback import _chapter_synthesis_fallback

async def _chapter_synthesis_attempts(self, _state):
    from . import converter as _runtime
    try:
        if self.verbose:
            print(f"   🔄 Running TTS command: {type(_state.tts_engine).__name__}")

        _state.synthesis_result = None
        _state.slow_engine_triggered = False
        _state.max_attempts = 1 if _state.current_engine_label == "edge" else 2
        _state.last_tts_output_path = _state.tts_output_path
        _state.last_needs_transcode = _state.needs_mp3_transcode
        self._append_runtime_metric(
            {
                "event": "pipeline_stage_start",
                "stage": "synthesize",
                "chapter": _state.chapter_num,
                "engine": _state.current_engine_label,
            },
            output_dir=_state.output_dir,
        )
        for _state.attempt in range(_state.max_attempts):
            _phase_flow = await _chapter_engine_acquisition(self, _state)
            if _phase_flow is not None:
                if _phase_flow.kind == "break":
                    break
                if _phase_flow.kind == "continue":
                    continue
                return _phase_flow
            _phase_flow = await _chapter_synthesis_fallback(self, _state)
            if _phase_flow is not None:
                if _phase_flow.kind == "break":
                    break
                if _phase_flow.kind == "continue":
                    continue
                return _phase_flow

        if _state.synthesis_result and _state.last_needs_transcode:
            self._append_runtime_metric(
                {
                    "event": "pipeline_stage_start",
                    "stage": "encode",
                    "chapter": _state.chapter_num,
                    "engine": _state.current_engine_label,
                },
                output_dir=_state.output_dir,
            )
            self.progress.tick("🎼 Converting WAV→MP3...")
            if self.verbose:
                print(
                    f"[DEBUG] Converting WAV→MP3: {_state.last_tts_output_path.name} → {_state.output_path.name} (bitrate={_state.config.bitrate})"
                )
            _state.converted = await self.audio_processor.convert_to_mp3(
                _state.last_tts_output_path,
                _state.output_path,
                bitrate=_state.config.bitrate,
            )
            if self.verbose and _state.converted is None:
                self._append_runtime_metric(
                    {
                        "event": "transcode_failed",
                        "chapter": _state.chapter_num,
                        "engine": _state.current_engine_label,
                        "input": str(_state.last_tts_output_path.name),
                        "output": str(_state.output_path.name),
                    },
                    output_dir=_state.output_dir,
                )
            _state.synthesis_result = _state.converted
            if _state.synthesis_result:
                with _runtime.contextlib.suppress(OSError):
                    _state.last_tts_output_path.unlink(missing_ok=True)
                self._append_runtime_metric(
                    {
                        "event": "pipeline_stage_done",
                        "stage": "encode",
                        "chapter": _state.chapter_num,
                        "engine": _state.current_engine_label,
                    },
                    output_dir=_state.output_dir,
                )

        if self.verbose and _state.synthesis_result:
            print(f"   ✅ TTS completed: {_state.output_path.name}")
    except _runtime.asyncio.TimeoutError:
        _state.elapsed = int(_runtime.time.time() - _state.start_synthesis)
        if _state.slow_switch_event.is_set() and _state.is_auto_engine and _state.auto_order:
            _state.current_engine = (_state.engine_tracker.get("label") or "").lower()
            _state.blocked_engines_for_chapter.add(_state.current_engine)
            _state.attempted_auto.add(_state.current_engine)
            _state.slow_engine_triggered = True
            if self.verbose:
                print(
                    f"   ⚡ Slow engine detected ({_state.current_engine}, {_state.elapsed}s without segment progress) - switching engine"
                )
            self.progress.tick(
                f"⚡ Slow engine {_state.current_engine}: switching automatically"
            )
            _state.synthesis_result = None
            return _ConversionControl("continue")
        if self.verbose:
            print(f"   ⚠️ TIMEOUT: Chapter stuck after {_state.elapsed}s")
        self.progress.tick(
            f"⚠️ TIMEOUT after {_state.elapsed}s - trying fallback without language..."
        )
        if _state.current_engine_label == "edge":
            _state._maybe_apply_edge_slow_mode(
                f"timeout after {_state.elapsed}s", engine_obj=_state.tts_engine
            )
            setattr(_state.tts_engine, "last_error", "timeout")
            await _state.wait_edge_cooldown_if_needed(
                f"timeout after {_state.elapsed}s",
                tracker=_state.engine_tracker,
                engine_ref=_state.engine_instance,
            )

        # **FALLBACK**: Remover language markup e tentar novamente
        try:
            from ..language import LanguageMarkup
            _state.LanguageMarkup = LanguageMarkup

            _state.base_text = _state.speech_text
            if _state.payload_locked:
                _state.clean_text = _state.speech_text
            else:
                _state.clean_text = (
                    _state.LanguageMarkup.strip(_state.base_text) if _state.LanguageMarkup else _state.base_text
                )
            _state.current_payload = _state.clean_text
            _state.clean_chars = len(_state.clean_text)
            _state.fallback_timeout = max(90, int(_state.timeout_seconds * 0.5))
            if _state.current_engine_label == "edge":
                _state.fallback_timeout = max(120, min(int(_state.timeout_seconds * 0.6), 600))

            if self.verbose:
                print("   🔄 RETRY: Trying again without language markers")
                print(
                    f"   📝 RETRY: {_state.clean_chars} chars (timeout: {_state.fallback_timeout}s)"
                )

            self.progress.tick(
                f"🔄 Fallback: {_state.clean_chars} chars (timeout: {_state.fallback_timeout}s)"
            )

            # Heartbeat for fallback engine (optimized: 3s)
            _state.heartbeat_active = True
            _state.start_fallback = _runtime.time.time()

            async def fallback_heartbeat():
                spinner_frames = ["🚑", "🔥"]
                frame_idx = 0
                while _state.heartbeat_active:
                    await _runtime.asyncio.sleep(5)
                    if not _state.heartbeat_active:
                        break
                    elapsed_fb = int(_runtime.time.time() - _state.start_fallback)
                    frame = spinner_frames[frame_idx % len(spinner_frames)]
                    self.progress.tick(
                        f"{frame} FALLBACK {elapsed_fb}s/{_state.fallback_timeout}s"
                    )
                    self._mark_health_activity(_state.chapter_num, "fallback")
                    frame_idx += 1
            _state.fallback_heartbeat = fallback_heartbeat

            _state.fallback_task = _runtime.asyncio.create_task(_state.fallback_heartbeat())

            try:
                _state.current_engine_label = (
                    _state.engine_tracker.get("label") or (_state.config.engine or "").lower()
                )
                _state.tts_output_path, _state.needs_mp3_transcode = _state._resolve_tts_output_path(
                    _state.output_path, _state.current_engine_label
                )
                _state.synthesis_result = await _runtime.asyncio.wait_for(
                    _state._synthesize_safe(
                        _state.tts_engine,
                        _state.clean_text,
                        _state.tts_output_path,
                        formatting_segments=None,
                        pre_segment_callback=_state.on_pre_segment,
                        chunk_callback=None,
                        resume_chunks_dir=None,
                    ),
                    timeout=_state.fallback_timeout,
                )
                if _state.synthesis_result and _state.needs_mp3_transcode:
                    self.progress.tick("🎼 Converting WAV→MP3 (fallback)...")
                    if self.verbose:
                        print(
                            f"[DEBUG] Converting WAV→MP3 (fallback): {_state.tts_output_path.name} → {_state.output_path.name} (bitrate={_state.config.bitrate})"
                        )
                    _state.converted = await self.audio_processor.convert_to_mp3(
                        _state.tts_output_path,
                        _state.output_path,
                        bitrate=_state.config.bitrate,
                    )
                    if self.verbose and _state.converted is None:
                        self._append_runtime_metric(
                            {
                                "event": "transcode_failed",
                                "chapter": _state.chapter_num,
                                "engine": _state.current_engine_label,
                                "input": str(_state.tts_output_path.name),
                                "output": str(_state.output_path.name),
                                "phase": "fallback",
                            },
                            output_dir=_state.output_dir,
                        )
                    _state.synthesis_result = _state.converted
                    if _state.synthesis_result:
                        with _runtime.contextlib.suppress(OSError):
                            _state.tts_output_path.unlink(missing_ok=True)
                if self.verbose and _state.synthesis_result:
                    print("   ✅ RETRY: Success no fallback!")
            finally:
                _state.heartbeat_active = False
                _state.fallback_task.cancel()
                with _runtime.contextlib.suppress(_runtime.asyncio.CancelledError):
                    await _state.fallback_task

        except (ImportError, _runtime.asyncio.TimeoutError):
            _state.total_elapsed = int(_runtime.time.time() - _state.start_synthesis)
            if self.verbose:
                print(
                    "   ⚠️ FALLBACK: Double attempt failed; skipping short-text emergency to avoid truncation"
                )
            self.progress.tick("🔄 Full-text retry only (short emergency disabled)")
            # Never synthesize reduced text (e.g., first 1000 chars), because
            # it generates valid-but-truncated audio and poisons final validation.
            _state.synthesis_result = None
            with _runtime.contextlib.suppress(Exception):
                setattr(_state.tts_engine, "last_error", "timeout_full_retry_required")

            if not _state.synthesis_result:
                _state.total_elapsed = int(_runtime.time.time() - _state.start_synthesis)
                _state.error_msg = (
                    f"TRIPLE TIMEOUT after {_state.total_elapsed}s - all attempts failed"
                )
                _state.current_label = (_state.engine_tracker.get("label") or "").lower()
                if (
                    _state.is_auto_engine
                    and _state.current_label in {"piper"}
                    and _state.chapter_attempt < _state.max_chapter_attempts
                ):
                    # Keep retrying the same chapter locally with safer settings
                    # instead of skipping ahead with failure.
                    _state.blocked_engines_for_chapter.add("edge")
                    _state.forced_auto_engine = _state.current_label
                    if _state.current_label == "piper":
                        try:
                            _state.current_chunk = int(
                                _runtime.os.getenv(
                                    "PIPER_CHUNK_CHARS",
                                    str(
                                        getattr(_state.config, "piper_chunk_chars", 1800)
                                        or 1800
                                    ),
                                )
                                or "1800"
                            )
                        except Exception:
                            _state.current_chunk = 1800
                        _state.safer_chunk = max(900, int(_state.current_chunk * 0.75))
                        _runtime.os.environ["PIPER_CHUNK_CHARS"] = str(_state.safer_chunk)
                        _runtime.os.environ["PIPER_MAX_PROCS"] = "2"
                        with _runtime.contextlib.suppress(Exception):
                            setattr(_state.config, "piper_chunk_chars", _state.safer_chunk)
                        with _runtime.contextlib.suppress(Exception):
                            setattr(_state.config, "piper_max_procs", 2)
                    self.progress.tick(
                        "🔁 Local timeout: retrying same chapter with safer offline profile"
                    )
                    _state.chapter_error = _state.error_msg
                    raise _state._RetryChapter(_state.error_msg)
                if self.verbose:
                    print(f"   ❌ FINAL ERROR: {_state.error_msg}")
                _state.chapter_error = _state.error_msg
                if (_state.engine_tracker.get("label") or "").lower() == "edge":
                    if _state.is_auto_engine:
                        _state.blocked_engines_for_chapter.add("edge")
                        _state._trip_edge_circuit("timeout")
                    else:
                        _state._edge_retry(_state.error_msg)
                _state.errors.append(f"{_state.chapter.name}: {_state.error_msg}")
                _state.error_msg = _state._error_text(_state.error_msg)
                self.progress.complete_chapter(f"❌ {_state.error_msg}")
                return _ConversionControl("break")
    finally:
        _state.heartbeat_active = False
        _state.heartbeat_task.cancel()
        with _runtime.contextlib.suppress(_runtime.asyncio.CancelledError):
            await _state.heartbeat_task
