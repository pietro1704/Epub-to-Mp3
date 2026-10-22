"""Literary Heading regression scenarios, collected by test_chapter_name_parsing."""

from __future__ import annotations

from python_app.tests._chapter_name_parsing_test_support import EpubParser as EpubParser
from python_app.tests._chapter_name_parsing_test_support import TextProcessor as TextProcessor
from python_app.tests._chapter_name_parsing_test_support import unittest as unittest


# ---------------------------------------------------------------------------
# 1. Harry Potter style (calibre-generated: h4 chapter number + h2 subtitle)
# ---------------------------------------------------------------------------
class TestHarryPotterStyleParsing(unittest.TestCase):
    """calibre EPUB: h4 with non-breaking spaces + h2 subtitle."""

    HTML = (
        '<h4 class="calibre12">CHAPTER\xa0\xa0ONE</h4>'
        '<h2 class="calibre14">THE BOY WHO LIVED</h2>'
        '<p class="first"><span class="drop">M</span>r. and Mrs. Dursley, '
        "of number four, Privet Drive, were proud to say that they were "
        "perfectly normal, thank you very much.</p>"
    )

    def test_extract_first_heading_returns_h4_text(self):
        # H_TAG finds the first heading; extract_first_heading does NOT normalize &nbsp;
        # → raw inner text "CHAPTER\xa0\xa0ONE", TAG_RE strips nothing (no tags),
        # normalise_whitespace collapses only [ \t\f\v], leaving \xa0 as-is.
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertIsNotNone(result)
        self.assertIn("CHAPTER", result)
        self.assertIn("ONE", result)

    def test_extract_first_heading_is_not_h2(self):
        # Must return h4 (first heading), not h2
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertNotEqual(result, "THE BOY WHO LIVED")

    def test_extract_structural_titles_includes_both_headings(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        # h-tag extraction: NBSP normalised in _add → "CHAPTER ONE"
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("chapter one", titles_cf)
        self.assertIn("the boy who lived", titles_cf)

    def test_extract_structural_titles_body_paragraph_not_included(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertFalse(any("privet drive" in t for t in titles_cf))

    def test_plain_text_contains_both_heading_texts(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("CHAPTER", plain)
        self.assertIn("THE BOY WHO LIVED", plain)

    def test_prepare_speech_text_adds_pause_after_h2(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("THE BOY WHO LIVED.", speech)

    def test_prepare_speech_text_chapter_heading_before_subtitle(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        # Chapter heading line must appear before subtitle
        self.assertLess(speech.index("CHAPTER"), speech.index("THE BOY WHO LIVED"))

    def test_plain_text_body_text_present(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("Dursley", plain)


# ---------------------------------------------------------------------------
# 2. IT English style (two h2 + h3 section marker)
# ---------------------------------------------------------------------------
class TestITEnglishStyleParsing(unittest.TestCase):
    """Stephen King IT: two h2 headings + h3 section number."""

    HTML = (
        '<h2 class="h2">CHAPTER 1</h2>'
        '<h2 class="h2title"><span class="txit">After the Flood (1957)</span></h2>'
        '<h3 class="h3a">1</h3>'
        '<p class="text">The terror, which would not end for another twenty-eight years, began.</p>'
    )

    def test_extract_first_heading_is_chapter_1(self):
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertEqual(result, "CHAPTER 1")

    def test_extract_structural_titles_includes_all_three_headings(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("chapter 1", titles_cf)
        self.assertIn("after the flood (1957)", titles_cf)
        self.assertIn("1", titles_cf)

    def test_extract_structural_titles_body_paragraph_excluded(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        self.assertFalse(any("terror" in t.casefold() for t in titles))

    def test_plain_text_has_all_heading_texts(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("CHAPTER 1", plain)
        self.assertIn("After the Flood", plain)

    def test_prepare_speech_text_adds_pause_after_chapter_1(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("CHAPTER 1.", speech)

    def test_prepare_speech_text_adds_pause_after_after_flood(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("After the Flood (1957).", speech)

    def test_prepare_speech_text_chapter_1_before_flood(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertLess(speech.index("CHAPTER 1"), speech.index("After the Flood"))


# ---------------------------------------------------------------------------
# 3. Moby Dick PT style (span.chaptitle_e, no h tag — title from chapter_title param)
# ---------------------------------------------------------------------------
class TestMobyDickStyleParsing(unittest.TestCase):
    """No h tags; title comes exclusively from the TOC chapter_title param."""

    HTML = (
        '<p class="magellan">\xa0</p>'
        '<span class="chaptitle_e" id="ct01">1 <strong>MIRAGENS</strong></span>'
        '<p class="noindent">Diz-se que, tempos atrás, alguns viajantes tinham avistado a baleia.</p>'
    )

    def test_extract_first_heading_returns_none(self):
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertIsNone(result)

    def test_extract_structural_titles_without_chapter_title(self):
        # No h tags, only a short non-p span and long p body
        # The <p class="magellan"> contains only &nbsp; → normalised to " " → empty after strip
        # The body paragraph is long → won't be picked up as a structural title
        titles = TextProcessor.extract_structural_titles(self.HTML)
        # No structural titles expected from p tags (body paragraph is long/punctuated)
        self.assertFalse(any("tempos" in t.casefold() for t in titles))

    def test_extract_structural_titles_with_chapter_title_param(self):
        titles = TextProcessor.extract_structural_titles(self.HTML, chapter_title="1 MIRAGENS")
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("1 miragens", titles_cf)

    def test_plain_text_contains_body_text(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("viajantes", plain)

    def test_prepare_speech_text_with_chapter_title_adds_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(
            plain, segs, raw_html=self.HTML, chapter_title="1 MIRAGENS"
        )
        # "1 MIRAGENS" should appear in speech with pause
        self.assertIn(".", speech)

    def test_prepare_speech_text_without_chapter_title_no_heading_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        # Without a chapter_title, the body paragraph is long so no heading pause expected
        # Body text must be present
        self.assertIn("viajantes", speech)


# ---------------------------------------------------------------------------
# 4. Mythical Man-Month style (h1 with italic span)
# ---------------------------------------------------------------------------
class TestMythicalManMonthStyleParsing(unittest.TestCase):
    """h1 with a single italic span wrapping the chapter title."""

    HTML = (
        '<h1 class="calibre10" id="calibre_pb_17">'
        '<span class="italic">The Tar Pit</span></h1>'
        "<p>Programming is fun. That is why so many people define their life's work in terms of it.</p>"
    )

    def test_extract_first_heading_returns_title(self):
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertEqual(result, "The Tar Pit")

    def test_extract_structural_titles_contains_title(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("the tar pit", titles_cf)

    def test_extract_structural_titles_body_excluded(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        self.assertFalse(any("programming" in t.casefold() for t in titles))

    def test_plain_text_contains_title(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("The Tar Pit", plain)

    def test_prepare_speech_text_adds_pause_after_title(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("The Tar Pit.", speech)

    def test_prepare_speech_text_body_follows_heading(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("Programming", speech)
        self.assertLess(speech.index("The Tar Pit"), speech.index("Programming"))


# ---------------------------------------------------------------------------
# 5. Epigraph opening quote style (h1 is a long quote, p.cap-cred is attribution)
# ---------------------------------------------------------------------------
class TestEpigraphOpeningQuoteStyleParsing(unittest.TestCase):
    """h1 is a long epigraph quote (>8 words); p.cap-cred is a short attribution."""

    HTML = (
        '<h1 class="capitulo" id="calibre_pb_0">'
        "Aqueles que desejam repetir o passado devem controlar o ensino da história."
        "</h1>"
        '<p class="cap-cred">– Suma Bene Gesserit</p>'
        "<p>Odrade nunca tinha visto um rosto como aquele antes na sua longa vida.</p>"
    )

    def test_extract_first_heading_returns_epigraph(self):
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertIn("Aqueles que desejam", result)

    def test_extract_structural_titles_includes_h1(self):
        # h-tag extraction is unconditional — even long h1 epigraphs are included
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertTrue(any("aqueles que desejam" in t for t in titles_cf))

    def test_extract_structural_titles_attribution_included(self):
        # "– Suma Bene Gesserit" has 3 words, ends with 'i' (no .!?) → qualifies
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertTrue(any("suma bene gesserit" in t for t in titles_cf))

    def test_extract_structural_titles_long_body_excluded(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        self.assertFalse(any("odrade" in t.casefold() for t in titles))

    def test_prepare_speech_text_adds_pause_after_attribution(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        # The attribution line (short, no terminal punctuation) gets the pause
        self.assertIn("Suma Bene Gesserit.", speech)
        # The speech must also contain the epigraph text
        self.assertIn("história", speech)

    def test_plain_text_has_attribution_and_body(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("Suma Bene Gesserit", plain)
        self.assertIn("Odrade", plain)
