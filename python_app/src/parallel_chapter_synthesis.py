# -*- coding: utf-8 -*-
"""Parallel chapter synthesis."""

from __future__ import annotations

from .conversion_control import ConversionControl as _ConversionControl
from .ebook_reader import Chapter as Chapter


async def _parallel_chapter_synthesis(self, _state):
    from . import converter as _runtime
    if self.verbose:
        _state.chapter_text = _state.chapter.text
        _state.text_info = "None" if _state.chapter_text is None else f"{len(_state.chapter_text)} chars"
        print(f"[DEBUG] Chapter {_state.index} text: {_state.text_info}")
        if _state.chapter_text:
            print(f"[DEBUG] Chapter {_state.index} preview: {str(_state.chapter_text)[:100]}")

    if not _runtime.TextValidator.is_valid_text(_state.speech_text or " "):
        _state.status_holder["text"] = self.loc.t("status_insufficient_text")
        self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
        _state.outcome = _runtime.ChapterConversionOutcome(
            index=_state.index,
            name=_state.chapter_label,
            path=None,
            error=_state.status_holder["text"],
        )
        return _ConversionControl("return", None if _state.legacy_mode else _state.outcome)

    try:
        _state.chunks = _runtime.ChapterProcessor.chunk_text(_state.speech_text or "")
        _state.chapter_payload = "\n".join(_state.chunks)
        if self.verbose:
            print(
                f"[DEBUG] Chapter {_state.index} chunks: {len(_state.chunks)}, payload: {len(_state.chapter_payload)} chars"
            )

    except Exception as e:
        _state.e = e
        if self.verbose:
            print(f"[DEBUG] Chapter {_state.index} chunk_text error: {_state.e}")
        raise
    self._cache_text(_state.cache_dir, _state.chapter, _state.index, _state.chapter_payload)

    # Spot-check against EPUB to ensure payload still matches source text
    if not self._spot_check_text_against_epub(_state.speech_text or "", _state.chapter_payload):
        _state.status_holder["text"] = "❌ text diverge do EPUB (spot-check)"
        self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
        _state.outcome = _runtime.ChapterConversionOutcome(
            index=_state.index,
            name=_state.chapter_label,
            path=None,
            error=_state.status_holder["text"],
        )
        return _ConversionControl("return", None if _state.legacy_mode else _state.outcome)

    # **TEXT INTEGRITY MONITORING**: Log character counts
    _state.epub_text = _state.speech_text or ""
    _state.epub_char_count = len(_runtime.re.sub(r"\s+", " ", _state.epub_text).strip())
    _state.payload_char_count = len(_runtime.re.sub(r"\s+", " ", _state.chapter_payload).strip())
    _state.char_diff = _state.epub_char_count - _state.payload_char_count
    _state.char_diff_percent = (
        (abs(_state.char_diff) / max(_state.epub_char_count, 1)) * 100 if _state.epub_char_count > 0 else 0
    )

    if abs(_state.char_diff) > 50:  # Only log if significant difference
        _state.diff_symbol = "⚠️ " if abs(_state.char_diff_percent) > 5.0 else "ℹ️ "
        print(
            f"{_state.diff_symbol}Chapter {_state.index}: EPUB={_state.epub_char_count:,} chars → "
            f"TTS={_state.payload_char_count:,} chars ({_state.char_diff:+,} chars, "
            f"{_state.char_diff_percent:+.1f}%)"
        )

    _state.status_holder["text"] = self.loc.t("status_synthesizing")
    self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])

    # **UPDATED**: Fallback strategy and timeouts based on estimated duration
    _state.char_count = len(_state.chapter_payload or "")
    _state.lang_tag_count = _state.chapter_payload.lower().count("[[lang:") if _state.chapter_payload else 0

    _state.use_immediate_fallback = _state.lang_tag_count > 50 or (
        _state.lang_tag_count > 20 and _state.char_count > 15000
    )
    if _state.payload_locked:
        _state.use_immediate_fallback = False

    if _state.use_immediate_fallback:
        if self.verbose:
            print(
                f"[DEBUG] Chapter {_state.index} muito complexo "
                f"({_state.lang_tag_count} tags, {_state.char_count} chars) - usando fallback imediato"
            )
        try:
            from ..language import LanguageMarkup
            _state.LanguageMarkup = LanguageMarkup

            _state.simplified = (
                _state.LanguageMarkup.strip(_state.chapter_payload)
                if _state.LanguageMarkup
                else _state.chapter_payload
            )
            if self.verbose:
                print(
                    f"[DEBUG] Chapter {_state.index} FALLBACK IMEDIATO: "
                    f"{_state.char_count} → {len(_state.simplified)} chars"
                )
            _state.status_holder["text"] = (
                f"🔄 Fallback: removendo {_state.lang_tag_count} tags de language"
            )
            self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
            _state.chapter_payload = _state.simplified
        except ImportError:
            if self.verbose:
                print(f"[DEBUG] Chapter {_state.index} FALLBACK: LanguageMarkup not available")

    # Recompute metrics after fallback
    _state.char_count = len(_state.chapter_payload or "")
    _state.lang_tag_count = _state.chapter_payload.lower().count("[[lang:") if _state.chapter_payload else 0
    _state.estimated_seconds = _runtime.TextValidator.estimate_duration(_state.chapter_payload)
    if _state.estimated_seconds <= 0:
        _state.estimated_seconds = max(_state.char_count / 25.0, 45.0)

    if _state.use_immediate_fallback or _state.lang_tag_count > 10:
        _state.base_timeout = _state.estimated_seconds * 1.4 + 45.0
        _state.minimum_timeout = 150.0
    else:
        _state.base_timeout = _state.estimated_seconds * 1.25 + 30.0
        _state.minimum_timeout = 90.0

    _state.chapter_timeout = max(_state.base_timeout, _state.minimum_timeout)
    _state.chapter_timeout = min(_state.chapter_timeout, 900.0)

    if self.verbose:
        print(
            f"[DEBUG] Chapter {_state.index} timeout: {_state.chapter_timeout:.0f}s "
            f"(estimado {_state.estimated_seconds:.0f}s, {_state.char_count} chars, {_state.lang_tag_count} tags)"
        )

    # Try synthesis (already with fallback applied for complex chapters)
    _state.synthesis_task = None
    _state.temp_wav = None
    _state.max_attempts = 1 if _state.use_immediate_fallback else 2
    _state.attempt = 1

    def _pre_segment_monitor(segment_text: str, _total_chars: int):
        self._pre_segment_health_check(
            engine_label=(_state.config.engine or "").lower(),
            segment_chars=len(segment_text or ""),
            config=_state.config,
            engine_obj=_state.tts_engine,
        )
    _state._pre_segment_monitor = _pre_segment_monitor

    while _state.attempt <= _state.max_attempts and _state.temp_wav is None:
        # On second attempt for non-complex chapters, apply fallback
        if _state.attempt == 2 and not _state.use_immediate_fallback and not _state.payload_locked:
            try:
                from ..language import LanguageMarkup
                _state.LanguageMarkup = LanguageMarkup

                _state.simplified_payload = (
                    _state.LanguageMarkup.strip(_state.chapter_payload)
                    if _state.LanguageMarkup
                    else _state.chapter_payload
                )
                _state.original_count = _state.chapter_payload.lower().count("[[lang:")
                if self.verbose:
                    print(
                        f"[DEBUG] Chapter {_state.index} FALLBACK: removendo {_state.original_count} tags [[lang:]]"
                    )
                    print(
                        f"[DEBUG] Chapter {_state.index} FALLBACK: {len(_state.chapter_payload)} → {len(_state.simplified_payload)} chars"
                    )
                _state.status_holder["text"] = (
                    f"🔄 Tentativa 2: removendo {_state.original_count} tags de language"
                )
                self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
                _state.chapter_payload = _state.simplified_payload
            except ImportError:
                if self.verbose:
                    print(
                        f"[DEBUG] Chapter {_state.index} FALLBACK: LanguageMarkup not available"
                    )

        try:
            if self.verbose:
                print(f"[DEBUG] Chapter {_state.index} attempt {_state.attempt}/{_state.max_attempts}")

            # Pass formatting segments only on first attempt with original payload
            _state.chapter_formatting = (
                None
                if _state.payload_locked
                else (
                    getattr(_state.chapter, "formatting_segments", None)
                    if _state.attempt == 1 and _state.chapter_payload == _state.speech_text
                    else None
                )
            )
            _state.synthesis_task = _runtime.asyncio.create_task(
                _state._synthesize_safe(
                    _state.tts_engine,
                    _state.chapter_payload,
                    _state.output_path.with_suffix(".wav"),
                    formatting_segments=_state.chapter_formatting,
                    pre_segment_callback=_state._pre_segment_monitor,
                )
            )
            _state.temp_wav = await _runtime._await_task_with_deadline(
                _state.synthesis_task, timeout=_state.chapter_timeout, grace=15.0
            )

            if _state.temp_wav and (_state.attempt == 2 or _state.use_immediate_fallback):
                if self.verbose:
                    print(f"[DEBUG] Chapter {_state.index} SUCESSO no fallback!")

        except _runtime.asyncio.TimeoutError:
            if self.verbose:
                print(
                    f"[DEBUG] Chapter {_state.index} attempt {_state.attempt} timeout after {_state.chapter_timeout}s"
                )
            # ``_await_task_with_deadline`` already detached the
            # task with bounded grace; still call safe-cancel so
            # mid-flight tasks from other code paths don't leak.
            await _runtime._safe_cancel_task(_state.synthesis_task, grace=5.0)

            if _state.attempt == _state.max_attempts:
                _state.temp_wav = None
                if hasattr(_state.tts_engine, "last_error"):
                    _state.tts_engine.last_error = "timeout_final"

        except Exception as e:
            _state.e = e
            if _state.legacy_mode:
                raise
            if self.verbose:
                print(f"[DEBUG] Chapter {_state.index} attempt {_state.attempt} error: {_state.e}")
            await _runtime._safe_cancel_task(_state.synthesis_task, grace=5.0)

            if _state.attempt == _state.max_attempts:
                _state.temp_wav = None
                if hasattr(_state.tts_engine, "last_error"):
                    _state.tts_engine.last_error = f"error: {_state.e}"

        _state.attempt += 1

    if not _state.temp_wav:
        _state.status_holder["text"] = self.loc.t("status_synthesis_failed")
        _state.last_error = getattr(_state.tts_engine, "last_error", None)
        _state.detail = (
            self.loc.t("status_synthesis_failed_detail", error=_state.last_error)
            if _state.last_error
            else _state.status_holder["text"]
        )
        _state.status_holder["text"] = _state.detail
        self._announce_stage(_state.index, _state.chapter_label, _state.detail)
        _state.outcome = _runtime.ChapterConversionOutcome(
            index=_state.index,
            name=_state.chapter_label,
            path=None,
            error=_state.detail,
            slowdown=self._should_flag_slowdown(_state.last_error),
        )
        return _ConversionControl("return", None if _state.legacy_mode else _state.outcome)

    _state.status_holder["text"] = self.loc.t("status_convert_mp3")
    self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
    _state.converted = await self.audio_processor.convert_to_mp3(
        _state.temp_wav, _state.output_path, bitrate=_state.config.bitrate
    )
    if _state.converted is None:
        _state.status_holder["text"] = self.loc.t("status_mp3_failed")
        self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
        _state.outcome = _runtime.ChapterConversionOutcome(
            index=_state.index,
            name=_state.chapter_label,
            path=None,
            error=_state.status_holder["text"],
        )
        return _ConversionControl("return", None if _state.legacy_mode else _state.outcome)

    # Post-validate output after each chapter
    await self._auto_validate_output(_state.output_dir, stage=f"chapter-{_state.index}")

    _state.truncation_warning = self._detect_short_audio_output(
        _state.converted,
        _state.chapter_payload,
        _state.config,
    )
