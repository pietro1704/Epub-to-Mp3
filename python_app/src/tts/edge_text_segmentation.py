# -*- coding: utf-8 -*-
"""Text segmentation and prosody for Edge requests."""

from __future__ import annotations

from typing import List, Optional


class EdgeTextSegmentation:
    """Own the text segmentation and prosody for Edge requests."""

    def _calculate_timeout(self, text: str) -> int:
        """Estimate a safe upper bound for synthesis time in seconds.

        Optimized: more aggressive timeout to fail fast in case of problems.
        """
        if not text:
            return 60  # 60s default for empty text

        estimated = max(self._estimate_duration(text), 5.0)

        # Timeout = estimated duration + 40% buffer + 20s fixed
        # More aggressive to avoid long waits
        timeout = estimated * 1.4 + 20.0

        # Limits: minimum 45s, dynamic maximum to avoid cutting long segments
        timeout = max(timeout, 45.0)
        timeout_cap = max(300.0, self._active_segment_seconds() * 1.5 + 60.0)
        timeout = min(timeout, timeout_cap)

        return int(round(timeout))

    def _active_segment_seconds(self) -> float:
        """Return the current target while preserving the configured hard limit."""
        if self._segment_duration_policy.enabled:
            return min(
                self._segment_duration_policy.target_seconds,
                self._segment_duration_policy.hard_max_seconds,
            )
        return self._max_segment_seconds

    def _chunk_text_with_dialogue(self, base_voice: str, text: str) -> list[tuple[str, str]]:
        """Like ``_chunk_text`` but routes dialogue spans to ``character_voice``.

        Falls back to plain single-voice chunking when:

        - the feature is off (``enable_character_voices`` is False);
        - narrator and character voices are identical (no point splitting);
        - the dialogue splitter import fails (defensive — splitter is
          self-contained but the engine must keep working).
        """
        if not self.enable_character_voices:
            return self._chunk_text(base_voice, text)
        if self.narrator_voice == self.character_voice:
            return self._chunk_text(base_voice, text)
        try:
            from ..dialogue_splitter import split_into_dialogue_spans
        except Exception:
            return self._chunk_text(base_voice, text)

        spans = split_into_dialogue_spans(text)
        if not spans:
            return []
        # When the language pipeline picked a non-default base_voice (e.g. an
        # English passage in a PT-BR book), keep using it for narrator spans
        # so we don't shove a Portuguese voice onto English text. Character
        # spans always use the dedicated character voice — multilingual
        # voices like ThalitaMultilingualNeural handle the language switch.
        narrator_voice = base_voice if base_voice != self.voice else self.narrator_voice
        out: list[tuple[str, str]] = []
        for span in spans:
            voice = self.character_voice if span.role == "character" else narrator_voice
            out.extend(self._chunk_text(voice, span.text))
        return out

    def _prepare_segments(self, text: str) -> list[tuple[str, str]]:
        from . import edge_engine as _runtime
        if text is None:
            return [(self.voice, "")]

        # Preserve markup for language detection; clean after parsing
        cleaned_text = text or ""

        if _runtime.LanguageMarkup is None:
            base_text = (
                _runtime.TextFormattingProcessor.clean_tts_text(cleaned_text)
                if _runtime.TextFormattingProcessor
                else cleaned_text
            )
            return self._chunk_text_with_dialogue(self.voice, base_text)

        try:
            lowered = cleaned_text.lower()
            if "[[lang:" not in lowered:
                base_text = (
                    _runtime.TextFormattingProcessor.clean_tts_text(cleaned_text)
                    if _runtime.TextFormattingProcessor
                    else cleaned_text
                )
                return self._chunk_text_with_dialogue(self.voice, base_text)

            segments = _runtime.LanguageMarkup.parse(cleaned_text, self.primary_language)
            if segments is None:
                base_text = (
                    _runtime.TextFormattingProcessor.clean_tts_text(cleaned_text)
                    if _runtime.TextFormattingProcessor
                    else cleaned_text
                )
                return self._chunk_text_with_dialogue(self.voice, base_text)

            if len(segments) > 100:
                simplified = _runtime.LanguageMarkup.strip(cleaned_text) if _runtime.LanguageMarkup else cleaned_text
                base_text = (
                    _runtime.TextFormattingProcessor.clean_tts_text(simplified)
                    if _runtime.TextFormattingProcessor
                    else simplified
                )
                return self._chunk_text_with_dialogue(self.voice, base_text)

            prepared: list[tuple[str, str]] = []
            for segment in segments:
                if segment is None:
                    continue
                segment_text = getattr(segment, "text", "") or ""
                segment_text = segment_text.strip()
                if not segment_text:
                    continue
                lang = (segment.language or "").split("-", 1)[0].lower()
                voice = self.language_voices.get(lang) or self.voice
                segment_clean = (
                    _runtime.TextFormattingProcessor.clean_tts_text(segment_text)
                    if _runtime.TextFormattingProcessor
                    else segment_text
                )
                prepared.extend(self._chunk_text_with_dialogue(voice, segment_clean))

            if not prepared:
                return self._chunk_text_with_dialogue(self.voice, cleaned_text)

            return prepared

        except Exception:
            fallback = (
                _runtime.TextFormattingProcessor.clean_tts_text(text or "")
                if _runtime.TextFormattingProcessor
                else (text or "")
            )
            return self._chunk_text_with_dialogue(self.voice, fallback)

    def _apply_chunk_prosody(self, text: str, rate_increase: str = "+50%") -> str:
        """
        Apply SSML prosody tags to an individual chunk to compensate for Edge-TTS pauses.

        NOTE: Function disabled - Edge-TTS ignores SSML prosody tags.
        Kept for future compatibility if Edge-TTS starts supporting them.

        Args:
            text: Chunk text
            rate_increase: Percentage increase in speech rate (not used)

        Returns:
            Original text without modifications
        """
        # DISABLED: Edge-TTS does not respect SSML prosody tags
        # Tests showed that tags do not reduce audio duration
        # Returns text without modifications
        return text

    def _chunk_text(
        self, voice: str, text: str, chunk_size: Optional[int] = None
    ) -> list[tuple[str, str]]:
        """Split long text into smaller blocks respecting approximate sentence and duration limits."""
        from . import edge_engine as _runtime
        if not text:
            return []

        stripped = text.strip()
        if not stripped:
            return []

        # If converter injected a precomputed plan, reuse it
        pre_segments = getattr(self, "_precomputed_segments", None)
        if pre_segments and isinstance(pre_segments, list):
            cleaned_segments: List[str] = []
            try:
                current_len = len(stripped)
            except Exception:
                current_len = 0
            for seg in pre_segments:
                if not isinstance(seg, str):
                    continue
                seg_text = seg.strip()
                if not seg_text:
                    continue
                cleaned_segments.append(self._sanitize_for_edge(seg_text))
            if cleaned_segments:
                total_len = sum(len(seg) for seg in cleaned_segments)
                # Guard against stale plans that don't match the current payload size.
                if current_len and total_len:
                    ratio = total_len / max(current_len, 1)
                    if ratio < 0.75 or ratio > 1.25:
                        cleaned_segments = []
                if cleaned_segments:
                    refined: List[tuple[str, str]] = []
                    for seg_text in cleaned_segments:
                        refined.extend(self._split_if_needed(voice, seg_text))

                    # Apply prosody to precomputed segments
                    prosody_refined: List[tuple[str, str]] = []
                    for seg_voice, seg_text in refined:
                        wrapped_text = self._apply_chunk_prosody(seg_text)
                        prosody_refined.append((seg_voice, wrapped_text))

                    return prosody_refined

        try:
            active_chunk_limit = (
                int(chunk_size) if chunk_size is not None else self._chunk_char_limit
            )
        except (TypeError, ValueError):
            active_chunk_limit = self._chunk_char_limit
        active_chunk_limit = max(_runtime._SAFE_CHUNK_MIN, active_chunk_limit)

        # Guardrail: shrink chunk size after rate limits or for very long payloads
        safe_limit_env = _runtime.os.getenv("EDGE_SAFE_SEGMENT_CHARS")
        safe_limit = None
        if safe_limit_env:
            try:
                safe_limit = int(safe_limit_env)
            except ValueError:
                safe_limit = None
        if safe_limit is None:
            safe_limit = 3600
        safe_limit = max(_runtime._SAFE_CHUNK_MIN, min(safe_limit, _runtime._SAFE_CHUNK_MAX))

        if _runtime._edge_rate_limit_count > 0:
            adjusted = min(active_chunk_limit, safe_limit)
            if adjusted != active_chunk_limit and self.verbose:
                self._log(f"🔍 Edge: chunk reduced to {adjusted} chars (rate limit / long chapter)")
            active_chunk_limit = adjusted

        if len(stripped) <= active_chunk_limit:
            base_chunks: List[tuple[str, str]] = [(voice, stripped)]
        else:
            base_chunks = []
            start = 0
            length = len(stripped)

            while start < length:
                end = min(start + active_chunk_limit, length)
                chunk = stripped[start:end]

                if end < length:
                    last_period = chunk.rfind(".")
                    last_exclamation = chunk.rfind("!")
                    last_question = chunk.rfind("?")
                    break_point = max(last_period, last_exclamation, last_question)
                    if break_point > active_chunk_limit * 0.5:
                        chunk = chunk[: break_point + 1]
                        end = start + len(chunk)

                if chunk:
                    base_chunks.append((voice, chunk))
                start = end

        refined: List[tuple[str, str]] = []
        for chunk_voice, chunk_text in base_chunks:
            refined.extend(self._split_if_needed(chunk_voice, chunk_text))

        # Apply prosody rate to each chunk to compensate for Edge-TTS pauses
        # This is done per-chunk because Edge-TTS processes each chunk independently
        prosody_refined: List[tuple[str, str]] = []
        for chunk_voice, chunk_text in refined:
            # Wrap chunk in prosody tags if it has high sentence density
            wrapped_text = self._apply_chunk_prosody(chunk_text)
            prosody_refined.append((chunk_voice, wrapped_text))

        return prosody_refined

    def _split_if_needed(self, voice: str, text: str) -> List[tuple[str, str]]:
        """Ensure each chunk respects the estimated duration limit."""
        if not text:
            return []

        duration = self._estimate_duration(text)
        active_segment_seconds = self._active_segment_seconds()
        if duration <= active_segment_seconds:
            return [(voice, text)]

        segments = self._split_text_by_duration(text, active_segment_seconds)
        return [(voice, segment) for segment in segments if segment]

    def _split_text_by_duration(self, text: str, max_seconds: float) -> List[str]:
        """Split text using sentence boundaries and estimated duration."""
        from . import edge_engine as _runtime
        sentences = _runtime._SENTENCE_SPLIT_RE.split(text)
        segments: List[str] = []
        buffer: List[str] = []

        for sentence in sentences:
            trimmed = sentence.strip()
            if not trimmed:
                continue

            candidate = f"{' '.join(buffer)} {trimmed}".strip() if buffer else trimmed
            if buffer and self._estimate_duration(candidate) > max_seconds:
                segments.append(" ".join(buffer).strip())
                buffer = [trimmed]
            else:
                buffer.append(trimmed)

        if buffer:
            segments.append(" ".join(buffer).strip())

        refined: List[str] = []
        for segment in segments:
            if not segment:
                continue
            if self._estimate_duration(segment) <= max_seconds or len(segment.split()) <= 1:
                refined.append(segment)
            else:
                refined.extend(self._split_by_words(segment, max_seconds))

        return [segment for segment in refined if segment]

    def _split_by_words(self, text: str, max_seconds: float) -> List[str]:
        """Fallback splitter when a single sentence still exceeds the duration limit."""
        from . import edge_engine as _runtime
        words = [word for word in text.split() if word]
        if not words:
            return []

        max_words = max(int((max_seconds / 60.0) * self._words_per_minute), _runtime.MIN_WORDS_PER_SEGMENT)
        segments: List[str] = []

        for start in range(0, len(words), max_words):
            segment_words = words[start : start + max_words]
            segment_text = " ".join(segment_words).strip()
            if segment_text:
                segments.append(segment_text)

        return segments

    def _estimate_duration(self, text: str) -> float:
        """Estimate spoken duration in seconds for the provided text."""
        from . import edge_engine as _runtime
        try:
            estimated = _runtime.TextValidator.estimate_duration(
                text, words_per_minute=self._words_per_minute
            )
            return float(estimated or 0.0)
        except Exception:
            words = [word for word in (text or "").split() if word]
            if not words:
                return 0.0
            return (len(words) / max(self._words_per_minute, 1)) * 60.0

    def _supports_emphasis(self) -> bool:
        voice = (self.voice or "").lower()
        return "neural" in voice or voice.startswith("pt-br")
