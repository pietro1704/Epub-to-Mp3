# -*- coding: utf-8 -*-
"""Tests for the in-memory TOC cache in ebook_reader."""

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src import ebook_reader
from src.ebook_reader import TocItem


class TestTocCache(unittest.TestCase):
    def setUp(self):
        ebook_reader._toc_cache.clear()

    def tearDown(self):
        ebook_reader._toc_cache.clear()

    def test_put_get_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "book.epub"
            p.write_bytes(b"x")
            items = [TocItem(title="Ch1", href="c1.html", level=1, children=[])]
            ebook_reader._toc_cache_put(str(p), "OEBPS/content.opf", items)
            hit = ebook_reader._toc_cache_get(str(p), "OEBPS/content.opf")
            self.assertIsNotNone(hit)
            self.assertEqual(hit[0].title, "Ch1")

    def test_mtime_invalidates(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "book.epub"
            p.write_bytes(b"x")
            items = [TocItem(title="v1", href="c.html", level=1, children=[])]
            ebook_reader._toc_cache_put(str(p), None, items)
            future_ns = p.stat().st_mtime_ns + 10_000_000_000
            os.utime(p, ns=(future_ns, future_ns))
            self.assertIsNone(ebook_reader._toc_cache_get(str(p), None))

    def test_miss_when_missing_file(self):
        self.assertIsNone(ebook_reader._toc_cache_get("/nonexistent/path.epub", None))

    def test_lru_eviction(self):
        original = ebook_reader._TOC_CACHE_MAX
        ebook_reader._TOC_CACHE_MAX = 2
        try:
            with tempfile.TemporaryDirectory() as tmp:
                for i in range(4):
                    p = Path(tmp) / f"b{i}.epub"
                    p.write_bytes(b"x")
                    ebook_reader._toc_cache_put(str(p), None, [])
                self.assertLessEqual(len(ebook_reader._toc_cache), 2)
        finally:
            ebook_reader._TOC_CACHE_MAX = original


if __name__ == "__main__":
    unittest.main()
