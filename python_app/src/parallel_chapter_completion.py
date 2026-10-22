# -*- coding: utf-8 -*-
"""Parallel chapter completion."""

from __future__ import annotations

from .conversion_control import ConversionControl as _ConversionControl


async def _parallel_chapter_completion(self, _state):
    from . import converter as _runtime
    if (
        getattr(_state.config, "verify_transcription", False)
        and _state.converted
        and _state.converted.exists()
    ):
        try:
            from .transcription_verifier import TranscriptionVerifier
            _state.TranscriptionVerifier = TranscriptionVerifier
            from .transcription_verifier import is_available as _whisper_available
            _state._whisper_available = _whisper_available

            if _state._whisper_available():
                if (
                    not hasattr(self, "_transcription_verifier")
                    or self._transcription_verifier is None
                ):
                    # Don't force language — let Whisper auto-detect per chapter
                    self._transcription_verifier = _state.TranscriptionVerifier(
                        model_size=getattr(_state.config, "transcription_model", "medium"),
                        language=None,
                    )

                _state.status_holder["text"] = "🔍 Verificando transcription..."
                self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])

                _state.vr = self._transcription_verifier.verify_chapter(
                    _state.converted, _state.chapter_payload
                )

                if _state.vr.passed:
                    if self.verbose:
                        print(
                            f"✅ Chapter {_state.index} transcription OK: "
                            f"{_state.vr.similarity_score:.1%} similarity"
                        )
                else:
                    if getattr(_state.vr, "partial", False):
                        # Timeout during transcription - audio likely fine, just too large
                        print(
                            f"⚠️ Chapter {_state.index} partial verification (timeout): "
                            f"{_state.vr.similarity_score:.1%} - mantendo MP3"
                        )
                    else:
                        print(
                            f"❌ Chapter {_state.index} transcription FAILED: "
                            f"{_state.vr.similarity_score:.1%} similarity (minimum {self._transcription_verifier.SIMILARITY_THRESHOLD:.0%})"
                        )
                        if self.verbose:
                            print(f"   {_state.vr.details}")
                        # Delete bad audio and signal failure for retry
                        _state.converted.unlink(missing_ok=True)
                        _state.status_holder["text"] = (
                            f"❌ Transcription diverges: {_state.vr.similarity_score:.1%} similarity"
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
            elif self.verbose:
                print(
                    "⚠️ faster-whisper not installed, skipping transcription verification"
                )
        except Exception as e:
            _state.e = e
            if self.verbose:
                print(f"⚠️ Chapter {_state.index} transcription verification error: {_state.e}")

    _state.status_holder["text"] = self.loc.t("status_complete")
    self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
    if getattr(_state.config, "listen", False):
        _state.status_holder["text"] = self.loc.t("status_playing")
        self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
        _state.played = await self.audio_processor.play_audio(_state.converted)
        _state.status_holder["text"] = (
            self.loc.t("status_complete")
            if _state.played
            else self.loc.t("status_play_unavailable")
        )
        self._announce_stage(_state.index, _state.chapter_label, _state.status_holder["text"])
    self._cache_audio(
        _state.cache_dir, _state.converted, _state.chapter, _state.index, _state.config, text_root=_state.output_dir
    )
    # Post-validate after each chapter (lightweight, best-effort)
    await self._auto_validate_output(_state.output_dir, stage=f"chapter-{_state.index}")
    _state.outcome = _runtime.ChapterConversionOutcome(index=_state.index, name=_state.chapter_label, path=_state.converted)
    return _ConversionControl("return", _state.converted if _state.legacy_mode else _state.outcome)
