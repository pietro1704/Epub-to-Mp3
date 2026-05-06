# -*- coding: utf-8 -*-
"""LanguageDetector.clear_cache() — drop the per-process detection memo."""

from __future__ import annotations

from src.language.detector import LanguageDetector


def test_clear_cache_drops_entries():
    det = LanguageDetector()
    text = (
        "This is a long English passage used to populate the per-process "
        "detection cache for the regression test."
    )
    det._detect_language_with_timeout(text, fallback_language="en")
    assert len(det._detect_cache) >= 1
    LanguageDetector.clear_cache()
    assert len(det._detect_cache) == 0


def test_clear_cache_is_class_scope():
    """Two detector instances share the cache (class-level dict). The
    clear_cache() classmethod must wipe it for both."""
    a = LanguageDetector()
    b = LanguageDetector()
    text = (
        "This is another long English passage used to ensure that the "
        "shared class-level cache is observed by both instances."
    )
    a._detect_language_with_timeout(text, fallback_language="en")
    assert len(b._detect_cache) >= 1
    b.clear_cache()
    assert len(a._detect_cache) == 0
