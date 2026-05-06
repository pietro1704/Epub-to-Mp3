# -*- coding: utf-8 -*-
"""Verify cache-key sites use blake2b instead of sha1 (v0.3.27 micro-perf).

The keys are an in-process implementation detail, so we only check
that the *site* uses blake2b — what matters for caller correctness is
that two equal inputs produce equal keys.
"""

from __future__ import annotations

import hashlib
import inspect


def test_ebook_reader_footnote_cache_uses_blake2b():
    from src.ebook_reader import TextProcessor

    src = inspect.getsource(TextProcessor.inject_footnotes)
    assert "blake2b" in src
    assert "hashlib.sha1" not in src.replace("# ", "")


def test_toc_disk_cache_uses_blake2b():
    from src import ebook_reader as _eb

    src = inspect.getsource(_eb._toc_disk_cache_path)
    assert "blake2b" in src


def test_language_detector_cache_uses_blake2b():
    from src.language.detector import LanguageDetector

    src = inspect.getsource(LanguageDetector._detect_language_with_timeout)
    assert "blake2b" in src


def test_blake2b_keys_are_stable_for_equal_inputs():
    """Sanity: blake2b is deterministic, so equal inputs produce equal
    keys — the cache invariant relied on by every site we changed."""
    a = hashlib.blake2b(b"hello world", digest_size=20).hexdigest()
    b = hashlib.blake2b(b"hello world", digest_size=20).hexdigest()
    assert a == b
    c = hashlib.blake2b(b"hello world!", digest_size=20).hexdigest()
    assert a != c
