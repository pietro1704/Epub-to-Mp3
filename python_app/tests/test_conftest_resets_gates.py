# -*- coding: utf-8 -*-
"""Verify the conftest autouse fixture resets module-level cleanup gates
between tests (v0.3.27).

The gates exist so the lazy GC of stale cache entries runs at most
once per CLI/server process. Without the conftest reset, a test that
triggered cleanup would leave the flag set, hiding the cleanup path
from later tests.
"""

from __future__ import annotations

from src import ebook_reader as _eb
from src.cache_manager import CacheManager


def test_toc_disk_cache_gate_starts_false():
    assert _eb._TOC_DISK_CACHE_CLEANED is False


def test_text_cache_gate_starts_false():
    assert CacheManager._TEXT_CACHE_CLEANED is False


def test_gate_set_in_one_test_resets_for_next_first_half():
    """First half of the pair: trip the gate."""
    _eb._TOC_DISK_CACHE_CLEANED = True
    CacheManager._TEXT_CACHE_CLEANED = True


def test_gate_set_in_one_test_resets_for_next_second_half():
    """Second half of the pair: gate must be back to False thanks to
    the conftest fixture, not still True from the previous test."""
    assert _eb._TOC_DISK_CACHE_CLEANED is False
    assert CacheManager._TEXT_CACHE_CLEANED is False
