# -*- coding: utf-8 -*-
"""Regression tests for chapter-title announcement (apply_structural_speech_cues).

Covers the Metro 2033 bug where numeric/short TOC titles were silently dropped
because the fuzzy substring suppression collided with incidental digits/words
in the opening paragraphs.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.ebook_reader import TextProcessor


class TestChapterAnnouncement(unittest.TestCase):
    def test_numeric_title_is_announced_even_if_opening_has_digits(self):
        body = "The year was 1933 and the tunnels were silent. He walked on."
        result = TextProcessor.apply_structural_speech_cues(body, None, "1")
        # Second pass converts the heading line to "1." for a sentence-end pause.
        # (Earlier versions used "..." but Edge sometimes interpreted that as a
        # stutter cue, so we use a single period and rely on post-synthesis
        # silence injection for the audible beat.)
        self.assertTrue(
            result.startswith("1.\n") or result.startswith("1\n"),
            f"expected '1' to be announced, got: {result!r}",
        )

    def test_short_title_is_announced_when_first_line_does_not_match(self):
        body = "Tunnels collapsed behind him. He kept running."
        result = TextProcessor.apply_structural_speech_cues(body, None, "Prologue")
        self.assertTrue(result.startswith("Prologue.\n") or result.startswith("Prologue\n"))

    def test_title_already_first_line_is_not_duplicated(self):
        body = "Chapter One\nHe walked into the tunnel."
        result = TextProcessor.apply_structural_speech_cues(body, None, "Chapter One")
        # Should not start with "Chapter One\nChapter One"
        self.assertFalse(result.startswith("Chapter One\nChapter One"))

    def test_substantive_title_suppressed_when_embedded_in_opening(self):
        # Long, multi-word titles genuinely duplicated in the body should still
        # suppress the prepend to avoid double-announcement.
        body = "The Last Refuge of Humanity\nThe station was quiet."
        result = TextProcessor.apply_structural_speech_cues(
            body, None, "The Last Refuge of Humanity"
        )
        self.assertEqual(result.count("The Last Refuge of Humanity"), 1)

    def test_substantive_title_as_substring_suppresses_prepend(self):
        body = "Preface: The Last Refuge of Humanity is coming\nRest of text."
        result = TextProcessor.apply_structural_speech_cues(
            body, None, "The Last Refuge of Humanity"
        )
        self.assertEqual(result.count("The Last Refuge of Humanity"), 1)

    def test_short_title_substring_in_opening_still_announced(self):
        # "Metro" appears incidentally in body but the TOC title is "Metro" —
        # short title should still be announced (this is the core bug fix).
        body = "He rode the metro every day for years. The station was his home."
        result = TextProcessor.apply_structural_speech_cues(body, None, "Metro")
        self.assertTrue(result.startswith("Metro.\n") or result.startswith("Metro\n"))

    def test_empty_title_does_not_prepend(self):
        body = "Some text content."
        result = TextProcessor.apply_structural_speech_cues(body, None, "")
        self.assertEqual(result, body)

    def test_empty_text_returns_empty(self):
        self.assertEqual(TextProcessor.apply_structural_speech_cues("", None, "Chapter 1"), "")


if __name__ == "__main__":
    unittest.main()
