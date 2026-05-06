# -*- coding: utf-8 -*-
"""TextProcessor.clear_footnote_cache() drops the in-memory memo (v0.3.26)."""

from __future__ import annotations

from src.ebook_reader import TextProcessor


def test_clear_footnote_cache_drops_entries():
    TextProcessor._footnote_cache.clear()
    TextProcessor.inject_footnotes("<html><body><p>A.</p></body></html>")
    TextProcessor.inject_footnotes("<html><body><p>B.</p></body></html>")
    assert len(TextProcessor._footnote_cache) >= 2
    TextProcessor.clear_footnote_cache()
    assert len(TextProcessor._footnote_cache) == 0


def test_clear_footnote_cache_is_thread_safe_call():
    """Smoke test: must not raise even when called repeatedly."""
    TextProcessor._footnote_cache.clear()
    TextProcessor.inject_footnotes("<html><body><p>C.</p></body></html>")
    TextProcessor.clear_footnote_cache()
    TextProcessor.clear_footnote_cache()  # idempotent
    assert len(TextProcessor._footnote_cache) == 0
