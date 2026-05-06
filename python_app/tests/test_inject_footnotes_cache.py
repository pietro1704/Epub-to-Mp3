# -*- coding: utf-8 -*-
"""Memoization of TextProcessor.inject_footnotes (v0.3.25)."""

from __future__ import annotations

from unittest.mock import patch

import pytest
from src.ebook_reader import TextProcessor


@pytest.fixture(autouse=True)
def _reset_footnote_cache():
    TextProcessor._footnote_cache.clear()
    yield
    TextProcessor._footnote_cache.clear()


def test_repeated_call_hits_cache():
    markup = "<html><body><p>Hello world.</p><p>Second paragraph here.</p></body></html>"

    with patch.object(
        TextProcessor,
        "_collect_footnotes_bs4",
        wraps=TextProcessor._collect_footnotes_bs4,
    ) as spy:
        first_text, first_fn = TextProcessor.inject_footnotes(markup)
        second_text, second_fn = TextProcessor.inject_footnotes(markup)
    assert first_text == second_text
    assert first_fn == second_fn
    # Underlying parser must run only once.
    assert spy.call_count == 1


def test_external_resolver_skips_cache():
    markup = "<html><body><p>External fnote here.</p></body></html>"
    calls = {"n": 0}

    def _resolver(_path):
        calls["n"] += 1
        return None

    with patch.object(
        TextProcessor,
        "_collect_footnotes_bs4",
        wraps=TextProcessor._collect_footnotes_bs4,
    ) as spy:
        TextProcessor.inject_footnotes(markup, external_file_resolver=_resolver)
        TextProcessor.inject_footnotes(markup, external_file_resolver=_resolver)
    # External resolver path must always re-parse — different runs may
    # produce different footnotes from a different zip context.
    assert spy.call_count == 2
    assert len(TextProcessor._footnote_cache) == 0


def test_cache_returns_independent_footnote_lists():
    markup = "<html><body><p>Test.</p></body></html>"
    _, fn_a = TextProcessor.inject_footnotes(markup)
    fn_a.append({"id": "tampered"})  # mutate caller's copy
    _, fn_b = TextProcessor.inject_footnotes(markup)
    assert fn_b == [] or all(item.get("id") != "tampered" for item in fn_b)


def test_cache_eviction_under_limit(monkeypatch):
    monkeypatch.setattr(TextProcessor, "_FOOTNOTE_CACHE_LIMIT", 5, raising=False)
    for i in range(15):
        TextProcessor.inject_footnotes(f"<html><body><p>Doc {i}.</p></body></html>")
    assert len(TextProcessor._footnote_cache) <= 5
