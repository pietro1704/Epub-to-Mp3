# -*- coding: utf-8 -*-
"""
Unit tests for EbookReader class
"""

import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from python_app.tests._ebook_reader_chapter_titles_cases import (
    TestChapterNameFromToc as TestChapterNameFromToc,
)
from python_app.tests._ebook_reader_chapter_titles_cases import (
    TestRestoreChapterNameStripping as TestRestoreChapterNameStripping,
)
from python_app.tests._ebook_reader_css_subchapter_cases import CssSubchapterCases
from python_app.tests._ebook_reader_footnote_placement_cases import (
    TestFootnoteNotInTocRegression as TestFootnoteNotInTocRegression,
)
from python_app.tests._ebook_reader_locale_cues_cases import (
    TestCueLocaleFollowsBookLanguage as TestCueLocaleFollowsBookLanguage,
)
from python_app.tests._ebook_reader_metadata_cases import TestEbookReader as TestEbookReader
from python_app.tests._ebook_reader_numeric_headings_cases import (
    TestNumericHeadingSplitter as TestNumericHeadingSplitter,
)
from python_app.tests._ebook_reader_paragraph_fallback_cases import ParagraphFallbackCases
from python_app.tests._ebook_reader_projection_cases import (
    TestHtmlFragmentToChaptersReusableAsStaticmethod as TestHtmlFragmentToChaptersReusableAsStaticmethod,
)
from python_app.tests._ebook_reader_projection_cases import (
    TestParseEpubToDict as TestParseEpubToDict,
)
from python_app.tests._ebook_reader_test_support import Book as Book
from python_app.tests._ebook_reader_test_support import EbookReader as EbookReader
from python_app.tests._ebook_reader_test_support import EpubParser as EpubParser
from python_app.tests._ebook_reader_test_support import Mock as Mock
from python_app.tests._ebook_reader_test_support import os as os
from python_app.tests._ebook_reader_test_support import patch as patch
from python_app.tests._ebook_reader_test_support import tempfile as tempfile
from python_app.tests._ebook_reader_test_support import unittest as unittest
from python_app.tests._ebook_reader_test_support import zipfile as zipfile


class TestReadBookFunction(unittest.TestCase):
    """Test cases for read_book factory function"""

    def test_read_book_function(self):
        """Test read_book factory function"""
        from src.ebook_reader import read_book

        sample_book = Book("Test", "Author", [])

        with patch("src.ebook_reader.EbookReader") as mock_reader_class:
            mock_reader_instance = Mock()
            mock_reader_instance.book = sample_book
            mock_reader_class.return_value = mock_reader_instance

            result = read_book("test.epub")

            mock_reader_class.assert_called_once_with("test.epub")
            self.assertEqual(result, sample_book)


