# -*- coding: utf-8 -*-
"""Tests for extracted _output_file_helpers pure functions."""

import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src._output_file_helpers import (
    coerce_chapter_index,
    sample_edges,
    title_from_filename,
)


class TestCoerceChapterIndex(unittest.TestCase):
    def test_none_returns_fallback(self):
        self.assertEqual(coerce_chapter_index(None, 7), 7)

    def test_int_positive(self):
        self.assertEqual(coerce_chapter_index(3, 1), 3)

    def test_zero_or_negative_returns_fallback(self):
        self.assertEqual(coerce_chapter_index(0, 5), 5)
        self.assertEqual(coerce_chapter_index(-2, 5), 5)

    def test_string_int(self):
        self.assertEqual(coerce_chapter_index("4", 1), 4)

    def test_string_float_truncates(self):
        self.assertEqual(coerce_chapter_index("4.5", 1), 4)

    def test_string_empty_returns_fallback(self):
        self.assertEqual(coerce_chapter_index("   ", 2), 2)

    def test_string_non_numeric_returns_fallback(self):
        self.assertEqual(coerce_chapter_index("foo", 9), 9)


class TestSampleEdges(unittest.TestCase):
    def test_short_text_returns_same(self):
        start, end = sample_edges("hello world", size=20)
        self.assertEqual(start, "hello world")
        self.assertEqual(end, "hello world")

    def test_long_text_splits(self):
        text = "a" * 200 + "b" * 200
        start, end = sample_edges(text, size=180)
        self.assertTrue(start.startswith("a"))
        self.assertTrue(end.endswith("b"))
        self.assertEqual(len(start), 180)
        self.assertEqual(len(end), 180)

    def test_whitespace_normalised(self):
        start, end = sample_edges("  foo\n\tbar   baz  ")
        self.assertEqual(start, "foo bar baz")
        self.assertEqual(end, "foo bar baz")


class TestTitleFromFilename(unittest.TestCase):
    def test_numeric_dash_prefix_stripped(self):
        self.assertEqual(title_from_filename(Path("005 - Chapter Name.mp3")), "Chapter Name")

    def test_numeric_underscore_prefix_stripped(self):
        self.assertEqual(title_from_filename(Path("005_Chapter_Name.mp3")), "Chapter Name")

    def test_non_numeric_prefix_untouched(self):
        self.assertEqual(title_from_filename(Path("Intro - Preface.mp3")), "Intro - Preface")

    def test_fallback_to_filename(self):
        self.assertEqual(title_from_filename(Path(".mp3")), ".mp3")


if __name__ == "__main__":
    unittest.main()
