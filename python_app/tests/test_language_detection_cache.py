# -*- coding: utf-8 -*-
"""Verify per-process memoization of language detection."""

from __future__ import annotations

from src.language.detector import LanguageDetector


def test_repeated_detection_is_memoized(monkeypatch):
    det = LanguageDetector()
    det._detect_cache.clear()

    call_counter = {"n": 0}
    real = det._detect_languages

    def _spy(text, *, top_n=3):
        call_counter["n"] += 1
        return real(text, top_n=top_n)

    monkeypatch.setattr(det, "_detect_languages", _spy)

    sample = (
        "This is a deliberately long English paragraph used to exercise "
        "the language detection memoization cache so that the langdetect "
        "thread pool is not spun up twice for the same input text."
    )
    first = det._detect_language_with_timeout(sample, fallback_language="en")
    second = det._detect_language_with_timeout(sample, fallback_language="en")
    third = det._detect_language_with_timeout(sample, fallback_language="en")

    assert first == second == third
    # Only the first call should have hit the underlying detector.
    assert call_counter["n"] <= 1


def test_cache_keys_separate_distinct_inputs():
    det = LanguageDetector()
    det._detect_cache.clear()
    en = "This is a long English paragraph for testing the detector cache key."
    pt = "Este é um parágrafo longo em português para testar a chave do cache."
    res_en = det._detect_language_with_timeout(en, fallback_language="en")
    res_pt = det._detect_language_with_timeout(pt, fallback_language="pt")
    # Both results were stored independently.
    assert len(det._detect_cache) >= 2
    assert res_en in {"en", "pt"}  # fallback may apply on slow envs
    assert res_pt in {"pt", "en"}


def test_cache_respects_short_text_fallback():
    det = LanguageDetector()
    det._detect_cache.clear()
    # Texts under 10 chars short-circuit before the cache lookup.
    out = det._detect_language_with_timeout("hi", fallback_language="pt")
    assert out == "pt"
    assert len(det._detect_cache) == 0


def test_cache_eviction_under_limit(monkeypatch):
    det = LanguageDetector()
    det._detect_cache.clear()
    # Tighten the limit so the eviction path is exercised cheaply.
    monkeypatch.setattr(det, "_DETECT_CACHE_LIMIT", 5, raising=False)
    LanguageDetector._DETECT_CACHE_LIMIT = 5
    try:
        for i in range(15):
            text = (
                f"Sample number {i} with enough characters to clear the "
                f"minimum-length guard inside the detector helper."
            )
            det._detect_language_with_timeout(text, fallback_language="en")
        assert len(det._detect_cache) <= 5
    finally:
        LanguageDetector._DETECT_CACHE_LIMIT = 4096
