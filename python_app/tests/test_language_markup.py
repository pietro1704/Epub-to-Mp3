# -*- coding: utf-8 -*-
"""Tests for language markup behaviour."""

import unittest

from src.language.detector import LanguageDetector
from src.language.markup import LanguageMarkup


class TestLanguageMarkup(unittest.TestCase):
    def setUp(self) -> None:
        self.detector = LanguageDetector()
        self.markup = LanguageMarkup(self.detector)

    def test_annotate_small_foreign_snippet_keeps_default(self):
        text = (
            "Agradeço a todos pelo apoio."  # pt
            " \"Thank you\" foi a única frase em inglês."  # tiny en quote
        )
        annotated = self.markup.annotate(text, "pt")
        self.assertEqual(annotated, text)

    def test_annotate_large_foreign_segment_marks_language(self):
        text = (
            "Introdução em português. \n"
            "[[lang:en]]This whole paragraph should be read in English because it is long\n"
            "and clearly distinct from the surrounding Portuguese text.[[/lang]]"
        )
        processed = self.markup.annotate(text, "pt")
        self.assertIn("[[lang:en]]", processed)


if __name__ == "__main__":
    unittest.main()
