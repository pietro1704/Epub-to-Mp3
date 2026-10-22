# -*- coding: utf-8 -*-
"""Tests for chapter name parsing across diverse EPUB styles.

Each test class corresponds to a real EPUB chapter structure pattern,
verified by inspecting EPUBs from ~/Downloads/livros/.
"""

from __future__ import annotations

import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from python_app.tests._chapter_name_parsing_test_support import (
    EpubParser as EpubParser,
    TextProcessor as TextProcessor,
    unittest as unittest,
)

from python_app.tests._chapter_name_parsing_literary_heading_cases import (
    TestHarryPotterStyleParsing as TestHarryPotterStyleParsing,
    TestITEnglishStyleParsing as TestITEnglishStyleParsing,
    TestMobyDickStyleParsing as TestMobyDickStyleParsing,
    TestMythicalManMonthStyleParsing as TestMythicalManMonthStyleParsing,
    TestEpigraphOpeningQuoteStyleParsing as TestEpigraphOpeningQuoteStyleParsing,
)
from python_app.tests._chapter_name_parsing_localized_heading_cases import (
    TestDivinaComediaStyleParsing as TestDivinaComediaStyleParsing,
    TestMontanhaMagicaStyleParsing as TestMontanhaMagicaStyleParsing,
    TestDomQuixoteStyleParsing as TestDomQuixoteStyleParsing,
    TestSilmarillionStyleParsing as TestSilmarillionStyleParsing,
)

