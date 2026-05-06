# -*- coding: utf-8 -*-
"""Language detection utilities for the converter."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from functools import lru_cache
from typing import Dict, Iterable, List, Optional, Sequence

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
    # Per-process cache for repeated identical paragraphs within a run.
    # langdetect's ThreadPoolExecutor + LangDetectException probing is the
    # heaviest CPU step in EPUB ingest for monolingual books — every call
    # spins up a worker and re-trains. Hash-keyed memoization eliminates
    # the duplicate work without changing detection semantics.
    _DETECT_CACHE_LIMIT = 4096
    _detect_cache: Dict[str, str] = {}

    def __init__(self) -> None:
        if DetectorFactory is not None:
            DetectorFactory.seed = 42  # pragma: no cover - deterministic results

    @classmethod
    def clear_cache(cls) -> None:
        """Drop the per-process detection memo. Useful between CI runs and
        when test fixtures stub the underlying detector."""
        cls._detect_cache.clear()

    def detect_profile(self, texts: Sequence[str], *, max_chars: int = 16000) -> LanguageProfile:
        sample = self._prepare_sample(texts, max_chars=max_chars)
        predictions = self._detect_languages(sample)
        languages = [pred.code for pred in predictions]
        primary = languages[0] if languages else None
        return LanguageProfile(
            primary=primary,
            languages=languages,
            predictions=predictions,
            analysed_chars=len(sample),
        )

    def detect_segments(
        self,
        text: str,
        *,
        min_segment_chars: int = 100,  # **OPTIMIZED**: Segmentos maiores (frases)
        min_probability: float = 0.7,  # **OPTIMIZED**: Higher confidence threshold
        timeout_seconds: float = 2.0,  # **NEW**: Timeout per detection
        fallback_language: str = "pt",  # **NEW**: Idioma de fallback
        primary_language: Optional[str] = None,  # **NEW**: Primary language for prioritization
    ) -> List[LanguageSegment]:
        if not text or detect_langs is None:
            return [LanguageSegment(language="unknown", text=text)]

        # **OPTIMIZED**: Process by paragraph instead of individual sentences
        paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
        if not paragraphs:
            paragraphs = [text]

        segments: List[LanguageSegment] = []
        current_lang = None
        buffer: List[str] = []

        for paragraph in paragraphs:
            # Only detect language in paragraphs that meet minimum length
            if len(paragraph.strip()) < min_segment_chars:
                buffer.append(paragraph)
                continue

            candidate_lang = self._detect_language_with_timeout(
                paragraph,
                min_probability=min_probability,
                timeout_seconds=timeout_seconds,
                fallback_language=fallback_language,
                primary_language=primary_language,
            )
            if not candidate_lang or candidate_lang == "unknown":
                buffer.append(paragraph)
                continue

            if current_lang is None:
                current_lang = candidate_lang
                buffer.append(paragraph)
                continue

            if candidate_lang != current_lang and buffer:
                merged = "\n".join(buffer).strip()  # **CHANGED**: Preserve paragraph breaks
                if merged:
                    segments.append(LanguageSegment(language=current_lang, text=merged))
                buffer = [paragraph]
                current_lang = candidate_lang
            else:
                buffer.append(paragraph)

        if buffer:
            merged = "\n".join(buffer).strip()  # **CHANGED**: Preserve paragraph breaks
            if merged:
                language = current_lang or "unknown"
                segments.append(LanguageSegment(language=language, text=merged))

        if not segments:
            fallback_lang = self._detect_language_with_timeout(
                text,
                timeout_seconds=timeout_seconds,
                fallback_language=fallback_language,
                primary_language=primary_language,
            )
            return [LanguageSegment(language=fallback_lang, text=text)]

        refined_segments: List[LanguageSegment] = []
        primary_short = self._normalise_code(primary_language) if primary_language else ""
        for segment in segments:
            stripped = segment.text.strip()
            if len(stripped) < min_segment_chars:
                refined_segments.append(LanguageSegment(language=segment.language, text=stripped))
                continue
            language = (
                self._detect_language_with_timeout(
                    stripped,
                    min_probability=min_probability,
                    timeout_seconds=timeout_seconds,
                    fallback_language=fallback_language,
                    primary_language=primary_language,
                )
                or segment.language
            )
            # Stability guardrail: if the first pass already classified this
            # segment as the primary language, do not let a non-deterministic
            # langdetect re-run flip it to a different language. The primary
            # tag is the reliable signal — the user's book is in pt-BR, and
            # langdetect oscillates on identical pt-BR paragraphs near the
            # 0.5 probability boundary against es/it/ca, which would route
            # the chunk to a foreign Edge voice and produce pt spoken with
            # an accent. Only the foreign-→primary direction stays free,
            # since that direction recovers correctness.
            seg_short = (segment.language or "").split("-", 1)[0].lower()
            ref_short = (language or "").split("-", 1)[0].lower()
            if (
                primary_short
                and seg_short == primary_short
                and ref_short
                and ref_short != primary_short
            ):
                language = segment.language
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
        fallback_language: str = "pt",
        primary_language: Optional[str] = None,
        ambiguity_threshold: float = 0.15,  # **NEW**: Max difference to consider ambiguous
    ) -> str:
        """Detect language with timeout, fallback, and primary language prioritization.

        When multiple languages are detected with similar probabilities (within ambiguity_threshold),
        and one of them is the primary_language, the primary language will be preferred.
        """
        stripped = (text or "").strip()
        if not stripped or len(stripped) < 10:
            return fallback_language

        # Memoize repeated paragraphs (boilerplate headers, recurring quotes,
        # short phrases that appear across many chapters). Key includes the
        # tunables that influence the outcome so different callers do not
        # collide on the same sample text.
        # blake2b for the in-memory memo: ~30% faster than sha1 on the
        # paragraph-sized inputs we hash here, and we don't need any of
        # sha1's cryptographic properties for an in-process LRU key.
        cache_key = hashlib.blake2b(
            f"{min_probability}|{timeout_seconds}|{fallback_language}|"
            f"{primary_language or ''}|{ambiguity_threshold}|{stripped}".encode(
                "utf-8", errors="ignore"
            ),
            digest_size=20,
        ).hexdigest()
        cached = self._detect_cache.get(cache_key)
        if cached is not None:
            return cached

        def _store(result: str) -> str:
            # Bound the cache to avoid pathological memory growth on
            # extremely diverse corpora. When the limit is hit we drop
            # ~10% of oldest entries.
            if len(self._detect_cache) >= self._DETECT_CACHE_LIMIT:
                drop = max(1, self._DETECT_CACHE_LIMIT // 10)
                for old_key in list(self._detect_cache.keys())[:drop]:
                    self._detect_cache.pop(old_key, None)
            self._detect_cache[cache_key] = result
            return result

        try:
            # Run detection in a thread to enable timeout
            import concurrent.futures

            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                # Get multiple language predictions instead of just one
                future = executor.submit(self._detect_languages, text, top_n=3)
                try:
                    predictions = future.result(timeout=timeout_seconds)
                    if not predictions:
                        return _store(fallback_language)

                    text_len = len(stripped)
                    # Check if primary language should be prioritized
                    if primary_language and len(predictions) > 1:
                        primary_normalized = self._normalise_code(primary_language)
                        best_prediction = predictions[0]

                        # Look for primary language in predictions
                        primary_prediction = None
                        for pred in predictions:
                            if pred.code == primary_normalized:
                                primary_prediction = pred
                                break

                        # If primary language found and text is short/ambiguous, prefer it
                        if primary_prediction:
                            if text_len <= 240:
                                return _store(primary_prediction.code)
                            prob_diff = abs(
                                best_prediction.probability - primary_prediction.probability
                            )
                            if prob_diff <= ambiguity_threshold:
                                # Ambiguous: primary language is within threshold, use it
                                return _store(primary_prediction.code)

                    # No ambiguity or no primary language match: use best prediction
                    best = predictions[0]
                    if best.probability < min_probability:
                        return _store(fallback_language)
                    return _store(best.code)

                except concurrent.futures.TimeoutError:
                    print(
                        f"⚠️ Language detection timeout ({timeout_seconds}s) — using fallback: {fallback_language}"
                    )
                    # Don't cache timeouts — they may be transient.
                    return fallback_language
        except Exception as e:
            print(f"⚠️ Language detection error: {e} — using fallback: {fallback_language}")
            return fallback_language

    @staticmethod
    def _merge_adjacent(segments: Iterable[LanguageSegment]) -> List[LanguageSegment]:
        merged: List[LanguageSegment] = []
        previous: Optional[LanguageSegment] = None
        for segment in segments:
            if previous and segment.language == previous.language:
                previous = LanguageSegment(
                    language=previous.language, text=f"{previous.text} {segment.text}".strip()
                )
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
        return clean.split("-", 1)[0]

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
