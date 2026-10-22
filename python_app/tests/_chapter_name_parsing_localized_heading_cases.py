"""Localized Heading regression scenarios, collected by test_chapter_name_parsing."""

from __future__ import annotations

from python_app.tests._chapter_name_parsing_test_support import EpubParser as EpubParser
from python_app.tests._chapter_name_parsing_test_support import TextProcessor as TextProcessor
from python_app.tests._chapter_name_parsing_test_support import unittest as unittest


# ---------------------------------------------------------------------------
# 6. Divina Comédia style (p-only, anchor id inside p, no h tags)
# ---------------------------------------------------------------------------
class TestDivinaComediaStyleParsing(unittest.TestCase):
    """No h tags; structural titles come only from short p elements."""

    HTML = (
        '<p class="titulonegritocentralizado1">Inferno</p>'
        '<p class="novoparagrafo"><a id="inCantoI" class="calibre6"></a>Canto I</p>'
        "<p>Nel mezzo del cammin di nostra vita mi ritrovai per una selva oscura, "
        "che la diritta via era smarrita e il poeta ne fu molto colpito.</p>"
    )

    def test_extract_first_heading_returns_none(self):
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertIsNone(result)

    def test_extract_structural_titles_includes_inferno(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("inferno", titles_cf)

    def test_extract_structural_titles_includes_canto_i(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("canto i", titles_cf)

    def test_extract_structural_titles_body_excluded(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        self.assertFalse(any("nel mezzo" in t.casefold() for t in titles))

    def test_plain_text_canto_i_without_anchor_id(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("Canto I", plain)
        # The anchor id text (inCantoI) is an artifact that gets stripped
        self.assertNotIn("inCantoI", plain)

    def test_prepare_speech_text_inferno_gets_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("Inferno.", speech)

    def test_prepare_speech_text_canto_i_gets_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("Canto I.", speech)

    def test_prepare_speech_text_inferno_before_canto_i(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertLess(speech.index("Inferno"), speech.index("Canto I"))


# ---------------------------------------------------------------------------
# 7. Montanha Mágica style (h1 with <small> roman numeral + period, h2 with <small>)
# ---------------------------------------------------------------------------
class TestMontanhaMagicaStyleParsing(unittest.TestCase):
    """h1 has roman numeral in <small> + a period outside; h2 has small-caps in <small>."""

    HTML = (
        '<h1 class="h" id="calibre_pb_0"><small class="calibre3">I</small>.</h1>'
        '<h2 id="sigil_toc_id_1" class="calibre10"><small class="calibre6">A CHEGADA</small></h2>'
        '<p class="calibre9">Hans Castorp chegou ao Berghof numa tarde de verão.</p>'
    )

    def test_extract_first_heading_is_h1(self):
        # h1 inner text: <small>I</small>. → TAG_RE strips <small> tags → "I."
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertIsNotNone(result)
        self.assertIn("I", result)

    def test_extract_structural_titles_includes_h1(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        # h1 inner: "I." → 1 word, ends with "." → check: norm[-1] not in ".!?" is False
        # BUT h-tag extraction in extract_structural_titles uses _add(match.group(2))
        # which does: TAG_RE.sub("", "I.") → "I.", normalise_whitespace → "I."
        # norm = "I.", key = "i." → it IS added (h tags are added unconditionally)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("i.", titles_cf)

    def test_extract_structural_titles_includes_h2(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("a chegada", titles_cf)

    def test_extract_structural_titles_body_excluded(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        self.assertFalse(any("hans castorp" in t.casefold() for t in titles))

    def test_plain_text_has_a_chegada(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("A CHEGADA", plain)

    def test_prepare_speech_text_adds_pause_after_a_chegada(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("A CHEGADA.", speech)

    def test_prepare_speech_text_heading_before_body(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("Hans Castorp", speech)
        self.assertLess(speech.index("A CHEGADA"), speech.index("Hans Castorp"))


# ---------------------------------------------------------------------------
# 8. Dom Quixote style (p-only, no h tags, typographic small-caps via span)
# ---------------------------------------------------------------------------
class TestDomQuixoteStyleParsing(unittest.TestCase):
    """No h tags; titles come from short p elements; span is used for small-caps."""

    HTML = (
        "<p>O engenhoso fidalgo Dom Quixote de la Mancha</p>"
        '<p class="parte1">P<span class="parte-2-versalete">RIMEIRA PARTE</span></p>'
        '<p class="epigrafe">Andad, maldichos y torpes.</p>'
    )

    def test_extract_first_heading_returns_none(self):
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertIsNone(result)

    def test_extract_structural_titles_includes_dom_quixote_title(self):
        # "O engenhoso fidalgo Dom Quixote de la Mancha" = 8 words, no terminal punctuation
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("o engenhoso fidalgo dom quixote de la mancha", titles_cf)

    def test_extract_structural_titles_includes_primeira_parte(self):
        # Inner text after stripping span: "PRIMEIRA PARTE" (no space between P and RIMEIRA
        # because HTML is `P<span>RIMEIRA PARTE</span>` — TAG_RE strips span → "PRIMEIRA PARTE")
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("primeira parte", titles_cf)

    def test_extract_structural_titles_epigrafe_excluded(self):
        # "Andad, maldichos y torpes." ends with "." → excluded
        titles = TextProcessor.extract_structural_titles(self.HTML)
        self.assertFalse(any("andad" in t.casefold() for t in titles))

    def test_plain_text_has_dom_quixote(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("Dom Quixote", plain)

    def test_prepare_speech_text_dom_quixote_gets_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("O engenhoso fidalgo Dom Quixote de la Mancha.", speech)

    def test_prepare_speech_text_primeira_parte_gets_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("PRIMEIRA PARTE.", speech)


# ---------------------------------------------------------------------------
# 9. Silmarillion style (deeply nested spans inside p, no h tags)
# ---------------------------------------------------------------------------
class TestSilmarillionStyleParsing(unittest.TestCase):
    """No h tags; title buried in deeply nested spans inside a p link."""

    HTML = (
        '<p class="calibre28">'
        '  <a href="split_002.html#filepos3229" class="calibre2">'
        '    <span class="bold"><span class="calibre3">'
        '      <span class="calibre4" style="text-decoration:underline">CHAPTER 1</span>'
        "    </span></span>"
        "  </a>"
        "</p>"
        '<p class="calibre20">In the beginning Eru, the One, who in the Elvish tongue is named '
        "Ilúvatar, made the world and all things in it and they were beautiful.</p>"
    )

    def test_extract_first_heading_returns_none(self):
        result = TextProcessor.extract_first_heading(self.HTML)
        self.assertIsNone(result)

    def test_extract_structural_titles_includes_chapter_1(self):
        # After stripping all nested tags: "CHAPTER 1" (2 words, no terminal punctuation)
        titles = TextProcessor.extract_structural_titles(self.HTML)
        titles_cf = [t.casefold() for t in titles]
        self.assertIn("chapter 1", titles_cf)

    def test_extract_structural_titles_body_excluded(self):
        titles = TextProcessor.extract_structural_titles(self.HTML)
        self.assertFalse(any("eru" in t.casefold() for t in titles))

    def test_plain_text_chapter_1_present(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("CHAPTER 1", plain)

    def test_plain_text_does_not_contain_href_artifact(self):
        # split_002.html should be stripped by ARTIFACT_RE
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertNotIn("split_002", plain)

    def test_prepare_speech_text_chapter_1_gets_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("CHAPTER 1.", speech)

    def test_prepare_speech_text_chapter_1_before_body(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertLess(speech.index("CHAPTER 1"), speech.index("Eru"))