# ---------------------------------------------------------------------------
# 10. O Corpo Não Esquece style (Kobo spans, two-line title, no h tags)
# ---------------------------------------------------------------------------
class TestKoboTwoLineTitleStyleParsing(unittest.TestCase):
    """No h tags; Kobo reader spans with IDs; two-line title structure."""

    HTML = (
        '<p id="_idParaDest-6" class="Titulo_1">'
        '<span class="koboSpan" id="kobo.2.1">CAPÍTULO 1</span></p>'
        '<p id="_idParaDest-7" class="Titulo_2">'
        '<span class="Bold"><span class="koboSpan" id="kobo.3.1">'
        "LIÇÕES DE COMBATENTES NO VIETNAME"
        "</span></span></p>"
        '<p class="body">Larry Dewey não era um homem que esperava muito da vida.</p>'
    )

    def test_extract_first_heading_returns_none(self):
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertIsNone(result)

    def test_extract_structural_titles_includes_capitulo_1(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("capítulo 1", titles_cf)

    def test_extract_structural_titles_includes_licoes(self):
        # "LIÇÕES DE COMBATENTES NO VIETNAME" = 5 words, no terminal punctuation
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("lições de combatentes no vietname", titles_cf)

    def test_extract_structural_titles_body_excluded(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        self.assertFalse(any("larry dewey" in t.casefold() for t in titles))

    def test_plain_text_no_kobo_ids(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertNotIn("kobo.2.1", plain)
        self.assertNotIn("kobo.3.1", plain)

    def test_plain_text_has_title_lines(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("CAPÍTULO 1", plain)
        self.assertIn("LIÇÕES DE COMBATENTES NO VIETNAME", plain)

    def test_prepare_speech_text_capitulo_1_gets_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("CAPÍTULO 1.", speech)

    def test_prepare_speech_text_licoes_gets_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("LIÇÕES DE COMBATENTES NO VIETNAME.", speech)

    def test_prepare_speech_text_capitulo_before_licoes(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertLess(speech.index("CAPÍTULO 1"), speech.index("LIÇÕES DE COMBATENTES"))


# ---------------------------------------------------------------------------
# 11. Voo Noturno style (h1 with single roman numeral via nested span)
# ---------------------------------------------------------------------------
class TestVooNoturnoRomanNumeralStyleParsing(unittest.TestCase):
    """h1 contains a single character "I" via nested span."""

    HTML = (
        '<h1 class="p1"><span class="t2">I</span></h1>'
        '<p class="calibre1">Já às três da madrugada os pilotos dos correios iniciavam a longa viagem.</p>'
    )

    def test_extract_first_heading_returns_i(self):
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertEqual(result, "I")

    def test_extract_structural_titles_includes_i(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("i", titles_cf)

    def test_extract_structural_titles_body_excluded(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        self.assertFalse(any("pilotos" in t.casefold() for t in titles))

    def test_plain_text_has_i_and_body(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("I", plain)
        self.assertIn("pilotos", plain)

    def test_prepare_speech_text_i_gets_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("I.", speech)

    def test_prepare_speech_text_i_before_body(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertLess(speech.index("I."), speech.index("pilotos"))


# ---------------------------------------------------------------------------
# 12. clean_chapter_title variants
# ---------------------------------------------------------------------------
class TestCleanChapterTitleVariants(unittest.TestCase):
    """Systematic tests for clean_chapter_title prefix stripping."""

    def test_removes_part_with_dash(self):
        result = TextProcessor.clean_chapter_title("part001 - Chapter One")
        self.assertEqual(result, "Chapter One")

    def test_removes_part_with_space_only(self):
        result = TextProcessor.clean_chapter_title("part0002 Chapter Two")
        self.assertEqual(result, "Chapter Two")

    def test_removes_part_with_colon(self):
        result = TextProcessor.clean_chapter_title("PART003: The Third")
        self.assertEqual(result, "The Third")

    def test_no_prefix_unchanged(self):
        result = TextProcessor.clean_chapter_title("Chapter One")
        self.assertEqual(result, "Chapter One")

    def test_roman_numeral_title_unchanged(self):
        result = TextProcessor.clean_chapter_title("I. A Chegada")
        self.assertEqual(result, "I. A Chegada")

    def test_empty_string_no_crash(self):
        result = TextProcessor.clean_chapter_title("")
        self.assertEqual(result, "")

    def test_removes_part_with_en_dash(self):
        result = TextProcessor.clean_chapter_title("part001 – The Beginning")
        self.assertEqual(result, "The Beginning")

    def test_short_part_prefix_not_removed(self):
        # "part01" has only 2 digits — the regex requires \d{3,} so "part01" is NOT removed
        result = TextProcessor.clean_chapter_title("part01 Chapter")
        # Should be unchanged (only 2 digits → not matched)
        self.assertEqual(result, "part01 Chapter")

    def test_removes_part_four_digit(self):
        result = TextProcessor.clean_chapter_title("part0010 - Introduction")
        self.assertEqual(result, "Introduction")

    def test_pure_part_prefix_falls_back_to_original_strip(self):
        # If after removing the prefix nothing remains, return original stripped
        result = TextProcessor.clean_chapter_title("part001")
        # After removing "part001" the remainder is "", so fallback to original.strip()
        self.assertEqual(result, "part001")


# ---------------------------------------------------------------------------
# 13. Additional edge cases for extract_first_heading
# ---------------------------------------------------------------------------
class TestExtractFirstHeadingEdgeCases(unittest.TestCase):
    def test_none_input_returns_none(self):
        self.assertIsNone(TextProcessor.extract_first_heading(None))

    def test_empty_string_returns_none(self):
        self.assertIsNone(TextProcessor.extract_first_heading(""))

    def test_no_h_tags_returns_none(self):
        self.assertIsNone(TextProcessor.extract_first_heading("<p>Just a paragraph.</p>"))

    def test_h6_tag_is_found(self):
        result = TextProcessor.extract_first_heading("<h6>Deep Heading</h6>")
        self.assertEqual(result, "Deep Heading")

    def test_heading_with_nested_tags_strips_inner_html(self):
        result = TextProcessor.extract_first_heading(
            "<h1><strong><em>Styled Title</em></strong></h1>"
        )
        self.assertEqual(result, "Styled Title")

    def test_multiline_heading_content(self):
        # DOTALL flag means newlines inside h tags are matched
        result = TextProcessor.extract_first_heading("<h2>\n  Chapter Two\n</h2>")
        self.assertIsNotNone(result)
        self.assertIn("Chapter Two", result)

    def test_first_heading_returned_when_multiple_present(self):
        html = "<h3>First</h3><h1>Second</h1>"
        result = TextProcessor.extract_first_heading(html)
        self.assertEqual(result, "First")


# ---------------------------------------------------------------------------
# 14. Additional edge cases for extract_structural_titles
# ---------------------------------------------------------------------------
class TestExtractStructuralTitlesEdgeCases(unittest.TestCase):
    def test_none_input_returns_empty_list(self):
        self.assertEqual(TextProcessor.extract_structural_titles(None), [])

    def test_empty_string_returns_empty_list(self):
        self.assertEqual(TextProcessor.extract_structural_titles(""), [])

    def test_chapter_title_only_with_no_html(self):
        titles = TextProcessor.extract_structural_titles(None, chapter_title="My Chapter")
        self.assertIn("My Chapter", titles)

    def test_chapter_title_em_dash_split(self):
        # Em-dash split: "Capítulo 3 – Seis telefonemas (1985)"
        titles = TextProcessor.extract_structural_titles(
            None, chapter_title="Capítulo 3 – Seis telefonemas (1985)"
        )
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("capítulo 3", titles_cf)
        self.assertIn("seis telefonemas (1985)", titles_cf)

    def test_chapter_title_colon_split(self):
        titles = TextProcessor.extract_structural_titles(
            None, chapter_title="Part One: The Beginning"
        )
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("part one", titles_cf)
        self.assertIn("the beginning", titles_cf)

    def test_p_with_nine_words_excluded(self):
        # 9 words → exceeds the ≤8 limit
        html = "<p>One two three four five six seven eight nine</p>"
        titles = TextProcessor.extract_structural_titles(html)
        self.assertEqual(titles, [])

    def test_p_with_eight_words_included(self):
        # 8 words, no terminal punctuation → included
        html = "<p>One two three four five six seven eight</p>"
        titles = TextProcessor.extract_structural_titles(html)
        self.assertTrue(len(titles) > 0)

    def test_p_ending_with_period_excluded(self):
        html = "<p>Short title.</p>"
        titles = TextProcessor.extract_structural_titles(html)
        # Ends with "." → excluded from p-heuristic, and no h tags
        self.assertEqual(titles, [])

    def test_no_duplicate_titles(self):
        # Same title from h tag and chapter_title param → deduplicated
        html = "<h1>My Title</h1>"
        titles = TextProcessor.extract_structural_titles(html, chapter_title="My Title")
        count = sum(1 for t in titles if t.casefold() == "my title")
        self.assertEqual(count, 1)

    def test_max_six_titles_from_p_elements(self):
        # 8 single-word paragraphs → at most 6 titles returned
        paras = "".join(f"<p>Word{i}</p>" for i in range(8))
        titles = TextProcessor.extract_structural_titles(paras)
        self.assertLessEqual(len(titles), 6)


# ---------------------------------------------------------------------------
# 15. Additional _prepare_speech_text edge cases
# ---------------------------------------------------------------------------
class TestPrepareSpeechTextEdgeCases(unittest.TestCase):
    def test_empty_text_returns_empty(self):
        result = EpubParser._prepare_speech_text("", [], raw_html=None)
        self.assertEqual(result, "")

    def test_no_headings_no_ellipsis_on_body(self):
        html = "<p>This is a long body paragraph that should not get an ellipsis pause added.</p>"
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(html)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=html)
        # Body paragraph is long — not a structural title — no "..." added mid-sentence
        self.assertNotIn("body paragraph...", speech)

    def test_chapter_title_param_injected_if_not_in_text(self):
        html = "<p>Some body text that does not mention the chapter title at all.</p>"
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(html)
        speech = EpubParser._prepare_speech_text(
            plain, segs, raw_html=html, chapter_title="The Missing Chapter"
        )
        # apply_structural_speech_cues prepends TOC title when not in opening text
        self.assertIn("The Missing Chapter", speech)

    def test_plain_text_from_only_h_tags(self):
        html = "<h1>Title Only</h1>"
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(html)
        self.assertEqual(plain.strip(), "Title Only")

    def test_speech_text_preserves_body_text(self):
        html = "<h1>Hello</h1><p>World content here to read aloud please.</p>"
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(html)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=html)
        self.assertIn("World content", speech)


if __name__ == "__main__":
    unittest.main()
