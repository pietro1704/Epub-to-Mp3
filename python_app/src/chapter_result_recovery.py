# -*- coding: utf-8 -*-
"""Chapter result recovery."""

from __future__ import annotations

from .chapter_audio_acceptance import _chapter_audio_acceptance
from .chapter_synthesis_telemetry import _chapter_synthesis_telemetry
from .conversion_control import ConversionControl as _ConversionControl


async def _chapter_result_recovery(self, _state):
    from . import converter as _runtime
    if _state.synthesis_result and _state.output_path.exists():
        _phase_flow = await _chapter_synthesis_telemetry(self, _state)
        if _phase_flow is not None:
            if _phase_flow.kind == "break":
                return _ConversionControl("break")
            if _phase_flow.kind == "continue":
                return _ConversionControl("continue")
            return _phase_flow
        _phase_flow = await _chapter_audio_acceptance(self, _state)
        if _phase_flow is not None:
            if _phase_flow.kind == "break":
                return _ConversionControl("break")
            if _phase_flow.kind == "continue":
                return _ConversionControl("continue")
            return _phase_flow
    else:
        # **RETRY**: Tentar com language default em caso de failure
        # Note: Don't block retry just because payload is locked - the cached text
        # may still be correct, and blocking prevents recovery from transient failures
        if _state.current_engine_label == "edge":
            _state.last_err = getattr(_state.tts_engine, "last_error", None)
            _state.reason = _state._edge_error_reason(_state.last_err)
            # Track Edge failures for adaptive delay
            _state.edge_failure_count += 1
            _state.edge_consecutive_failures += 1
            if self.verbose and _state.edge_consecutive_failures > 1:
                print(
                    f"   ⚠️  Edge-TTS failure #{_state.edge_failure_count} "
                    f"({_state.edge_consecutive_failures} consecutive)"
                )
            if _state.reason in {"rate_limit", "timeout"}:
                _state.backoff = min(8.0, 1.5 + float(_state.edge_consecutive_failures))
                _state._maybe_apply_edge_slow_mode(
                    f"{_state.reason} detected", engine_obj=_state.tts_engine
                )
                if self.verbose:
                    print(
                        f"   ⏳ Edge {_state.reason}: applying {_state.backoff:.1f}s backoff before retry"
                    )
                await _runtime.asyncio.sleep(_state.backoff)
            _state._maybe_apply_edge_slow_mode(
                f"failure Edge ({_state.reason})", engine_obj=_state.tts_engine
            )
            _state.chapter_error = (
                f"Edge unavailable ({_state.reason})"
                if _state.reason != "unknown"
                else "Edge failed"
            )
            if _state.is_auto_engine and _state.reason in {"network", "auth"}:
                _state._block_edge_connectivity(_state.last_err)
                if self.verbose:
                    print(
                        "   🛡️ Edge blocked for this chapter/pass after connectivity failure"
                    )
            else:
                _state._edge_retry(_state.chapter_error, count_failure=False)
        if self.verbose:
            print("   ⚠️ RETRY: Synthesis failed, retrying with default language")

            try:
                # If Edge is on cooldown, wait before retrying to avoid instant failures.
                await _state.wait_edge_cooldown_if_needed(
                    "antes do retry",
                    tracker=_state.engine_tracker,
                    engine_ref=_state.engine_instance,
                )

                # Use only the first part of text with default language
                _state.simple_text = (_state.speech_text or "")[:2000].strip()
                _state.current_payload = _state.simple_text
                if _state.simple_text:
                    self.progress.tick(
                        "🔄 Retry: text simples (language default)..."
                    )
                    _state.retry_timeout = 45

                    _state.synthesis_result = None
                    for _state.attempt in range(2):
                        _state.synthesis_result = await _runtime.asyncio.wait_for(
                            _state._synthesize_safe(
                                _state.tts_engine,
                                _state.simple_text,
                                _state.output_path,
                                formatting_segments=None,
                                pre_segment_callback=_state.on_pre_segment,
                                chunk_callback=_state.chunk_callback,
                                resume_chunks_dir=_state.chunk_root,
                            ),
                            timeout=_state.retry_timeout,
                        )
                        if _state.synthesis_result:
                            break
                        _state.waited = await _state.wait_edge_cooldown_if_needed(
                            f"retry {_state.attempt + 1}/2",
                            tracker=_state.engine_tracker,
                            engine_ref=_state.engine_instance,
                        )
                        if not _state.waited:
                            break

                    if _state.synthesis_result and _state.output_path.exists():
                        _state.file_size = _state.output_path.stat().st_size

                        # Validar tamanho minimum
                        if _state.file_size > 1000:
                            _state.truncation_warning = self._detect_short_audio_output(
                                _state.output_path,
                                _state.current_payload,
                                _state.config,
                                engine_label=_state.engine_tracker.get("label"),
                            )
                            if _state.truncation_warning:
                                if self.verbose:
                                    print(f"   ⚠️ {_state.truncation_warning}")
                                if hasattr(_state.tts_engine, "last_error"):
                                    setattr(
                                        _state.tts_engine, "last_error", "short_output"
                                    )
                                _state.output_path.unlink(missing_ok=True)
                                _state.chapter_error = _state.truncation_warning
                                if (
                                    _state.engine_tracker.get("label") or ""
                                ).lower() == "edge":
                                    _state._edge_retry(_state.truncation_warning)
                                _state.errors.append(
                                    f"{_state.chapter.name}: {_state.truncation_warning}"
                                )
                                self.progress.complete_chapter(
                                    f"❌ {_state.truncation_warning}"
                                )
                                return _ConversionControl("break")

                            if getattr(_state.config, "validate_audio", True):
                                _state.audio_ok, _state.audio_error = (
                                    self._validate_audio_after_write(
                                        _state.current_payload, _state.output_path, config=_state.config
                                    )
                                )
                                if not _state.audio_ok:
                                    _state.retried = await self._attempt_segment_retry(
                                        _state.tts_engine,
                                        _state.chapter_num,
                                        _state.chapter_label,
                                        _state.output_path,
                                        config=_state.config,
                                    )
                                    if _state.retried:
                                        _state.audio_ok, _state.audio_error = (
                                            self._validate_audio_after_write(
                                                _state.current_payload,
                                                _state.output_path,
                                                config=_state.config,
                                            )
                                        )
                                    if not _state.audio_ok:
                                        _state.output_path.unlink(missing_ok=True)
                                        _state.chapter_error = (
                                            _state.audio_error or "Invalid audio"
                                        )
                                        if (
                                            _state.engine_tracker.get("label") or ""
                                        ).lower() == "edge":
                                            _state._edge_retry(_state.chapter_error)
                                        _state.errors.append(
                                            f"{_state.chapter.name}: {_state.chapter_error}"
                                        )
                                        self.progress.complete_chapter(
                                            f"❌ {_state.chapter_error}"
                                        )
                                        return _ConversionControl("break")

                            if (
                                _state.engine_tracker.get("label") or ""
                            ).lower() == "edge":
                                _state.segments_ok, _state.segments_error = (
                                    self._edge_segment_integrity_ok(_state.tts_engine)
                                )
                                if not _state.segments_ok:
                                    _state.output_path.unlink(missing_ok=True)
                                    _state.chapter_error = (
                                        _state.segments_error or "Incomplete segments"
                                    )
                                    _state.edge_failure_count += 1
                                    _state.edge_consecutive_failures += 1
                                    if self.verbose:
                                        print(
                                            f"   ⚠️  Edge-TTS segment failure #{_state.edge_failure_count}"
                                        )
                                        print(f"   ⚠️  {_state.chapter_error}")
                                    _state._edge_retry(_state.chapter_error, count_failure=False)
                                _state.errors.append(f"{_state.chapter.name}: {_state.chapter_error}")
                                _state.chapter_error = _state._error_text(_state.chapter_error)
                                self.progress.complete_chapter(
                                    f"❌ {_state.chapter_error}"
                                )
                                return _ConversionControl("break")

                            _state.converted_files.append(_state.output_path)
                            self._embed_id3_metadata(
                                _state.output_path,
                                title=_state.chapter_label,
                                album=_state.book_title,
                                artist=_state.book_author or None,
                                cover_art=_state.cover_art,
                            )
                            _state.chapter_success = True

                            if self.verbose:
                                print(
                                    f"   ✅ RETRY: Success with simplified text ({_state.file_size} bytes)"
                                )
                            self.progress.complete_chapter("✅ Success (retry)")
                            _state.chapter_elapsed = _runtime.time.time() - _state.start_time
                            _state.current_engine_label = (
                                _state.engine_tracker.get("label")
                                or (_state.config.engine or "").lower()
                            )
                            if (
                                _state.current_engine_label == "edge"
                                and not _state.switched_for_size
                                and getattr(_state.config, "edge_auto_offline_seconds", 0)
                            ):
                                _state.slow_cutoff = max(
                                    getattr(_state.config, "edge_auto_offline_seconds", 0),
                                    0,
                                )
                                if (
                                    _state.slow_cutoff
                                    and _state.chapter_elapsed >= _state.slow_cutoff * 1.4
                                ):
                                    if _state.build_best_offline_engine(
                                        f"Edge took {int(_state.chapter_elapsed)}s for this chapter"
                                    ):
                                        if self.verbose:
                                            print(
                                                "   ⚡ Next chapters will switch to offline engine for performance"
                                            )
                                        _state.current_engine_label = (
                                            _state.engine_tracker.get("label")
                                            or (_state.config.engine or "").lower()
                                        )
                                        _state.tts_output_path, _state.needs_mp3_transcode = (
                                            _state._resolve_tts_output_path(
                                                _state.output_path, _state.current_engine_label
                                            )
                                        )
                            self._retry_original_texts.pop(_state.chapter_label, None)
                            return _ConversionControl("break")  # Success! Continue to next chapter

                        if self.verbose:
                            print(f"   ⚠️ RETRY: Invalid file ({_state.file_size} bytes)")
                        _state.output_path.unlink(missing_ok=True)
            except Exception as retry_e:
                _state.retry_e = retry_e
                if self.verbose:
                    print(f"   ❌ RETRY failed: {_state.retry_e}")

            if _state.current_engine_label == "edge":
                _state.last_err = ""
                try:
                    _state.last_err = str(getattr(_state.tts_engine, "last_error", "") or "")
                except Exception:
                    _state.last_err = ""
                if (
                    "rate_limit" in _state.last_err.lower()
                    or "too many requests" in _state.last_err.lower()
                ):
                    _state._maybe_apply_edge_slow_mode(
                        "Rate limit detected", engine_obj=_state.tts_engine
                    )
                    if hasattr(self, "progress"):
                        self.progress.tick(
                            "⏳ Edge rate-limited; applying safe mode and retrying"
                        )

            # If all retries failed
            _state.error_msg = "Synthesis failed"
            if hasattr(_state.tts_engine, "last_error") and _state.tts_engine.last_error:
                _state.error_msg += f": {_state.tts_engine.last_error}"
            if self.verbose:
                print(f"   ❌ FINAL ERROR: {_state.error_msg}")
            _state.chapter_error = _state.error_msg
            if (
                _state.engine_tracker.get("label") or (_state.config.engine or "").lower()
            ) == "edge":
                _state._edge_retry(_state.error_msg)
            _state.errors.append(f"{_state.chapter.name}: {_state.error_msg}")
            _state.error_msg = _state._error_text(_state.error_msg)
            self.progress.complete_chapter(f"❌ {_state.error_msg}")
