"""Chapter-number markers like "1 |" must be SUPPRESSED, not voiced.

User feedback on Carl conversion: "Cap 1 deveria ler capitulo 1...1...
a transformacao. Está sem as pausas." — the pt-BR EPUB has
"Capítulo 1\\n1 |\\nA transformação..." and Edge was reading it as one
unbroken sentence "Capítulo 1 1 A transformação..." then a stuttered
"Capítulo 1 1 A transformação".

Earlier attempts (commits 31a1781, 9781eac, c03646b) tried to inject
"<N>..." or "<N>." pauses, but plain-text Edge caps inter-sentence
silence at ~700ms regardless of punctuation density. The pause never
sounded like a real beat between chapter number and body.

Final fix: drop the standalone "<N>" / "<N> |" / "## <N>" markers
entirely. The chapter title prepended at the top ("Capítulo 1.") plays
the announcement role; the bare number is a printed artifact with no
listener value.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.ebook_reader import TextProcessor


class TestChapterMarkerSuppressed(unittest.TestCase):
    def test_pipe_marker_dropped(self):
        text = "1 |\nA transformação aconteceu."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 1"
        )
        self.assertIn("Capítulo 1.", out)
        self.assertNotIn("|", out)
        # The standalone "1" line must be gone — body should follow the
        # title directly.
        self.assertNotIn("1 |", out)
        # Body intact.
        self.assertIn("A transformação aconteceu", out)

    def test_marker_at_start_of_text(self):
        text = "5 |\nO viajante chegou."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 5"
        )
        self.assertNotIn("|", out)
        self.assertIn("O viajante chegou", out)

    def test_no_pipe_no_change_to_body(self):
        """Body sentences containing | (e.g. for tables) shouldn't be
        rewritten — only the standalone-line marker pattern."""
        text = "Linha 1.\nA | B | C\nLinha final."
        out = TextProcessor.apply_structural_speech_cues(text, raw_html=None, chapter_title="X")
        self.assertIn("A | B | C", out)

    def test_double_digit_chapter_number(self):
        text = "42 |\nO sentido da vida."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 42"
        )
        self.assertNotIn("42 |", out)
        self.assertIn("O sentido da vida", out)

    def test_markdown_hash_marker_dropped(self):
        """Markdown-style "## 7" chapter heading also dropped."""
        text = "## 7\nO velho dragão acordou."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 7"
        )
        self.assertNotIn("##", out)
        self.assertIn("O velho dragão acordou", out)

    def test_bare_numeric_marker_dropped(self):
        """Bare "<N>" line at chapter start (Companhia das Letras style)."""
        text = "12\nA nova manhã.\nE o sol nasceu."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 12"
        )
        # The standalone "12" must NOT appear as its own line.
        lines = [line.strip() for line in out.split("\n") if line.strip()]
        self.assertNotIn("12", lines)

    def test_bare_numeric_does_not_match_three_plus_digits(self):
        """Year mentions like "2026\nfoi" must NOT be rewritten."""
        text = "2026\nfoi um ano notável."
        out = TextProcessor.apply_structural_speech_cues(text, raw_html=None, chapter_title="Cap")
        self.assertIn("2026", out)

    def test_marker_with_trailing_period(self):
        """`enhance_natural_pauses` may have appended '.' to the marker
        line before normalisation — the regex must still drop it."""
        text = "1 |.\nA transformação aconteceu."
        out = TextProcessor.apply_structural_speech_cues(
            text, raw_html=None, chapter_title="Capítulo 1"
        )
        self.assertNotIn("1 |", out)
        self.assertIn("A transformação aconteceu", out)


if __name__ == "__main__":
    unittest.main()
