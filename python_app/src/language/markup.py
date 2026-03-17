# -*- coding: utf-8 -*-
"""Utilities to mark text with language hints and build engine payloads."""

from __future__ import annotations

import html
import re
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional

from .codes import ensure_bcp47
from .detector import LanguageDetector

LANG_START_RE = re.compile(r"\[\[lang:([a-zA-Z\-]{2,15})\]\]", re.IGNORECASE)
LANG_END_RE = re.compile(r"\[\[/lang\]\]", re.IGNORECASE)

# Text formatting patterns for TTS guidance (not spoken)
FORMATTING_PATTERNS = [
    # Italic text - add slight emphasis
    (re.compile(r"<i>(.*?)</i>", re.IGNORECASE | re.DOTALL), r"[[emphasis:mild]]\1[[/emphasis]]"),
    (re.compile(r"<em>(.*?)</em>", re.IGNORECASE | re.DOTALL), r"[[emphasis:mild]]\1[[/emphasis]]"),
    # Bold text - add strong emphasis
    (re.compile(r"<b>(.*?)</b>", re.IGNORECASE | re.DOTALL), r"[[emphasis:strong]]\1[[/emphasis]]"),
    (
        re.compile(r"<strong>(.*?)</strong>", re.IGNORECASE | re.DOTALL),
        r"[[emphasis:strong]]\1[[/emphasis]]",
    ),
    # Quotations - add pause before and after
    (re.compile(r'"([^"]*)"'), r'[[pause:short]]"\1"[[pause:short]]'),
    (re.compile(r'"([^"]*)"'), r'[[pause:short]]"\1"[[pause:short]]'),
    # Parentheses - slight pause and lower tone
    (re.compile(r"\(([^)]*)\)"), r"[[pause:short]][[tone:lower]](\1)[[/tone]][[pause:short]]"),
    # Titles and paragraph breaks - add natural pauses
    (re.compile(r"\n\n+"), r"\n\n[[pause:long]]"),
    (
        re.compile(r"^([A-ZÁÀÂÃÉÊÍÓÔÕÚÇ][A-ZÁÀÂÃÉÊÍÓÔÕÚÇ\s]+)$", re.MULTILINE),
        r"[[pause:medium]]\1[[pause:long]]",
    ),
]


@dataclass(slots=True)
class MarkedSegment:
    language: str
    text: str


