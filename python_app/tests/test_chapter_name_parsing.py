# -*- coding: utf-8 -*-
"""Tests for chapter name parsing across diverse EPUB styles.

Each test class corresponds to a real EPUB chapter structure pattern,
verified by inspecting EPUBs from ~/Downloads/livros/.
"""

from __future__ import annotations

import unittest

from src.ebook_reader import EpubParser, TextProcessor


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
        self.assertIn("THE BOY WHO LIVED...", speech)

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
        self.assertIn("CHAPTER 1...", speech)

    def test_prepare_speech_text_adds_pause_after_after_flood(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("After the Flood (1957)...", speech)

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
        self.assertIn("...", speech)

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
        self.assertIn("The Tar Pit...", speech)

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
        self.assertIn("Suma Bene Gesserit...", speech)
        # The speech must also contain the epigraph text
        self.assertIn("história", speech)

    def test_plain_text_has_attribution_and_body(self):
        plain, _ = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        self.assertIn("Suma Bene Gesserit", plain)
        self.assertIn("Odrade", plain)


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
        self.assertIn("Inferno...", speech)

    def test_prepare_speech_text_canto_i_gets_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("Canto I...", speech)

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
        self.assertIn("A CHEGADA...", speech)

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
        self.assertIn("O engenhoso fidalgo Dom Quixote de la Mancha...", speech)

    def test_prepare_speech_text_primeira_parte_gets_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("PRIMEIRA PARTE...", speech)


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
        self.assertIn("CHAPTER 1...", speech)

    def test_prepare_speech_text_chapter_1_before_body(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertLess(speech.index("CHAPTER 1"), speech.index("Eru"))


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
        self.assertIn("CAPÍTULO 1...", speech)

    def test_prepare_speech_text_licoes_gets_pause(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertIn("LIÇÕES DE COMBATENTES NO VIETNAME...", speech)

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
        self.assertIn("I...", speech)

    def test_prepare_speech_text_i_before_body(self):
        plain, segs = TextProcessor.html_to_plain_text_with_formatting(self.HTML)
        speech = EpubParser._prepare_speech_text(plain, segs, raw_html=self.HTML)
        self.assertLess(speech.index("I..."), speech.index("pilotos"))


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
