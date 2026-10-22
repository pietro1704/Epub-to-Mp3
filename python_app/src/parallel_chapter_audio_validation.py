# -*- coding: utf-8 -*-
"""Parallel chapter audio validation."""

from __future__ import annotations


from .conversion_control import ConversionControl as _ConversionControl


async def _parallel_chapter_audio_validation(self, _state):
    from . import converter as _runtime
    if _state.truncation_warning:
        if self.verbose:
            print(f"   ⚠️ {_state.truncation_warning}")
        try:
            _state.converted.unlink(missing_ok=True)
        except OSError:
            pass
        _state.status_holder["text"] = _state.truncation_warning
        self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
        _state.outcome = _runtime.ChapterConversionOutcome(
            index=_state.index,
            name=_state.chapter_label,
            path=None,
            error=_state.status_holder["text"],
        )
        return _ConversionControl("return", None if _state.legacy_mode else _state.outcome)

    try:
        if _state.temp_wav.exists():
            _state.temp_wav.unlink()
    except OSError:
        pass

    # **INTEGRITY VALIDATION**: Verify audio matches text
    if getattr(_state.config, "validate_audio", True):
        try:
            from .audio_validator import AudioValidator
            _state.AudioValidator = AudioValidator

            _state.validator = _state.AudioValidator()
            _state.file_valid = _state.validator.validate_audio_file(_state.converted)
            if not _state.file_valid:
                _state.recovered = await self._attempt_segment_retry(
                    _state.tts_engine,
                    _state.index,
                    _state.chapter_label,
                    _state.converted,
                    config=_state.config,
                )
                if _state.recovered:
                    _state.file_valid = _state.validator.validate_audio_file(_state.converted)
            if not _state.file_valid:
                if self.verbose:
                    print(
                        f"⚠️ Chapter {_state.index} validation warning: Invalid audio"
                    )
                if getattr(_state.config, "strict_validate", False):
                    _state.converted.unlink(missing_ok=True)
                    _state.status_holder["text"] = "Invalid audio"
                    self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
                    _state.outcome = _runtime.ChapterConversionOutcome(
                        index=_state.index,
                        name=_state.chapter_label,
                        path=None,
                        error=_state.status_holder["text"],
                    )
                    return _ConversionControl("return", None if _state.legacy_mode else _state.outcome)
            else:
                _state.normalized_len = len(_runtime.re.sub(r"\s+", " ", _state.chapter_payload or "").strip())
                if _state.normalized_len >= 5000:
                    _state.tolerance = 0.35 if _state.normalized_len < 20000 else 0.25
                    _state.validation_result = _state.validator.validate_duration(
                        _state.chapter_payload,
                        _state.converted,
                        tolerance=_state.tolerance,
                    )
                    if not _state.validation_result.is_valid:
                        _state.recovered = await self._attempt_segment_retry(
                            _state.tts_engine,
                            _state.index,
                            _state.chapter_label,
                            _state.converted,
                            config=_state.config,
                        )
                        if _state.recovered:
                            _state.validation_result = _state.validator.validate_duration(
                                _state.chapter_payload,
                                _state.converted,
                                tolerance=_state.tolerance,
                            )
                    if not _state.validation_result.is_valid:
                        if self.verbose:
                            print(
                                f"⚠️ Chapter {_state.index} validation warning: {_state.validation_result.error_message}"
                            )
                        if getattr(_state.config, "strict_validate", False):
                            _state.converted.unlink(missing_ok=True)
                            _state.status_holder["text"] = (
                                _state.validation_result.error_message or "Invalid duration"
                            )
                            self._announce_stage(
                                _state.index, _state.chapter_label, _state.status_holder["text"]
                            )
                            _state.outcome = _runtime.ChapterConversionOutcome(
                                index=_state.index,
                                name=_state.chapter_label,
                                path=None,
                                error=_state.status_holder["text"],
                            )
                            return _ConversionControl("return", None if _state.legacy_mode else _state.outcome)

                        # **AUTOMATIC RETRY**: Check for failed segments and retry
                        try:
                            if hasattr(_state.tts_engine, "get_synthesis_tracker"):
                                _state.tracker = _state.tts_engine.get_synthesis_tracker()
                                if _state.tracker:
                                    _state.missing_segments = _state.tracker.get_missing_segments()
                                    if _state.missing_segments:
                                        if self.verbose:
                                            print(
                                                f"🔄 Chapter {_state.index}: Found {len(_state.missing_segments)} failed segments, attempting retry..."
                                            )

                                        from .retry_manager import RetryManager
                                        _state.RetryManager = RetryManager

                                        _state.retry_manager = _state.RetryManager(max_retries=3)
                                        _state.temp_retry_dir = (
                                            _state.converted.parent / f"retry_temp_{_state.index}"
                                        )

                                        _state.retry_report = (
                                            await _state.retry_manager.retry_failed_segments(
                                                engine=_state.tts_engine,
                                                failed_segments=_state.missing_segments,
                                                output_path=_state.converted,
                                                temp_dir=_state.temp_retry_dir,
                                            )
                                        )

                                        if self.verbose:
                                            print(
                                                f"✓ Retry results: {_state.retry_report.successful}/{_state.retry_report.total_retried} recovered, "
                                                f"{_state.retry_report.still_failed} still failed"
                                            )

                                        # Clean up retry temp dir
                                        try:
                                            if _state.temp_retry_dir.exists():
                                                import shutil
                                                _state.shutil = shutil

                                                _state.shutil.rmtree(
                                                    _state.temp_retry_dir, ignore_errors=True
                                                )
                                        except Exception:
                                            pass

                                        if _state.retry_report.still_failed > 0:
                                            if self.verbose:
                                                print(
                                                    f"⚠️ Chapter {_state.index}: {_state.retry_report.still_failed} segments could not be recovered after retries"
                                                )
                        except Exception as e:
                            _state.e = e
                            if self.verbose:
                                print(f"⚠️ Retry mechanism error: {_state.e}")

                    # Save validation log
                    if _state.cache_dir:
                        try:
                            from .cache_manager import CacheManager
                            _state.CacheManager = CacheManager

                            _state.cm = _state.CacheManager(cache_dir=_state.cache_dir)
                            _state.validation_log_path = _state.cm.get_validation_log_path(
                                self._current_book_path or _runtime.Path("unknown.epub"), _state.index
                            )

                            # Create simple validation report
                            import json
                            _state.json = json
                            from datetime import datetime, timezone
                            _state.datetime = datetime
                            _state.timezone = timezone

                            _state.validation_data = {
                                "chapter_number": _state.index,
                                "chapter_title": _state.chapter_label,
                                "validated_at": (
                                    _state.datetime.now(_state.timezone.utc)
                                    .replace(tzinfo=None)
                                    .isoformat()
                                ),
                                "is_valid": _state.validation_result.is_valid,
                                "expected_duration": _state.validation_result.expected_duration,
                                "actual_duration": _state.validation_result.actual_duration,
                                "duration_diff_percent": _state.validation_result.duration_diff_percent,
                                "message": _state.validation_result.error_message,
                                "text_length": len(_state.chapter_payload),
                            }

                            _state.validation_log_path.parent.mkdir(
                                parents=True, exist_ok=True
                            )
                            with open(_state.validation_log_path, "w", encoding="utf-8") as _state.f:
                                _state.json.dump(
                                    _state.validation_data, _state.f, indent=2, ensure_ascii=False
                                )

                            if self.verbose:
                                print(
                                    f"✓ Chapter {_state.index} validation: "
                                    f"{_state.validation_result.actual_duration:.1f}s audio "
                                    f"(expected {_state.validation_result.expected_duration:.1f}s, "
                                    f"{_state.validation_result.duration_diff_percent:+.1f}% diff)"
                                )

                        except Exception as e:
                            _state.e = e
                            if self.verbose:
                                print(
                                    f"⚠️ Chapter {_state.index} failed to save validation log: {_state.e}"
                                )

        except ImportError:
            # audio_validator not available, skip validation
            pass
        except Exception as e:
            _state.e = e
            if self.verbose:
                print(f"⚠️ Chapter {_state.index} validation error: {_state.e}")

    # **TRANSCRIPTION VERIFICATION**: Verify audio content via speech-to-text
