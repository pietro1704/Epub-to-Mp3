# -*- coding: utf-8 -*-
"""Utilities to mark text with language hints and build engine payloads."""

from __future__ import annotations

import html
import re
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional

from .codes import ensure_bcp47
from .detector import LanguageDetector, LanguageSegment


LANG_START_RE = re.compile(r"\[\[lang:([a-zA-Z\-]{2,15})\]\]", re.IGNORECASE)
LANG_END_RE = re.compile(r"\[\[/lang\]\]", re.IGNORECASE)


@dataclass(slots=True)
class MarkedSegment:
    language: str
    text: str


class LanguageMarkup:
    """Apply and interpret language markup in chapter text."""

    def __init__(self, detector: Optional[LanguageDetector] = None) -> None:
        self.detector = detector or LanguageDetector()

    def annotate(self, text: str, default_language: Optional[str]) -> str:
        if not text:
            return text
        default_language = (default_language or "unknown").lower()
        default_short = default_language.split("-", 1)[0]

        # **OPTIMIZED**: Pular detecção automática para textos complexos ou muito longos
        if len(text) > 15000:  # Textos muito longos
            return text

        # Contar tags de idioma existentes - se muitas, provavelmente já processado
        existing_tags = text.lower().count("[[lang:")
        if existing_tags > 20:  # Se já tem muitas tags, não reprocessar
            return text

        try:
            # **TIMEOUT**: Aplicar timeout na detecção de perfil
            import concurrent.futures
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                future = executor.submit(self.detector.detect_profile, [text], max_chars=4000)
                try:
                    profile = future.result(timeout=3.0)  # 3 segundos max
                except concurrent.futures.TimeoutError:
                    print(f"⚠️ Timeout na detecção de perfil de idioma - usando idioma padrão: {default_short}")
                    return text
        except Exception as e:
            print(f"⚠️ Erro na detecção de perfil: {e} - usando idioma padrão: {default_short}")
            return text

        profile_languages = {
            (lang or "").split("-", 1)[0]
            for lang in profile.languages
            if lang and lang != "unknown"
        }

        if not profile_languages or (default_short and profile_languages <= {default_short}):
            return text

        try:
            # **TIMEOUT**: Aplicar timeout na segmentação
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                future = executor.submit(
                    self.detector.detect_segments,
                    text,
                    timeout_seconds=1.5,  # Timeout mais agressivo para segmentos
                    fallback_language=default_short
                )
                try:
                    segments = future.result(timeout=5.0)  # 5 segundos max total
                except concurrent.futures.TimeoutError:
                    print(f"⚠️ Timeout na segmentação de idioma - usando idioma padrão: {default_short}")
                    return text
        except Exception as e:
            print(f"⚠️ Erro na segmentação: {e} - usando idioma padrão: {default_short}")
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
            # **OPTIMIZED**: Só aplicar marcação em segmentos grandes e confiáveis
            if segment_lang not in {"unknown", default_short}:
                # Verificar se o segmento é grande o suficiente para marcação
                if len(segment.text.strip()) < 150:  # **CHANGED**: Mínimo 150 chars (era 40)
                    segment_lang = default_short
                else:
                    # **TIMEOUT**: Confirmar com timeout para evitar travamento
                    try:
                        import concurrent.futures
                        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                            future = executor.submit(
                                self.detector._detect_language_simple,
                                segment.text,
                                min_probability=0.8
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
        segments: List[MarkedSegment] = []
        cursor = 0
        current_language = default_language

        while cursor < len(text):
            start_match = LANG_START_RE.search(text, cursor)
            end_match = LANG_END_RE.search(text, cursor)

            if start_match and (not end_match or start_match.start() < end_match.start()):
                if start_match.start() > cursor:
                    raw = text[cursor:start_match.start()]
                    segments.append(MarkedSegment(language=current_language, text=raw))
                current_language = start_match.group(1).lower()
                cursor = start_match.end()
                continue

            if end_match:
                raw = text[cursor:end_match.start()]
                segments.append(MarkedSegment(language=current_language, text=raw))
                current_language = default_language
                cursor = end_match.end()
                continue

            raw = text[cursor:]
            segments.append(MarkedSegment(language=current_language, text=raw))
            break

        return LanguageMarkup._merge_segments(segments)

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

        ssml_parts: List[str] = ["<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xmlns:mstts=\"http://www.w3.org/2001/mstts\">"]

        for segment in segments:
            text = segment.text
            if not text.strip():
                continue
            voice = language_voices.get(segment.language, default_voice)
            lang_code = ensure_bcp47(segment.language if segment.language != "unknown" else default_language)
            safe_text = html.escape(text)
            if lang_code:
                ssml_parts.append(
                    f"<voice name=\"{voice}\"><lang xml:lang=\"{lang_code}\">{safe_text}</lang></voice>"
                )
            else:
                ssml_parts.append(f"<voice name=\"{voice}\">{safe_text}</voice>")

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
