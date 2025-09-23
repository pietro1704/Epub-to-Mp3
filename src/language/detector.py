# -*- coding: utf-8 -*-
"""Language detection utilities for the converter."""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass
from functools import lru_cache
from typing import Iterable, List, Optional, Sequence

try:  # pragma: no cover - optional dependency resolved at runtime
    from langdetect import DetectorFactory, LangDetectException, detect_langs
except ImportError:  # pragma: no cover - handled by caller
    DetectorFactory = None  # type: ignore
    LangDetectException = Exception  # type: ignore
    detect_langs = None  # type: ignore


DetectorFactory and detect_langs  # type: ignore  # expression keeps linters quiet when missing


@dataclass
class LanguagePrediction:
    code: str
    probability: float


@dataclass
class LanguageSegment:
    language: str
    text: str


@dataclass
class LanguageProfile:
    primary: Optional[str]
    languages: List[str]
    predictions: List[LanguagePrediction]
    analysed_chars: int

    @property
    def is_confident(self) -> bool:
        return bool(self.primary and self.predictions and self.predictions[0].probability >= 0.65)


class LanguageDetector:
    """Wrapper around ``langdetect`` with sane defaults and fallbacks."""

    SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?;:\n])\s+")

    def __init__(self) -> None:
        if DetectorFactory is not None:
            DetectorFactory.seed = 42  # pragma: no cover - deterministic results

    def detect_profile(self, texts: Sequence[str], *, max_chars: int = 16000) -> LanguageProfile:
        sample = self._prepare_sample(texts, max_chars=max_chars)
        predictions = self._detect_languages(sample)
        languages = [pred.code for pred in predictions]
        primary = languages[0] if languages else None
        return LanguageProfile(primary=primary, languages=languages, predictions=predictions, analysed_chars=len(sample))

    def detect_segments(
        self,
        text: str,
        *,
        min_segment_chars: int = 100,  # **OPTIMIZED**: Segmentos maiores (frases)
        min_probability: float = 0.7,  # **OPTIMIZED**: Maior confiança
        timeout_seconds: float = 2.0,  # **NEW**: Timeout para cada detecção
        fallback_language: str = "pt",  # **NEW**: Idioma de fallback
    ) -> List[LanguageSegment]:
        if not text or detect_langs is None:
            return [LanguageSegment(language="unknown", text=text)]

        # **OPTIMIZED**: Processar por parágrafos ao invés de frases individuais
        paragraphs = [p.strip() for p in text.split('\n\n') if p.strip()]
        if not paragraphs:
            paragraphs = [text]

        segments: List[LanguageSegment] = []
        current_lang = None
        buffer: List[str] = []

        for paragraph in paragraphs:
            # Só detectar idioma em parágrafos com tamanho mínimo
            if len(paragraph.strip()) < min_segment_chars:
                buffer.append(paragraph)
                continue

            candidate_lang = self._detect_language_with_timeout(
                paragraph,
                min_probability=min_probability,
                timeout_seconds=timeout_seconds,
                fallback_language=fallback_language
            )
            if not candidate_lang or candidate_lang == "unknown":
                buffer.append(paragraph)
                continue

            if current_lang is None:
                current_lang = candidate_lang
                buffer.append(paragraph)
                continue

            if candidate_lang != current_lang and buffer:
                merged = "\n".join(buffer).strip()  # **CHANGED**: Manter quebras de parágrafo
                if merged:
                    segments.append(LanguageSegment(language=current_lang, text=merged))
                buffer = [paragraph]
                current_lang = candidate_lang
            else:
                buffer.append(paragraph)

        if buffer:
            merged = "\n".join(buffer).strip()  # **CHANGED**: Manter quebras de parágrafo
            if merged:
                language = current_lang or "unknown"
                segments.append(LanguageSegment(language=language, text=merged))

        if not segments:
            fallback_lang = self._detect_language_with_timeout(
                text,
                timeout_seconds=timeout_seconds,
                fallback_language=fallback_language
            )
            return [LanguageSegment(language=fallback_lang, text=text)]

        refined_segments: List[LanguageSegment] = []
        for segment in segments:
            stripped = segment.text.strip()
            if len(stripped) < min_segment_chars:
                refined_segments.append(LanguageSegment(language=segment.language, text=stripped))
                continue
            language = self._detect_language_with_timeout(
                stripped,
                min_probability=min_probability,
                timeout_seconds=timeout_seconds,
                fallback_language=fallback_language
            ) or segment.language
            refined_segments.append(LanguageSegment(language=language or "unknown", text=stripped))

        return self._merge_adjacent(refined_segments)

    def _detect_languages(self, text: str, *, top_n: int = 3) -> List[LanguagePrediction]:
        if not text or detect_langs is None:
            return []

        try:
            candidates = detect_langs(text)
        except LangDetectException:
            return []

        predictions: List[LanguagePrediction] = []
        for candidate in candidates[:top_n]:
            code = self._normalise_code(candidate.lang)
            if not code:
                continue
            predictions.append(LanguagePrediction(code=code, probability=float(candidate.prob)))
        return predictions

    def _detect_language_simple(self, text: str, *, min_probability: float = 0.4) -> str:
        predictions = self._detect_languages(text, top_n=1)
        if not predictions:
            return "unknown"
        best = predictions[0]
        if best.probability < min_probability:
            return "unknown"
        return best.code

    def _detect_language_with_timeout(
        self,
        text: str,
        *,
        min_probability: float = 0.4,
        timeout_seconds: float = 2.0,
        fallback_language: str = "pt"
    ) -> str:
        """Detect language with timeout and fallback."""
        if not text or len(text.strip()) < 10:
            return fallback_language

        try:
            # Run detection in a thread to enable timeout
            import concurrent.futures
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                future = executor.submit(self._detect_language_simple, text, min_probability=min_probability)
                try:
                    result = future.result(timeout=timeout_seconds)
                    if result == "unknown":
                        return fallback_language
                    return result
                except concurrent.futures.TimeoutError:
                    print(f"⚠️ Timeout na detecção de idioma ({timeout_seconds}s) - usando fallback: {fallback_language}")
                    return fallback_language
        except Exception as e:
            print(f"⚠️ Erro na detecção de idioma: {e} - usando fallback: {fallback_language}")
            return fallback_language

    @staticmethod
    def _merge_adjacent(segments: Iterable[LanguageSegment]) -> List[LanguageSegment]:
        merged: List[LanguageSegment] = []
        previous: Optional[LanguageSegment] = None
        for segment in segments:
            if previous and segment.language == previous.language:
                previous = LanguageSegment(language=previous.language, text=f"{previous.text} {segment.text}".strip())
                merged[-1] = previous
            else:
                merged.append(segment)
                previous = segment
        return merged

    @staticmethod
    def _normalise_code(code: Optional[str]) -> str:
        if not code:
            return ""
        clean = code.replace("_", "-").strip().lower()
        if not clean:
            return ""
        return clean.split('-', 1)[0]

    @staticmethod
    def _prepare_sample(texts: Sequence[str], *, max_chars: int) -> str:
        if not texts:
            return ""
        sample_parts: List[str] = []
        total = 0
        for text in texts:
            if not text:
                continue
            remaining = max_chars - total
            if remaining <= 0:
                break
            snippet = text[:remaining]
            sample_parts.append(snippet)
            total += len(snippet)
        return "\n".join(sample_parts)


@lru_cache(maxsize=1)
def get_language_detector() -> LanguageDetector:
    return LanguageDetector()


__all__ = [
    "LanguageDetector",
    "LanguagePrediction",
    "LanguageProfile",
    "LanguageSegment",
    "get_language_detector",
]