class LanguageMarkup:
    """Apply and interpret language markup in chapter text."""

    _MIXED_LANGUAGE_SHORT_TEXT_MAX_CHARS = 400
    _MIXED_LANGUAGE_SHORT_SEGMENT_MAX_CHARS = 120

    def __init__(self, detector: Optional[LanguageDetector] = None) -> None:
        self.detector = detector or LanguageDetector()

    def apply_formatting_markup(self, text: str) -> str:
        """Apply text formatting markup for TTS guidance (emphasis, pauses, etc.)"""
        return text

    def annotate(
        self,
        text: str,
        default_language: Optional[str],
        *,
        prioritize_primary_language: bool = True,
    ) -> str:
        if not text:
            return text

        # Apply formatting markup first
        text = self.apply_formatting_markup(text)

        default_language = (default_language or "unknown").lower()
        default_short = default_language.split("-", 1)[0]

        # **OPTIMIZED**: Skip auto-detection for complex or very long texts
        if len(text) > 15000:  # Textos muito longos
            return text

        # Count existing language tags — if many, probably already processed
        existing_tags = text.lower().count("[[lang:")
        if existing_tags > 20:  # Already has many tags, skip reprocessing
            return text

        try:
            # **TIMEOUT**: Apply timeout to profile detection
            import concurrent.futures

            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                future = executor.submit(self.detector.detect_profile, [text], max_chars=4000)
                try:
                    profile = future.result(timeout=3.0)  # 3 segundos max
                except concurrent.futures.TimeoutError:
                    print(f"⚠️ Timeout detecting language profile - using default: {default_short}")
                    return text
        except Exception as e:
            print(f"⚠️ Profile detection error: {e} — using default language: {default_short}")
            return text

        def _short(code: Optional[str]) -> str:
            if not code:
                return ""
            return code.split("-", 1)[0].lower()

        profile_languages = {
            _short(lang) for lang in profile.languages if lang and lang != "unknown"
        }

        predictions = list(getattr(profile, "predictions", []) or [])
        primary_prediction = next(
            (pred for pred in predictions if _short(pred.code) == default_short), None
        )
        best_alternative = next(
            (pred for pred in predictions if _short(pred.code) != default_short), None
        )

        if default_short and default_short not in {"", "unknown", "auto"}:
            allow_mixed = best_alternative is not None
            if best_alternative:
                alt_prob = best_alternative.probability
                primary_prob = primary_prediction.probability if primary_prediction else 0.0
                # Require strong evidence before overriding configured primary language
                if alt_prob < 0.35:
                    allow_mixed = False
                elif primary_prediction and primary_prob >= 0.45:
                    if alt_prob <= primary_prob and alt_prob < 0.75:
                        allow_mixed = False
            if not allow_mixed:
                return text

        if not profile_languages or (default_short and profile_languages <= {default_short}):
            return text

        try:
            # **TIMEOUT**: Apply timeout to segmentation
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                primary_language = default_short if prioritize_primary_language else None
                future = executor.submit(
                    self.detector.detect_segments,
                    text,
                    timeout_seconds=1.5,  # More aggressive timeout for short segments
                    fallback_language=default_short,
                    primary_language=primary_language,
                )
                try:
                    segments = future.result(timeout=5.0)  # 5 segundos max total
                except concurrent.futures.TimeoutError:
                    print(
                        f"⚠️ Language segmentation timeout - using default language: {default_short}"
                    )
                    return text
        except Exception as e:
            print(f"⚠️ Segmentation error: {e} — using default language: {default_short}")
            return text

        languages = {
            (segment.language or "").split("-", 1)[0]
            for segment in segments
            if segment.language and segment.language != "unknown"
        }
        if default_short:
            languages = {lang for lang in languages if lang != default_short}
        if not languages:
            return text

        total_length = sum(len(segment.text or "") for segment in segments if segment.text)
        if default_short and total_length > 0:
            # **OPTIMIZED**: Apenas marcar se tiver mais idioma estrangeiro
            non_default = sum(
                len(segment.text or "")
                for segment in segments
                if (segment.language or "").split("-", 1)[0] not in {default_short, "unknown"}
            )
            share = non_default / total_length if total_length else 0.0
            if share < 0.15:  # **CHANGED**: Threshold maior (era 0.08)
                return text

        parts: List[str] = []
        for segment in segments:
            if not segment.text:
                continue
            segment_lang = (segment.language or "unknown").split("-", 1)[0]
            # **OPTIMIZED**: Only apply markup to large, confident segments
            if segment_lang not in {"unknown", default_short}:
                # Check if the segment is large enough for markup
                if len(segment.text.strip()) < 150:  # **CHANGED**: Minimum 150 chars (was 40)
                    segment_lang = default_short
                else:
                    # **TIMEOUT**: Confirm with timeout to avoid deadlock
                    try:
                        import concurrent.futures

                        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                            future = executor.submit(
                                self.detector._detect_language_simple,
                                segment.text,
                                min_probability=0.8,
                            )
                            try:
                                confirmed = future.result(timeout=1.0)  # 1 segundo max
                            except concurrent.futures.TimeoutError:
                                confirmed = default_short  # Fallback em caso de timeout
                    except Exception:
                        confirmed = default_short  # Fallback em caso de erro

                    if confirmed in {"unknown", default_short}:
                        segment_lang = default_short
            if segment_lang in ("unknown", default_short):
                parts.append(segment.text)
            else:
                parts.append(f"[[lang:{segment_lang}]]{segment.text}[[/lang]]")
        output = "".join(part for part in parts if part)
        return output.strip() or text

    @staticmethod
    def parse(text: str, default_language: Optional[str]) -> List[MarkedSegment]:
        if not text:
            return []

        default_language = (default_language or "unknown").lower()
        default_short = default_language.split("-", 1)[0] if default_language else "unknown"
        has_explicit_tags = bool(LANG_START_RE.search(text))
        segments: List[MarkedSegment] = []
        cursor = 0
        current_language = default_language

        while cursor < len(text):
            start_match = LANG_START_RE.search(text, cursor)
            end_match = LANG_END_RE.search(text, cursor)

            if start_match and (not end_match or start_match.start() < end_match.start()):
                if start_match.start() > cursor:
                    raw = text[cursor : start_match.start()]
                    segments.append(MarkedSegment(language=current_language, text=raw))
                current_language = start_match.group(1).lower()
                cursor = start_match.end()
                continue

            if end_match:
                raw = text[cursor : end_match.start()]
                segments.append(MarkedSegment(language=current_language, text=raw))
                current_language = default_language
                cursor = end_match.end()
                continue

            raw = text[cursor:]
            segments.append(MarkedSegment(language=current_language, text=raw))
            break

        merged = LanguageMarkup._merge_segments(segments)
        if not merged or default_short in {"", "unknown"}:
            return merged
        if has_explicit_tags:
            # Preserve idiomas declarados via [[lang:xx]] mesmo para textos curtos
            return merged

        languages = {
            (segment.language or "").split("-", 1)[0].lower()
            for segment in merged
            if segment.language and segment.language != "unknown"
        }
        if len(languages) <= 1:
            return merged

        total_chars = sum(len(segment.text or "") for segment in merged)
        if total_chars <= LanguageMarkup._MIXED_LANGUAGE_SHORT_TEXT_MAX_CHARS:
            return [
                MarkedSegment(language=default_language, text=segment.text) for segment in merged
            ]
        if default_short not in languages:
            return merged

        normalized: List[MarkedSegment] = []
        for segment in merged:
            segment_text = segment.text or ""
            segment_lang = (segment.language or "unknown").split("-", 1)[0].lower()
            if segment_lang in {"unknown", default_short}:
                normalized.append(MarkedSegment(language=default_language, text=segment_text))
                continue
            if len(segment_text.strip()) <= LanguageMarkup._MIXED_LANGUAGE_SHORT_SEGMENT_MAX_CHARS:
                normalized.append(MarkedSegment(language=default_language, text=segment_text))
            else:
                normalized.append(MarkedSegment(language=segment.language, text=segment_text))

        return LanguageMarkup._merge_segments(normalized)

    @staticmethod
    def strip(text: str) -> str:
        if not text:
            return ""
        text = LANG_START_RE.sub("", text)
        text = LANG_END_RE.sub("", text)
        return text

    @staticmethod
    def to_edge_ssml(
        segments: Iterable[MarkedSegment],
        default_voice: str,
        language_voices: Optional[Dict[str, str]] = None,
        default_language: Optional[str] = None,
    ) -> Optional[str]:
        segments = list(segments)
        if not segments:
            return None

        language_voices = language_voices or {}
        default_language = (default_language or "unknown").lower()

        ssml_parts: List[str] = [
            '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="http://www.w3.org/2001/mstts">'
        ]

        for segment in segments:
            text = segment.text
            if not text.strip():
                continue
            voice = language_voices.get(segment.language, default_voice)
            lang_code = ensure_bcp47(
                segment.language if segment.language != "unknown" else default_language
            )
            safe_text = html.escape(text)
            if lang_code:
                ssml_parts.append(
                    f'<voice name="{voice}"><lang xml:lang="{lang_code}">{safe_text}</lang></voice>'
                )
            else:
                ssml_parts.append(f'<voice name="{voice}">{safe_text}</voice>')

        ssml_parts.append("</speak>")
        return "".join(ssml_parts)

    @staticmethod
    def _merge_segments(segments: Iterable[MarkedSegment]) -> List[MarkedSegment]:
        merged: List[MarkedSegment] = []
        previous: Optional[MarkedSegment] = None
        for segment in segments:
            if previous and segment.language == previous.language:
                merged[-1] = MarkedSegment(
                    language=previous.language,
                    text=f"{previous.text}{segment.text}",
                )
                previous = merged[-1]
            else:
                merged.append(segment)
                previous = segment
        return merged


__all__ = ["LanguageMarkup", "MarkedSegment"]
