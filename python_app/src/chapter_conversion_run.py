# -*- coding: utf-8 -*-
"""Coordinate chapter conversion phases and original control flow."""

from __future__ import annotations


from .conversion_control import ConversionControl as _ConversionControl
from .ebook_reader import Chapter


from .parallel_chapter_synthesis import _parallel_chapter_synthesis
from .parallel_chapter_audio_validation import _parallel_chapter_audio_validation
from .parallel_chapter_completion import _parallel_chapter_completion

async def _chapter_conversion_run(self, _state):
    from . import converter as _runtime
    _state.legacy_mode = _state.config is None and _state.progress is None
    if _state.config is None:
        _state.config = _runtime.ConversionConfig(engine="edge", output_dir=str(_state.output_dir))
    if _state.progress is None:
        _state.progress = self.progress

    async def _synthesize_safe(engine_obj, text, output_path, **kwargs):
        try:
            sig = _runtime.inspect.signature(engine_obj.synthesize_async)
            allowed = {k: v for k, v in kwargs.items() if k in sig.parameters}
        except Exception:
            allowed = kwargs
        return await engine_obj.synthesize_async(text, output_path, **allowed)
    _state._synthesize_safe = _synthesize_safe

    _state.chapter_label = _state.chapter.name or f"Chapter {_state.index}"
    _state.output_path = self.file_manager.get_temp_output_path(_state.chapter_label, _state.output_dir, _state.index)
    _state.cache_dir = getattr(_state.config, "cache_dir", None)
    _state.speech_text, _state._pre_tts_path, _state.payload_locked = self._resolve_pre_tts_payload(
        _state.chapter, _state.index, _state.output_dir, _state.config
    )

    if _state.output_path.exists() and not _state.config.force_reprocess:
        # **AUTOMATIC CACHE VALIDATION**: Verify cached audio integrity
        _state.cache_valid = True
        try:
            from .audio_validator import AudioValidator
            _state.AudioValidator = AudioValidator

            if _state.speech_text and getattr(_state.config, "validate_audio", True):
                _state.validator = _state.AudioValidator()
                _state.validation_result = _state.validator.validate_duration(
                    _state.speech_text,
                    _state.output_path,
                    tolerance=0.25,  # 25% tolerance for cached files
                )

                if not _state.validation_result.is_valid:
                    _state.cache_valid = False
                    if self.verbose:
                        print(f"⚠️ Chapter {_state.index} cache INVALID: {_state.validation_result.error_message}")
                        print(f"   Re-converting chapter {_state.index}...")
                    # Delete invalid cached file
                    try:
                        _state.output_path.unlink()
                    except OSError:
                        pass
                elif self.verbose:
                    print(
                        f"✓ Chapter {_state.index} cache valid: "
                        f"{_state.validation_result.actual_duration:.1f}s "
                        f"({_state.validation_result.duration_diff_percent:+.1f}% diff)"
                    )
        except Exception as e:
            _state.e = e
            if self.verbose:
                print(f"⚠️ Chapter {_state.index} cache validation error: {_state.e}")
            # On validation error, trust cache and continue
            _state.cache_valid = True

        if _state.cache_valid:
            _state.progress.start_chapter(_state.chapter_label, _state.index)
            if _state.cache_dir:
                try:
                    _state.cached_chunks = _runtime.ChapterProcessor.chunk_text(_state.speech_text or "")
                    _state.cached_payload = "\n".join(_state.cached_chunks)
                    self._cache_text(_state.cache_dir, _state.chapter, _state.index, _state.cached_payload)
                except Exception:
                    pass
            self._cache_audio(
                _state.cache_dir, _state.output_path, _state.chapter, _state.index, _state.config, text_root=_state.output_dir
            )
            _state.status = self.loc.t("status_cached")
            self._announce_stage(_state.index, _state.chapter_label, _state.status)
            if getattr(_state.config, "listen", False):
                _state.progress.tick(self.loc.t("status_playing"))
                _state.played = await self.audio_processor.play_audio(_state.output_path)
                _state.status = (
                    self.loc.t("status_complete")
                    if _state.played
                    else self.loc.t("status_play_unavailable")
                )
                self._announce_stage(_state.index, _state.chapter_label, _state.status)
            _state.progress.complete_chapter(_state.status)
            _state.outcome = _runtime.ChapterConversionOutcome(
                index=_state.index, name=_state.chapter_label, path=_state.output_path
            )
            return _ConversionControl("return", _state.output_path if _state.legacy_mode else _state.outcome)
        # If cache invalid, fall through to reconversion below

    _state.progress.start_chapter(_state.chapter_label, _state.index)
    _state.status_holder = {"text": self.loc.t("status_waiting_slot")}
    self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
    _state.heartbeat_stop = _runtime.asyncio.Event()

    async def heartbeat():
        try:
            while not _state.heartbeat_stop.is_set():
                _state.progress.tick(_state.status_holder["text"])
                await _runtime.asyncio.sleep(1)
        except _runtime.asyncio.CancelledError:
            pass
    _state.heartbeat = heartbeat

    _state.heartbeat_task = _runtime.asyncio.create_task(_state.heartbeat())

    try:
        await _state.semaphore.acquire()
        _state.progress.mark_phase_start()
        _state.status_holder["text"] = self.loc.t("status_preparing")
        self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
        try:
            _phase_flow = await _parallel_chapter_synthesis(self, _state)
            if _phase_flow is not None:
                return _phase_flow
            _phase_flow = await _parallel_chapter_audio_validation(self, _state)
            if _phase_flow is not None:
                return _phase_flow
            _phase_flow = await _parallel_chapter_completion(self, _state)
            if _phase_flow is not None:
                return _phase_flow
        except Exception as inner_exc:
            _state.inner_exc = inner_exc
            if _state.legacy_mode:
                raise
            raise RuntimeError(f"chapter conversion failed: {_state.inner_exc}") from _state.inner_exc
    except Exception as exc:
        _state.exc = exc
        if self.verbose:
            print(f"[DEBUG] Chapter {_state.index} exception: {type(_state.exc).__name__}: {_state.exc}")
            import traceback
            _state.traceback = traceback

            _state.traceback.print_exc()
        if not _state.status_holder["text"].startswith("❌"):
            _state.status_holder["text"] = self.loc.t("status_internal_error")
            self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
        if _state.legacy_mode:
            raise
        raise RuntimeError(f"chapter conversion failed: {type(_state.exc).__name__}: {_state.exc}") from _state.exc
    finally:
        _state.semaphore.release()
        _state.heartbeat_stop.set()
        _state.heartbeat_task.cancel()
        with _runtime.contextlib.suppress(_runtime.asyncio.CancelledError):
            await _state.heartbeat_task
        _state.progress.complete_chapter(_state.status_holder["text"])
