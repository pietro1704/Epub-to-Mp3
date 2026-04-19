# -*- coding: utf-8 -*-
"""Tests for chapter-text LRU in _cache_mixin."""

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src import _cache_mixin


class TestChapterTextLRU(unittest.TestCase):
    def setUp(self):
        _cache_mixin._chapter_text_lru.clear()

    def tearDown(self):
        _cache_mixin._chapter_text_lru.clear()

    def test_hit_returns_cached_text_without_rereading(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "a.txt"
            p.write_text("hello", encoding="utf-8")
            first = _cache_mixin._read_chapter_text_cached(p)
            orig_mtime_ns = p.stat().st_mtime_ns
            p.write_text("overwritten-without-mtime-bump", encoding="utf-8")
            os.utime(p, ns=(orig_mtime_ns, orig_mtime_ns))
            second = _cache_mixin._read_chapter_text_cached(p)
            self.assertEqual(first, "hello")
            self.assertEqual(second, "hello")

    def test_mtime_change_invalidates(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "a.txt"
            p.write_text("v1", encoding="utf-8")
            _cache_mixin._read_chapter_text_cached(p)
            future_ns = p.stat().st_mtime_ns + 10_000_000_000
            p.write_text("v2", encoding="utf-8")
            os.utime(p, ns=(future_ns, future_ns))
            self.assertEqual(_cache_mixin._read_chapter_text_cached(p), "v2")

    def test_lru_evicts_oldest_beyond_bound(self):
        original = _cache_mixin._CHAPTER_TEXT_LRU_MAX
        _cache_mixin._CHAPTER_TEXT_LRU_MAX = 3
        try:
            with tempfile.TemporaryDirectory() as tmp:
                paths = []
                for i in range(5):
                    p = Path(tmp) / f"c{i}.txt"
                    p.write_text(f"body-{i}", encoding="utf-8")
                    paths.append(p)
                    _cache_mixin._read_chapter_text_cached(p)
                self.assertLessEqual(
                    len(_cache_mixin._chapter_text_lru),
                    _cache_mixin._CHAPTER_TEXT_LRU_MAX,
                )
        finally:
            _cache_mixin._CHAPTER_TEXT_LRU_MAX = original


if __name__ == "__main__":
    unittest.main()