class TestSubchapterDetection(
    CssSubchapterCases,
    ParagraphFallbackCases,
    unittest.TestCase,
):
    """Tests for CSS-marker subchapter splitting and paragraph-boundary fallback."""

    # ------------------------------------------------------------------ helpers

    def _build_epub_bytes(self, chapter_html: str) -> bytes:
        """Return a minimal valid EPUB zip as bytes with one chapter file."""
        import io

        container_xml = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            "<rootfiles>"
            '<rootfile full-path="OEBPS/content.opf"'
            ' media-type="application/oebps-package+xml"/>'
            "</rootfiles></container>"
        )
        opf_content = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<package xmlns="http://www.idpf.org/2007/opf"'
            ' unique-identifier="uid" version="2.0">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            "<dc:title>Test Book</dc:title>"
            "<dc:creator>Test Author</dc:creator>"
            "<dc:language>en</dc:language>"
            "</metadata>"
            "<manifest>"
            '<item id="chapter01" href="chapter01.xhtml"'
            ' media-type="application/xhtml+xml"/>'
            '<item id="ncx" href="toc.ncx"'
            ' media-type="application/x-dtbncx+xml"/>'
            "</manifest>"
            '<spine toc="ncx"><itemref idref="chapter01"/></spine>'
            "</package>"
        )
        ncx_content = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
            '<head><meta name="dtb:uid" content="uid"/></head>'
            "<docTitle><text>Test Book</text></docTitle>"
            "<navMap>"
            '<navPoint id="ch01" playOrder="1">'
            "<navLabel><text>Chapter 11</text></navLabel>"
            '<content src="chapter01.xhtml"/>'
            "</navPoint></navMap></ncx>"
        )
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip")
            zf.writestr("META-INF/container.xml", container_xml)
            zf.writestr("OEBPS/content.opf", opf_content)
            zf.writestr("OEBPS/toc.ncx", ncx_content)
            zf.writestr("OEBPS/chapter01.xhtml", chapter_html)
        return buf.getvalue()

    # ------------------------------------------------------------------ hierarchical TOC indices

    def _build_epub_bytes_nested_toc(
        self, part_html: str, chapter_html: str, chapter_toc_title: str
    ) -> bytes:
        """Build a minimal EPUB with a two-level nav.xhtml TOC:

        Level 1:
          - Parte 2 – Junho de 1958  (part0011.xhtml)

        Level 2 (child of Parte 2):
          - <chapter_toc_title>  (part0012.xhtml)

        Parte 2 is the 5th top-level entry because four front-matter items
        precede it in the nav (matching the real "It: A coisa" structure).
        Those four items reference files that are not in the spine, so only
        part0011 and part0012 are rendered.
        """
        import io

        nav_content = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml"'
            ' xmlns:epub="http://www.idpf.org/2007/ops">'
            "<head><title>nav</title></head><body>"
            '<nav epub:type="toc" hidden="">'
            "<ol>"
            # 4 front-matter level-1 items pointing to files NOT in the spine
            '<li><a href="fm01.xhtml">Capa</a></li>'
            '<li><a href="fm02.xhtml">Folha de Rosto</a></li>'
            '<li><a href="fm03.xhtml">Sumário</a></li>'
            '<li><a href="fm04.xhtml">Parte 1 – A sombra antes</a><ol>'
            '<li><a href="fm05.xhtml">Capítulo 1</a></li>'
            "</ol></li>"
            # Parte 2 = 5th level-1 item → TOC index 5
            '<li><a href="part0011.xhtml">Parte 2 – Junho de 1958</a><ol>'
            f'<li><a href="part0012.xhtml">{chapter_toc_title}</a></li>'
            "</ol></li>"
            "</ol></nav>"
            "</body></html>"
        )
        opf_content = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<package xmlns="http://www.idpf.org/2007/opf"'
            ' unique-identifier="uid" version="3.0">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            "<dc:title>It A coisa (test)</dc:title>"
            "<dc:creator>Stephen King</dc:creator>"
            "<dc:language>pt-BR</dc:language>"
            "</metadata>"
            "<manifest>"
            '<item id="nav" href="nav.xhtml"'
            ' media-type="application/xhtml+xml"'
            ' properties="nav"/>'
            '<item id="part0011" href="part0011.xhtml"'
            ' media-type="application/xhtml+xml"/>'
            '<item id="part0012" href="part0012.xhtml"'
            ' media-type="application/xhtml+xml"/>'
            "</manifest>"
            "<spine>"
            '<itemref idref="part0011"/>'
            '<itemref idref="part0012"/>'
            "</spine>"
            "</package>"
        )
        container_xml = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<container version="1.0"'
            ' xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            "<rootfiles>"
            '<rootfile full-path="OEBPS/content.opf"'
            ' media-type="application/oebps-package+xml"/>'
            "</rootfiles></container>"
        )
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip")
            zf.writestr("META-INF/container.xml", container_xml)
            zf.writestr("OEBPS/content.opf", opf_content)
            zf.writestr("OEBPS/nav.xhtml", nav_content)
            zf.writestr("OEBPS/part0011.xhtml", part_html)
            zf.writestr("OEBPS/part0012.xhtml", chapter_html)
        return buf.getvalue()

    def test_nested_toc_hierarchical_index_and_css_split(self):
        """IT-style nested TOC + section markers without class_sG5 produce:
        - Parte 2  → index 5  (5th top-level TOC item)
        - Capítulo 4 splits → indices "5.1.1", "5.1.2"
        - Section names include the chapter TOC title + section number + content start.

        This encodes the expected parsing from the user's report:
          end of 5.1.1: last paragraph before "2" marker
          start of 5.1.2: the "2" marker paragraph
          name 5.1.1: "<chapter title> - 1 - <first content words>"
          name 5.1.2: "<chapter title> - 2 - <first content words>"
        """
        part_html = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml">'
            "<head><title>Parte 2</title></head><body>"
            "<h1>Parte 2 – Junho de 1958</h1>"
            "<p>Introduction paragraph for Parte 2.</p>"
            "</body></html>"
        )
        chapter_html = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml">'
            "<head><title>part0012</title></head><body>"
            '<div class="class_s11-0">'
            '<p class="class_s3J-0">Capítulo 4</p>'
            '<p class="class_s3M-0">Ben Hanscom sofre uma queda</p>'
            # Section 1 — no class_sG5 title
            '<p class="class_s3P-0">1</p>'
            '<p class="class_s1PD-0">Por volta das 23h45, uma das comissárias.</p>'
            '<p class="class_s4G-0">A escola.</p>'
            '<p class="class_s4G-0">A escola</p>'
            # Section 2 — no class_sG5 title
            '<p class="class_s42-0">2</p>'
            '<p class="class_s1S-0">acabou!</p>'
            '<p class="class_s3T-0">O som do sino se espalhou pelos corredores.</p>'
            "</div></body></html>"
        )
        chapter_toc_title = "Capítulo 4 – Ben Hanscom sofre uma queda"

        epub_bytes = self._build_epub_bytes_nested_toc(part_html, chapter_html, chapter_toc_title)
        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as tmp:
            tmp.write(epub_bytes)
            tmp_path = tmp.name
        try:
            reader = EbookReader(tmp_path)
            chapters = reader.get_chapters()
        finally:
            os.unlink(tmp_path)

        # Parte 2 (part0011) = 1 unsplit chapter with index 5
        parte2_chapters = [ch for ch in chapters if str(ch.index) == "5"]
        self.assertEqual(len(parte2_chapters), 1, "Parte 2 should be a single chapter")

        # Capítulo 4 (part0012) splits into exactly 2 CSS-marker sections
        cap4_chapters = [ch for ch in chapters if str(ch.index).startswith("5.1")]
        self.assertEqual(len(cap4_chapters), 2, f"Expected 2 sections, got {len(cap4_chapters)}")

        # --- Section 1 (5.1.1) ---
        s1 = cap4_chapters[0]
        self.assertEqual(str(s1.index), "5.1.1")
        # Name contains chapter TOC title + section number + first content words
        self.assertIn("Capítulo 4", s1.name)
        self.assertIn(" - 1 - ", s1.name)
        self.assertIn("Por volta das 23h45", s1.name)
        # Text ends with the last section-1 paragraph ("A escola"), NOT the "2" marker
        self.assertTrue(
            s1.text.rstrip().endswith("A escola"),
            f"Section 1 should end with 'A escola', got: {s1.text[-60:]!r}",
        )
        self.assertNotIn("\n2\n", s1.text)

        # --- Section 2 (5.1.2) ---
        s2 = cap4_chapters[1]
        self.assertEqual(str(s2.index), "5.1.2")
        # Name contains chapter TOC title + section number + first content words
        self.assertIn("Capítulo 4", s2.name)
        self.assertIn(" - 2 - ", s2.name)
        self.assertIn("acabou", s2.name)
        # Text starts with "2" (the section number spoken as plain text)
        self.assertTrue(
            s2.text.lstrip().startswith("2\n"),
            f"Section 2 text should start with '2', got: {s2.text[:60]!r}",
        )
        self.assertIn("O som do sino", s2.text)

    def test_oversized_css_section_gets_dash_split(self):
        """A CSS-marker section that exceeds paragraph_split_chars is further split
        at paragraph boundaries with a dash suffix: e.g. '5.1.2-1', '5.1.2-2'.
        This distinguishes char-limit cuts from structural CSS-marker splits.
        Requires paragraph_split=True on EbookReader."""
        # Use a low threshold so the test does not need huge text.
        _SPLIT_CHARS = 500

        # Build a section-2 body that exceeds the char limit.
        long_para = "Palavra " * 400 + "fim."  # ~3 200 chars
        n_paras = (_SPLIT_CHARS // max(len(long_para), 1)) + 2
        section2_body = "".join(f'<p class="class_s3T-0">{long_para}</p>' for _ in range(n_paras))

        chapter_html = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml">'
            "<head><title>part0012</title></head><body>"
            '<div class="class_s11-0">'
            '<p class="class_s3J-0">Capítulo 4</p>'
            '<p class="class_s3M-0">Ben Hanscom sofre uma queda</p>'
            '<p class="class_s3P-0">1</p>'
            '<p class="class_s1PD-0">Seção um, parágrafo curto.</p>'
            '<p class="class_s42-0">2</p>'
            '<p class="class_s1S-0">Início da seção dois longa.</p>'
            + section2_body
            + "</div></body></html>"
        )
        part_html = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml">'
            "<head><title>Parte 2</title></head><body>"
            "<h1>Parte 2</h1><p>Intro.</p>"
            "</body></html>"
        )

        epub_bytes = self._build_epub_bytes_nested_toc(
            part_html, chapter_html, "Capítulo 4 – Ben Hanscom sofre uma queda"
        )
        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as tmp:
            tmp.write(epub_bytes)
            tmp_path = tmp.name
        try:
            # paragraph_split_chars=500 triggers auto-split on oversized sections
            reader = EbookReader(tmp_path, paragraph_split_chars=500)
            chapters = reader.get_chapters()
        finally:
            os.unlink(tmp_path)

        # Section 1 (small) → single chapter with index "5.1.1"
        s1_list = [ch for ch in chapters if str(ch.index) == "5.1.1"]
        self.assertEqual(len(s1_list), 1)

        # Section 2 (large) → multiple dash-split chapters "5.1.2-1", "5.1.2-2", ...
        s2_splits = [ch for ch in chapters if str(ch.index).startswith("5.1.2-")]
        self.assertGreater(len(s2_splits), 1, "Oversized section 2 must be split")
        for i, ch in enumerate(s2_splits, 1):
            self.assertEqual(str(ch.index), f"5.1.2-{i}")

        # No "5.1.2.1" style indices should appear
        dot_splits = [ch for ch in chapters if str(ch.index).startswith("5.1.2.")]
        self.assertEqual(len(dot_splits), 0, "Dot-suffix paragraph splits must not appear")


if __name__ == "__main__":
    unittest.main()
