# -*- coding: utf-8 -*-
"""Tests for the bounded in-memory LRU in CacheManager."""

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src import cache_manager as cache_manager_module
from src.cache_manager import CacheManager


class TestMemoryCacheLRU(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.cache = CacheManager(cache_dir=Path(self._tmp.name))

    def test_memory_cache_is_bounded(self):
        """Memory cache should evict entries beyond the LRU bound."""
        bound = cache_manager_module._MEMORY_CACHE_MAX_ENTRIES
        for i in range(bound + 5):
            self.cache._memory_cache_put(f"book-{i}", {"title": f"T{i}"})
        self.assertEqual(len(self.cache._memory_cache), bound)
        # Oldest entries evicted
        self.assertNotIn("book-0", self.cache._memory_cache)
        self.assertIn(f"book-{bound + 4}", self.cache._memory_cache)

    def test_memory_cache_lru_ordering(self):
        """Re-inserting a key marks it most-recent and spares it from eviction."""
        bound = cache_manager_module._MEMORY_CACHE_MAX_ENTRIES
        for i in range(bound):
            self.cache._memory_cache_put(f"book-{i}", {"title": f"T{i}"})
        # Touch book-0 so it becomes most-recent
        self.cache._memory_cache_put("book-0", {"title": "T0-refreshed"})
        # Insert one more — book-1 (oldest now) should be evicted, not book-0
        self.cache._memory_cache_put("book-new", {"title": "new"})
        self.assertIn("book-0", self.cache._memory_cache)
        self.assertNotIn("book-1", self.cache._memory_cache)


if __name__ == "__main__":
    unittest.main()
