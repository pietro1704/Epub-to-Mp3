"""Chapter-number markers like "1 |" must become TTS pauses.

User feedback on Carl conversion: "Cap 1 deveria ler capitulo 1...1...
a transformacao. Está sem as pausas." — the pt-BR EPUB has
"Capítulo 1\\n1 |\\nA transformação..." and Edge was reading it as one
unbroken sentence "Capítulo 1 1 A transformação...".

The fix in `apply_structural_speech_cues` rewrites a "<N> |" marker
that lives on its own line into "<N>..." so the TTS pauses between
the announcement, the chapter number, and the chapter body.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.ebook_reader import TextProcessor


class TestChapterMarkerPause(unittest.TestCase):
    def test_pipe_marker_becomes_ellipsis(self):
        text = "1 |\nA transformação aconteceu."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 1"
        )
        # Title prepended + chapter number normalised.
        self.assertIn("Capítulo 1.", out)
        self.assertIn("1.", out)
        self.assertNotIn("|", out)

    def test_marker_at_start_of_text(self):
        text = "5 |\nO viajante chegou."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 5"
        )
        self.assertIn("5.", out)
        self.assertNotIn("|", out)

    def test_no_pipe_no_change_to_body(self):
        """Body sentences containing | (e.g. for tables) shouldn't be
        rewritten — only the standalone-line marker pattern."""
        text = "Linha 1.\nA | B | C\nLinha final."
        out = TextProcessor.apply_structural_speech_cues(text, raw_html=None, chapter_title="X")
        # The middle line has letters, not a number, so it stays as-is.
        self.assertIn("A | B | C", out)

    def test_double_digit_chapter_number(self):
        text = "42 |\nO sentido da vida."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 42"
        )
        self.assertIn("42.", out)
        self.assertNotIn("42 |", out)

    def test_markdown_hash_marker_becomes_pause(self):
        """Markdown-style "## 7" chapter heading must also pause."""
        text = "## 7\nO velho dragão acordou."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 7"
        )
        self.assertIn("7.", out)
        self.assertNotIn("##", out)

    def test_bare_numeric_marker_becomes_pause(self):
        """Bare "<N>" line at chapter start (Companhia das Letras style)."""
        text = "12\nA nova manhã.\nE o sol nasceu."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 12"
        )
        self.assertIn("12.", out)

    def test_bare_numeric_does_not_match_three_plus_digits(self):
        """Year mentions like "2026\nfoi" must NOT be rewritten."""
        text = "2026\nfoi um ano notável."
        out = TextProcessor.apply_structural_speech_cues(text, raw_html=None, chapter_title="Cap")
        self.assertNotIn("2026.", out)

    def test_marker_with_trailing_period(self):
        """`enhance_natural_pauses` appends '.' to un-punctuated paragraph
        ends BEFORE this normaliser runs. The regex must therefore tolerate
        a period between '|' and the newline; otherwise the marker keeps
        flowing into the body and the pause is lost (Carl Capítulo 1
        regression)."""
        text = "1 |.\nA transformação aconteceu."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 1"
        )
        self.assertIn("1.", out)
        self.assertNotIn("1 |", out)


if __name__ == "__main__":
    unittest.main()
