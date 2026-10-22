# -*- coding: utf-8 -*-
"""Chapter audio acceptance."""

from __future__ import annotations


from .conversion_control import ConversionControl as _ConversionControl


async def _chapter_audio_acceptance(self, _state):
    from . import converter as _runtime
    if _state.file_size > 1000:  # Minimum 1KB for valid audio
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
                setattr(_state.tts_engine, "last_error", "short_output")
            if (_state.engine_tracker.get("label") or "").lower() == "edge":
                # Track Edge truncation failures for adaptive delay
                _state.edge_failure_count += 1
                _state.edge_consecutive_failures += 1
                if self.verbose and _state.edge_consecutive_failures > 1:
                    print(
                        f"   ⚠️  Edge-TTS truncation #{_state.edge_failure_count} "
                        f"({_state.edge_consecutive_failures} consecutive)"
                    )
                _state._maybe_apply_edge_slow_mode(
                    "Truncated audio", engine_obj=_state.tts_engine
                )
                # Force fallback offline after truncamento
                _state.edge_state = self._edge_auto_state or {}
                _state.edge_state["force_offline_after_trunc"] = True
                self._edge_auto_state = _state.edge_state
                if _state.is_auto_engine:
                    _state.pool_view = _state.available_auto_pool()
                    _state.fallback_engine = self._resolve_offline_fallback_engine(
                        set(_state.pool_view.keys())
                    )
                    if (
                        _state.fallback_engine
                        and _state.fallback_engine not in _state.blocked_engines_for_chapter
                    ):
                        _state.forced_auto_engine = _state.fallback_engine
                        if self.verbose:
                            print(
                                "   ⚡ Truncation detected - forcing offline retry: "
                                f"edge → {_state.fallback_engine}"
                            )
            _state.output_path.unlink(missing_ok=True)
            _state.chapter_error = _state.truncation_warning
            if (_state.engine_tracker.get("label") or "").lower() == "edge":
                _state._edge_retry(_state.truncation_warning, count_failure=False)
            _state.errors.append(f"{_state.chapter.name}: {_state.truncation_warning}")
            self.progress.complete_chapter(f"❌ {_state.truncation_warning}")
            return _ConversionControl("break")

        if getattr(_state.config, "validate_audio", True):
            _state.audio_ok, _state.audio_error = self._validate_audio_after_write(
                _state.current_payload, _state.output_path, config=_state.config
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
                    _state.audio_ok, _state.audio_error = self._validate_audio_after_write(
                        _state.current_payload, _state.output_path, config=_state.config
                    )
                if not _state.audio_ok:
                    _state.output_path.unlink(missing_ok=True)
                    _state.chapter_error = _state.audio_error or "Invalid audio"
                    # Track Edge validation failures for adaptive delay
                    if (_state.engine_tracker.get("label") or "").lower() == "edge":
                        _state.edge_failure_count += 1
                        _state.edge_consecutive_failures += 1
                        if self.verbose:
                            print(
                                f"   ⚠️  Edge-TTS validation failure #{_state.edge_failure_count}"
                            )
                    if (_state.engine_tracker.get("label") or "").lower() == "edge":
                        _state._edge_retry(_state.chapter_error, count_failure=False)
                    _state.errors.append(f"{_state.chapter.name}: {_state.chapter_error}")
                    _state.chapter_error = _state._error_text(_state.chapter_error)
                    self.progress.complete_chapter(f"❌ {_state.chapter_error}")
                    return _ConversionControl("break")

        if (
            (_state.engine_tracker.get("label") or "").lower() == "edge"
            and hasattr(_state.tts_engine, "__module__")
            and "edge_engine" in getattr(_state.tts_engine, "__module__", "")
        ):
            _state.segments_ok, _state.segments_error = self._edge_segment_integrity_ok(
                _state.tts_engine
            )
            if not _state.segments_ok:
                _state.output_path.unlink(missing_ok=True)
                _state.chapter_error = _state.segments_error or "Incomplete segments"
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
                self.progress.complete_chapter(f"❌ {_state.chapter_error}")
                return _ConversionControl("break")

        _state.converted_files.append(_state.output_path)
        await _runtime._apply_silence_padding(
            _state.output_path,
            _state.config,
            logger=print if self.verbose else None,
        )
        # Optional: inject extra silence at the
        # natural title/body boundary. Off by
        # default (the user reported it sounded
        # awkward — a fixed-length pause is too
        # uniform across chapters of varying
        # length). Opt in via `--inject-title-pause`
        # on the CLI, which sets
        # `config.inject_title_pause_ms` to a
        # positive value. The injection MUST run
        # before `_embed_id3_metadata` because
        # ffmpeg concat-copy strips non-audio
        # streams (the JPEG cover) and ID3 frames.
        _state.inject_pause_ms = int(getattr(_state.config, "inject_title_pause_ms", 0) or 0)
        if _state.inject_pause_ms > 0:
            try:
                from .audio_postprocess import (
                    find_silence_for_title,
                    inject_silence_at_offset,
                )
                _state.find_silence_for_title = find_silence_for_title
                _state.inject_silence_at_offset = inject_silence_at_offset

                _state.title_hint = _state.chapter_label or _state.chapter.name or ""
                if " - " in _state.title_hint:
                    _state.title_hint = _state.title_hint.split(" - ", 1)[-1]
                _state.splice_at = await _state.find_silence_for_title(
                    _state.output_path,
                    title_text=_state.title_hint,
                )
                if _state.splice_at is not None:
                    await _state.inject_silence_at_offset(
                        _state.output_path,
                        insert_at_seconds=_state.splice_at,
                        silence_ms=_state.inject_pause_ms,
                        bitrate=getattr(_state.config, "bitrate", "8k") or "8k",
                    )
            except Exception as _exc:
                _state._exc = _exc
                if self.verbose:
                    print(f"   ⚠️ title-pause injection failed: {_state._exc}")
        self._embed_id3_metadata(
            _state.output_path,
            title=_state.chapter_label,
            album=_state.book_title,
            artist=_state.book_author or None,
            cover_art=_state.cover_art,
        )
        _state.chapter_success = True

        if self.verbose:
            print(f"   📊 File generated: {_state.file_size} bytes")
        self.progress.complete_chapter(f"✅ Success ({_state.file_size} bytes)")
        _state.chapter_elapsed = _runtime.time.time() - _state.start_time
        _state.current_engine_label = (
            _state.engine_tracker.get("label") or (_state.config.engine or "").lower()
        )
        if _state.chapter_chars:
            _state.throughput = int(_state.chapter_chars / max(_state.chapter_elapsed, 0.001))
        else:
            _state.throughput = 0
        if _state.chapter_chars > 0 and _state.chapter_elapsed > 0:
            _state.cps = float(_state.chapter_chars) / max(float(_state.chapter_elapsed), 0.001)
            self._eta_recent_cps.append(_state.cps)
            if len(self._eta_recent_cps) > 12:
                del self._eta_recent_cps[0 : len(self._eta_recent_cps) - 12]
            self._save_eta_baseline(_state.config, _state.cps)
            self._update_startup_guardrail(_state.config, _state.cps)
        _state.engine_display = (_state.current_engine_label or "engine").upper()
        print(
            f"⏱️ [{_state.engine_display}] Chapter {_state.chapter_num} → "
            f"{_state.chapter_elapsed:.1f}s for {_state.chapter_chars} chars "
            f"({_state.throughput or '~0'} chars/s)"
        )
        if (
            _state.current_engine_label == "edge"
            and not _state.switched_for_size
            and getattr(_state.config, "edge_auto_offline_seconds", 0)
        ):
            _state.slow_cutoff = max(
                getattr(_state.config, "edge_auto_offline_seconds", 0), 0
            )
            if _state.slow_cutoff and _state.chapter_elapsed >= _state.slow_cutoff * 1.4:
                if _state.build_best_offline_engine(
                    f"Edge took {int(_state.chapter_elapsed)}s for this chapter"
                ):
                    if self.verbose:
                        print(
                            "   ⚡ Next chapters will switch to offline engine for performance"
                        )
                _state.current_engine_label = (
                    _state.engine_tracker.get("label") or (_state.config.engine or "").lower()
                )
                _state.tts_output_path, _state.needs_mp3_transcode = _state._resolve_tts_output_path(
                    _state.output_path, _state.current_engine_label
                )
        if (
            _state.edge_auto_enabled
            and _state.current_engine_label == "edge"
            and not _state.chapter_cached
        ):
            _state.chars_per_second = _state.chapter_chars / max(_state.chapter_elapsed, 0.001)
            _state.min_cps = float(
                _state.edge_state.get(
                    "min_chars_per_second", _runtime.EDGE_MIN_CHARS_PER_SECOND
                )
            )
            _state.slow_ratio = float(
                _state.edge_state.get(
                    "slow_ratio_threshold", _runtime.EDGE_SLOW_RATIO_THRESHOLD
                )
            )
            if _state.chars_per_second < _state.min_cps or (
                _state.estimated_seconds > 0
                and _state.chapter_elapsed > (_state.estimated_seconds * _state.slow_ratio)
            ):
                _state._maybe_apply_edge_slow_mode(
                    f"low speed ({_state.chars_per_second:.1f} chars/s)",
                    engine_obj=_state.tts_engine,
                )
        self._retry_original_texts.pop(_state.chapter_label, None)

        # Validate audio completeness (detect truncations)
        if (
            _state.current_engine_label == "edge"
            and hasattr(_state.tts_engine, "__module__")
            and "edge_engine" in getattr(_state.tts_engine, "__module__", "")
        ):
            _state.is_complete, _state.coverage_percent = _runtime.validate_audio_completeness(
                _state.output_path, _state.chapter_chars
            )
            # Lenient acceptance — shared with the server path
            # via LENIENT_COVERAGE_THRESHOLD_PERCENT so a
            # given coverage value never disagrees between
            # CLI and web on whether the audio is truncated.
            if (
                not _state.is_complete
                and _state.coverage_percent >= _runtime.LENIENT_COVERAGE_THRESHOLD_PERCENT
            ):
                if self.verbose:
                    print(
                        f"   ✅ Accepted {_state.coverage_percent:.1f}% coverage "
                        f"({_state.chapter_chars:,} chars — within tolerance)"
                    )
                _state.is_complete = True
            if not _state.is_complete:
                # Audio was truncated - treat as failure
                _state.missing_percent = 100.0 - _state.coverage_percent
                if self.verbose:
                    print(
                        f"   ⚠️ Truncated audio: {_state.coverage_percent:.1f}% do text "
                        f"({_state.missing_percent:.1f}% missing)"
                    )

                # Increment failure counters
                _state.edge_failure_count += 1
                _state.edge_consecutive_failures += 1

                # Mark for retry
                _state.output_path.unlink(missing_ok=True)
                _state.synthesis_result = None
                if _state.is_auto_engine:
                    _state.pool_view = _state.available_auto_pool()
                    _state.fallback_engine = self._resolve_offline_fallback_engine(
                        set(_state.pool_view.keys())
                    )
                    if (
                        _state.fallback_engine
                        and _state.fallback_engine not in _state.blocked_engines_for_chapter
                    ):
                        _state.forced_auto_engine = _state.fallback_engine
                        if self.verbose:
                            print(
                                "   ⚡ Incomplete edge audio - forcing offline retry: "
                                f"edge → {_state.fallback_engine}"
                            )
                _state._edge_retry(
                    f"Audio truncated ({_state.coverage_percent:.1f}% coverage)",
                    count_failure=False,
                )

                # Log failure stats
                if self.verbose:
                    print(
                        f"   📊 Failures Edge: {_state.edge_failure_count} total, "
                        f"{_state.edge_consecutive_failures} consecutive"
                    )
            else:
                # Audio is complete - reset consecutive failures counter
                # (but keep total failure count for statistics)
                if _state.edge_consecutive_failures > 0 and self.verbose:
                    print(
                        f"   ✅ Audio complete ({_state.coverage_percent:.1f}% do text) - "
                        f"resetting consecutive failures counter"
                    )
                _state.edge_consecutive_failures = 0
    else:
        # Output file too small - likely corrompido
        if self.verbose:
            print(
                f"   ⚠️ Output file too small ({_state.file_size} bytes) - considerando failure"
            )
        _state.output_path.unlink(missing_ok=True)
        _state.synthesis_result = None  # Force retry
