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


def test_footnote_collection_scales_with_many_backlinks():
    notes = "".join(f'<aside id="n{i}">Note {i}</aside>' for i in range(400))
    links = "".join(f'<a href="#n{i}">[{i}]</a>' for i in range(400))

    result = TextProcessor.inject_footnotes(f"<html><body>{links}{notes}</body></html>")

    assert "Note 399" in result[0] or any(
        item.get("text") == "Note 399" for item in result[1]
    )
