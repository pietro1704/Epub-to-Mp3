# -*- coding: utf-8 -*-
"""
Unit tests for EbookReader class
"""

import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import Mock, patch

from src.ebook_reader import (
    Book,
    Chapter,
    EbookReader,
    EpubParser,
    PdfParser,
    parse_epub_to_dict,
)


class TestEbookReader(unittest.TestCase):
    """Test cases for EbookReader class"""

    def setUp(self):
        """Set up test fixtures"""
        self.temp_dir = tempfile.mkdtemp()
        self.sample_epub_path = os.path.join(self.temp_dir, "test.epub")
        self.sample_pdf_path = os.path.join(self.temp_dir, "test.pdf")

        # Create dummy files
        with open(self.sample_epub_path, "w") as f:
            f.write("dummy epub")
        with open(self.sample_pdf_path, "w") as f:
            f.write("dummy pdf")

        # Sample book data
        self.sample_chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2"),
        ]
        self.sample_book = Book("Test Book", "Test Author", self.sample_chapters)

    def tearDown(self):
        """Clean up test fixtures"""
        for file_path in [self.sample_epub_path, self.sample_pdf_path]:
            if os.path.exists(file_path):
                os.remove(file_path)
        os.rmdir(self.temp_dir)

    def test_init_without_file(self):
        """Test EbookReader initialization without file path"""
        reader = EbookReader()
        self.assertIsNone(reader.file_path)
        self.assertIsNone(reader.book)

    def test_init_with_string_path(self):
        """Test EbookReader initialization with string path"""
        with patch.object(EbookReader, "load") as mock_load:
            reader = EbookReader("test.epub")
            self.assertEqual(reader.file_path, Path("test.epub"))
            mock_load.assert_called_once_with("test.epub", paragraph_split_chars=0)

    def test_init_with_path_object(self):
        """Test EbookReader initialization with Path object"""
        path_obj = Path("test.epub")
        with patch.object(EbookReader, "load") as mock_load:
            reader = EbookReader(path_obj)
            self.assertEqual(reader.file_path, path_obj)
            mock_load.assert_called_once_with(path_obj, paragraph_split_chars=0)

    @patch.object(EpubParser, "parse")
    def test_load_epub_file(self, mock_parse):
        """Test loading EPUB file"""
        mock_parse.return_value = self.sample_book

        reader = EbookReader()
        reader.load(self.sample_epub_path)

        self.assertEqual(reader.file_path, Path(self.sample_epub_path))
        self.assertEqual(reader.book, self.sample_book)
        mock_parse.assert_called_once()

    @patch.object(PdfParser, "parse")
    def test_load_pdf_file(self, mock_parse):
        """Test loading PDF file"""
        mock_parse.return_value = self.sample_book

        reader = EbookReader()
        reader.load(self.sample_pdf_path)

        self.assertEqual(reader.file_path, Path(self.sample_pdf_path))
        self.assertEqual(reader.book, self.sample_book)
        mock_parse.assert_called_once()

    def test_load_nonexistent_file(self):
        """Test loading non-existent file"""
        reader = EbookReader()

        with self.assertRaises(FileNotFoundError) as context:
            reader.load("/path/that/does/not/exist.epub")

        self.assertIn("File not found", str(context.exception))

    def test_load_unsupported_format(self):
        """Test loading unsupported file format"""
        unsupported_path = os.path.join(self.temp_dir, "test.txt")
        with open(unsupported_path, "w") as f:
            f.write("dummy content")

        reader = EbookReader()

        with self.assertRaises(ValueError) as context:
            reader.load(unsupported_path)

        self.assertIn("Unsupported format", str(context.exception))

        os.remove(unsupported_path)

    def test_load_path_object(self):
        """Test loading with Path object"""
        with patch.object(EpubParser, "parse") as mock_parse:
            mock_parse.return_value = self.sample_book

            reader = EbookReader()
            reader.load(Path(self.sample_epub_path))

            self.assertEqual(reader.file_path, Path(self.sample_epub_path))
            mock_parse.assert_called_once()

    def test_title_property_with_book(self):
        """Test title property when book is loaded"""
        reader = EbookReader()
        reader.book = self.sample_book

        self.assertEqual(reader.title, "Test Book")

    def test_title_property_without_book(self):
        """Test title property when no book is loaded"""
        reader = EbookReader()

        self.assertEqual(reader.title, "")

    def test_author_property_with_book(self):
        """Test author property when book is loaded"""
        reader = EbookReader()
        reader.book = self.sample_book

        self.assertEqual(reader.author, "Test Author")

    def test_author_property_without_book(self):
        """Test author property when no book is loaded"""
        reader = EbookReader()

        self.assertEqual(reader.author, "")

    def test_get_chapters_with_book(self):
        """Test get_chapters when book is loaded"""
        reader = EbookReader()
        reader.book = self.sample_book

        chapters = reader.get_chapters()
        self.assertEqual(len(chapters), 2)
        self.assertEqual(chapters[0].name, "Chapter 1")
        self.assertEqual(chapters[1].name, "Chapter 2")

    def test_get_chapters_without_book(self):
        """Test get_chapters when no book is loaded"""
        reader = EbookReader()

        chapters = reader.get_chapters()
        self.assertEqual(chapters, [])

    @patch.object(EbookReader, "load")
    def test_read_ebook_success(self, mock_load):
        """Test read_ebook method success case"""
        reader = EbookReader()
        reader.book = self.sample_book

        title, author, chapters = reader.read_ebook("test.epub")

        mock_load.assert_called_once_with("test.epub")
        self.assertEqual(title, "Test Book")
        self.assertEqual(author, "Test Author")
        self.assertEqual(len(chapters), 2)
        self.assertEqual(chapters[0], ("Chapter 1", "Content 1"))
        self.assertEqual(chapters[1], ("Chapter 2", "Content 2"))

    @patch.object(EbookReader, "load")
    def test_read_ebook_no_book(self, mock_load):
        """Test read_ebook when no book is loaded"""
        reader = EbookReader()
        reader.book = None

        title, author, chapters = reader.read_ebook("test.epub")

        mock_load.assert_called_once_with("test.epub")
        self.assertEqual(title, "")
        self.assertEqual(author, "")
        self.assertEqual(chapters, [])

    def test_get_chapter_structure_preserve_all_true(self):
        """Test get_chapter_structure with preserve_all=True"""
        reader = EbookReader()
        reader.book = self.sample_book

        chapters = reader.get_chapter_structure(preserve_all=True)

        self.assertEqual(len(chapters), 2)
        self.assertEqual(chapters, self.sample_chapters)

    def test_get_chapter_structure_preserve_all_false(self):
        """Test get_chapter_structure with preserve_all=False (filtering)"""
        # Create chapters with different text lengths
        short_chapter = Chapter(1, "Short", "short.html", "Hi")  # 2 chars
        long_chapter = Chapter(2, "Long", "long.html", "A" * 200)  # 200 chars

        book_with_mixed = Book("Test", "Author", [short_chapter, long_chapter])

        reader = EbookReader()
        reader.book = book_with_mixed

        chapters = reader.get_chapter_structure(preserve_all=False)

        # Should filter out chapters with less than 100 chars
        self.assertEqual(len(chapters), 1)
        self.assertEqual(chapters[0].name, "Long")

    def test_epub_parser_extracts_inline_footnotes(self):
        """Inline footnotes should be rendered into the chapter text."""
        fixture_path = (
            Path(__file__).resolve().parent / "fixtures" / "epubs" / "test_multifeature.epub"
        )
        self.assertTrue(fixture_path.exists())
        reader = EbookReader(fixture_path)

        chapters = reader.get_chapters()
        self.assertGreaterEqual(len(chapters), 1)

        first_chapter = chapters[0]
        self.assertIsNotNone(first_chapter.footnotes)
        self.assertEqual(len(first_chapter.footnotes or []), 1)

        self.assertIn("Este é o início do nosso experimento", first_chapter.text)
        self.assertIn("_itálico_", first_chapter.text)
        self.assertIn("nota de rodapé 1", first_chapter.text)
        self.assertIn("fim da nota de rodapé", first_chapter.text)

    def test_get_chapter_structure_no_book(self):
        """Test get_chapter_structure when no book is loaded"""
        reader = EbookReader()

        chapters = reader.get_chapter_structure()
        self.assertEqual(chapters, [])

    def test_get_chapter_structure_default_preserve_all(self):
        """Test get_chapter_structure default parameter (preserve_all=True)"""
        reader = EbookReader()
        reader.book = self.sample_book

        chapters = reader.get_chapter_structure()  # Default should be True

        self.assertEqual(len(chapters), 2)
        self.assertEqual(chapters, self.sample_chapters)

    @patch.object(EpubParser, "parse")
    def test_case_insensitive_extensions(self, mock_parse):
        """Test that file extensions are case insensitive"""
        mock_parse.return_value = self.sample_book

        # Test uppercase extension
        uppercase_epub = os.path.join(self.temp_dir, "test.EPUB")
        with open(uppercase_epub, "w") as f:
            f.write("dummy")

        reader = EbookReader()
        reader.load(uppercase_epub)

        mock_parse.assert_called_once()
        os.remove(uppercase_epub)

    @patch.object(EpubParser, "parse")
    def test_mixed_case_extensions(self, mock_parse):
        """Test mixed case file extensions"""
        mock_parse.return_value = self.sample_book

        mixed_case_epub = os.path.join(self.temp_dir, "test.ePuB")
        with open(mixed_case_epub, "w") as f:
            f.write("dummy")

        reader = EbookReader()
        reader.load(mixed_case_epub)

        mock_parse.assert_called_once()
        os.remove(mixed_case_epub)

    @patch.object(EpubParser, "__init__")
    def test_parser_initialization(self, mock_epub_init):
        """Test that parsers are initialized with correct file paths"""
        mock_epub_init.return_value = None

        with patch.object(EpubParser, "parse") as mock_parse:
            mock_parse.return_value = self.sample_book

            reader = EbookReader()
            reader.load(self.sample_epub_path)

            mock_epub_init.assert_called_once_with(self.sample_epub_path, paragraph_split_chars=0)

    def test_file_path_conversion_string(self):
        """Test file path is properly converted to Path object from string"""
        with patch.object(EbookReader, "load") as mock_load:
            reader = EbookReader("test.epub")
            self.assertIsInstance(reader.file_path, Path)
            self.assertEqual(str(reader.file_path), "test.epub")

    def test_file_path_conversion_none(self):
        """Test file path handling when None is passed"""
        reader = EbookReader(None)
        self.assertIsNone(reader.file_path)


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


class TestSubchapterDetection(unittest.TestCase):
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

    # ------------------------------------------------------------------ unit tests for static methods

    def test_split_on_markers_it_style_number_plus_title(self):
        """Detects the IT book pattern: class_s3P-0 "1" + class_sG5 title, then
        class_s42-0 "N" + class_sG5 title for subsequent sections."""
        html = (
            '<p class="class_s3J-0">Chapter 11</p>'
            '<p class="class_s3M-0">Walks</p>'
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Ben makes a retreat</p>'
            '<p class="class_s1S-1">Body of section 1.</p>'
            '<p class="class_s42-0">2</p>'
            '<p class="class_sG5">Richie builds castles</p>'
            '<p class="class_s1S-1">Body of section 2.</p>'
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, 11, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )

        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0][0], "11.1")
        self.assertEqual(result[0][1], "Ben makes a retreat")
        self.assertEqual(result[1][0], "11.2")
        self.assertEqual(result[1][1], "Richie builds castles")

    def test_split_on_markers_number_at_start_of_correct_fragment(self):
        """The section-number paragraph must be at the START of its fragment,
        not appended to the previous one (regression for the original split-at-title bug)."""
        html = (
            '<p class="class_s3J-0">Chapter 11</p>'
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Section One</p>'
            '<p class="body">First section content.</p>'
            '<p class="class_s42-0">2</p>'
            '<p class="class_sG5">Section Two</p>'
            '<p class="body">Second section content.</p>'
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, 5, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )

        self.assertIsNotNone(result)
        frag1, frag2 = result[0][2], result[1][2]
        # class_s42-0 "2" must be in fragment 2, not fragment 1.
        self.assertIn("class_s42-0", frag2)
        self.assertNotIn("class_s42-0", frag1)
        # class_s3P-0 "1" is in fragment 1 (via preamble prepend).
        self.assertIn("class_s3P-0", frag1)

    def test_split_on_markers_preamble_in_first_fragment(self):
        """Content before the first number element is included in the first fragment."""
        html = (
            '<p class="class_s3J-0">Chapter Title</p>'
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Section One</p>'
            "<p>Section one body.</p>"
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, 5, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )

        self.assertIsNotNone(result)
        self.assertEqual(len(result), 1)
        # Preamble paragraph class must appear in the first fragment.
        self.assertIn("class_s3J-0", result[0][2])

    def test_split_on_markers_no_markers_returns_none(self):
        """Returns None when the HTML contains no subchapter number elements."""
        html = "<p>Just a normal paragraph.</p><p>Another paragraph.</p>"
        result = EpubParser._split_html_on_subchapter_markers(
            html, 3, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )
        self.assertIsNone(result)

    def test_split_on_markers_empty_number_class_set_returns_none(self):
        """Returns None when the number class set is empty."""
        html = '<p class="class_s3P-0">1</p>' '<p class="class_sG5">Title</p><p>Body.</p>'
        result = EpubParser._split_html_on_subchapter_markers(html, 1, frozenset(), "class_sG5")
        self.assertIsNone(result)

    def test_split_on_markers_number_without_following_title_is_skipped(self):
        """A number element with no paragraph closing within the 2000-char fallback
        window is skipped (the split is abandoned for that marker)."""
        # The noise paragraph is 2100 chars long — its </p> is outside the 2000-char
        # fallback window, so neither the explicit title search nor the any-paragraph
        # fallback finds content, and the number element is skipped → None.
        html = (
            '<p class="class_s42-0">2</p>'
            + '<p class="noise">'
            + "x" * 2100
            + "</p>"
            + '<p class="class_sG5">Late title</p>'
            + "<p>Body.</p>"
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, 3, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )
        self.assertIsNone(result)

    def test_split_on_markers_string_parent_index(self):
        """Parent index can be a string; sub-indices are formatted correctly."""
        html = (
            '<p class="class_s3P-0">1</p><p class="class_sG5">A</p><p>body a</p>'
            '<p class="class_s42-0">2</p><p class="class_sG5">B</p><p>body b</p>'
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, "7", frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )
        self.assertIsNotNone(result)
        self.assertEqual(result[0][0], "7.1")
        self.assertEqual(result[1][0], "7.2")

    def test_split_on_markers_six_subchapters_it_style(self):
        """All 6 subchapter markers in IT ch.11 are detected correctly."""
        parts = [
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Section 1</p>'
            '<p class="body">Content of section 1.</p>'
        ]
        for i in range(2, 7):
            parts.append(
                f'<p class="class_s42-0">{i}</p>'
                f'<p class="class_sG5">Section {i}</p>'
                f'<p class="body">Content of section {i}.</p>'
            )
        html = '<p class="class_s3J-0">Chapter 11</p>' + "".join(parts)
        result = EpubParser._split_html_on_subchapter_markers(
            html, 11, frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 6)
        for i, entry in enumerate(result, start=1):
            idx, title = entry[0], entry[1]
            self.assertEqual(idx, f"11.{i}")
            self.assertEqual(title, f"Section {i}")

    def test_paragraph_split_oversized_chapter(self):
        """Chapters exceeding SUBCHAPTER_MAX_CHARS are split at line boundaries
        and get a dash-suffix index (e.g. "7-1", "7-2")."""
        # EPUB plain text uses single \n between paragraphs.
        para = "Word " * 200  # ~1 000 chars each
        text = "\n".join([para] * 60)  # ~60 000 chars total

        result = EpubParser._split_text_at_paragraph_boundaries(text, 50_000, 7)

        self.assertGreater(len(result), 1)
        for idx, chunk in result:
            self.assertTrue(idx.startswith("7-"), f"Expected dash index, got {idx!r}")
        # Each chunk should not vastly exceed the limit (some slack for last line).
        for _, chunk in result:
            self.assertLessEqual(len(chunk), 55_000)

    def test_paragraph_split_small_chapter_unchanged(self):
        """Small chapters are returned as-is with the original (non-decimal) index."""
        text = "Short chapter.\nSecond paragraph."
        result = EpubParser._split_text_at_paragraph_boundaries(text, 50_000, 3)

        self.assertEqual(len(result), 1)
        self.assertEqual(result[0][0], "3")
        self.assertEqual(result[0][1], text)

    def test_paragraph_split_exact_boundary(self):
        """A chapter that barely fits is returned with the original index."""
        text = "A" * 49_999
        result = EpubParser._split_text_at_paragraph_boundaries(text, 50_000, 2)

        self.assertEqual(len(result), 1)
        self.assertEqual(result[0][0], "2")

    def test_paragraph_split_uses_dash_suffix(self):
        """Paragraph-boundary splits use a dash suffix ("N-1", "N-2") so they
        are visually distinct from CSS-marker decimal splits ("N.1", "N.2")."""
        para = "Paragraph text. " * 50  # ~800 chars each
        text = "\n".join([para] * 10)  # ~8 000 chars total
        result = EpubParser._split_text_at_paragraph_boundaries(text, 3_000, 4)

        self.assertGreater(len(result), 1)
        for i, (idx, _) in enumerate(result, 1):
            self.assertEqual(idx, f"4-{i}", f"Expected '4-{i}', got {idx!r}")

    def test_paragraph_split_dash_with_string_parent_index(self):
        """Dash suffix also works when parent_index is a hierarchical string."""
        para = "Long paragraph content. " * 60  # ~1 440 chars each
        text = "\n".join([para] * 20)  # ~28 800 chars total
        result = EpubParser._split_text_at_paragraph_boundaries(text, 10_000, "5.1.3")

        self.assertGreater(len(result), 1)
        for i, (idx, _) in enumerate(result, 1):
            self.assertEqual(idx, f"5.1.3-{i}", f"Expected '5.1.3-{i}', got {idx!r}")

    def test_paragraph_split_long_single_line_uses_epub_parser_splitter(self):
        """A single oversized line is force-split without calling EbookReader."""
        text = "word " * 15_000

        result = EpubParser._split_text_at_paragraph_boundaries(text, 50_000, 9)

        self.assertGreater(len(result), 1)
        for idx, chunk in result:
            self.assertTrue(idx.startswith("9-"), f"Expected dash index, got {idx!r}")
            self.assertLessEqual(len(chunk), 50_000)

    # ------------------------------------------------------------------ integration tests

    def test_epub_with_subchapter_markers_creates_decimal_chapters(self):
        """Full EPUB parse: IT-style number+title markers produce decimal-indexed chapters."""
        chapter_html = (
            '<?xml version="1.0" encoding="utf-8"?>'
            "<!DOCTYPE html>"
            '<html xmlns="http://www.w3.org/1999/xhtml">'
            "<head><title>Chapter 11</title></head><body>"
            '<div class="class_s11-0">'
            '<p class="class_s3J-0">Chapter 11</p>'
            '<p class="class_s3M-0">Walks</p>'
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Ben makes a retreat</p>'
            '<p class="class_s1S-1">This is the first section body text here.</p>'
            '<p class="class_s42-0">2</p>'
            '<p class="class_sG5">Richie builds castles</p>'
            '<p class="class_s1S-1">This is the second section body text here.</p>'
            "</div></body></html>"
        )
        epub_bytes = self._build_epub_bytes(chapter_html)
        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as tmp:
            tmp.write(epub_bytes)
            tmp_path = tmp.name
        try:
            reader = EbookReader(tmp_path)
            chapters = reader.get_chapters()
        finally:
            os.unlink(tmp_path)

        self.assertEqual(len(chapters), 2)
        self.assertEqual(chapters[0].index, "1.1")
        self.assertEqual(chapters[0].name, "Ben makes a retreat")
        self.assertIn("first section body", chapters[0].text)
        self.assertEqual(chapters[1].index, "1.2")
        self.assertEqual(chapters[1].name, "Richie builds castles")
        self.assertIn("second section body", chapters[1].text)

    def test_epub_without_markers_single_chapter(self):
        """EPUB without subchapter markers produces a single Chapter per spine file."""
        chapter_html = (
            '<?xml version="1.0" encoding="utf-8"?>'
            "<!DOCTYPE html>"
            '<html xmlns="http://www.w3.org/1999/xhtml">'
            "<head><title>Chapter 1</title></head><body>"
            "<h1>Chapter One</h1>"
            "<p>This is the body text without any subchapter markers.</p>"
            "</body></html>"
        )
        epub_bytes = self._build_epub_bytes(chapter_html)
        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as tmp:
            tmp.write(epub_bytes)
            tmp_path = tmp.name
        try:
            reader = EbookReader(tmp_path)
            chapters = reader.get_chapters()
        finally:
            os.unlink(tmp_path)

        self.assertEqual(len(chapters), 1)
        self.assertIsInstance(chapters[0].index, int)

    # ------------------------------------------------------------------ ch4-style (no class_sG5 title)

    def test_split_markers_no_title_class_fallback_to_first_paragraph(self):
        """When no class_sG5 follows the number marker, the first paragraph's
        text is used as the section title (IT chapter-4 pattern)."""
        # This mirrors the real HTML structure of "It: A coisa" ch.4 where section
        # numbers are NOT followed by a dedicated class_sG5 title paragraph.
        html = (
            '<div class="class_s11-0">'
            '<p class="class_s3J-0">Capítulo 4</p>'
            '<p class="class_s3M-0">Ben Hanscom sofre uma queda</p>'
            '<p class="class_s3P-0">1</p>'
            '<p class="class_s1PD-0">Por volta das 23h45, uma das comissárias.</p>'
            '<p class="class_s4G-0">A escola.</p>'
            '<p class="class_s4G-0">A escola</p>'
            '<p class="class_s42-0">2</p>'
            '<p class="class_s1S-0">acabou!</p>'
            '<p class="class_s3T-0">O som do sino se espalhou pelos corredores.</p>'
            "</div>"
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html,
            "5.1",
            frozenset({"class_s3P-0", "class_s42-0"}),
            "class_sG5",
        )

        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)

        # Section 1
        idx1, title1, frag1, explicit1 = result[0]
        self.assertEqual(idx1, "5.1.1")
        self.assertFalse(explicit1, "title was derived from content, not class_sG5")
        self.assertIn("Por volta das 23h45", title1)
        # Section 1 fragment ends before the "2" marker
        self.assertNotIn('class_s42-0">2</p>', frag1)
        # Preamble (chapter heading) is in section 1
        self.assertIn("class_s3J-0", frag1)
        # Last paragraph of section 1 content is present
        self.assertIn("A escola</p>", frag1)

        # Section 2
        idx2, title2, frag2, explicit2 = result[1]
        self.assertEqual(idx2, "5.1.2")
        self.assertFalse(explicit2)
        self.assertIn("acabou", title2)
        # Section 2 fragment starts with the "2" marker
        self.assertTrue(
            frag2.lstrip().startswith('<p class="class_s42-0">2</p>'),
            f"Expected section 2 to start with the number marker, got: {frag2[:80]!r}",
        )
        self.assertIn("O som do sino", frag2)

    def test_split_markers_with_explicit_title_keeps_has_explicit_true(self):
        """Sections that DO have a class_sG5 title report has_explicit_title=True."""
        html = (
            '<p class="class_s3P-0">1</p>'
            '<p class="class_sG5">Stanley Uris toma um banho</p>'
            '<p class="body">Content here.</p>'
            '<p class="class_s42-0">2</p>'
            '<p class="class_sG5">Richie Tozier liga</p>'
            '<p class="body">More content.</p>'
        )
        result = EpubParser._split_html_on_subchapter_markers(
            html, "4.3", frozenset({"class_s3P-0", "class_s42-0"}), "class_sG5"
        )
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)
        _, title1, _, explicit1 = result[0]
        _, title2, _, explicit2 = result[1]
        self.assertTrue(explicit1)
        self.assertTrue(explicit2)
        self.assertEqual(title1, "Stanley Uris toma um banho")
        self.assertEqual(title2, "Richie Tozier liga")

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


class TestNumericHeadingSplitter(unittest.TestCase):
    """Tests for EpubParser._split_html_on_numeric_headings."""

    def _split(self, markup, parent_index="5.1", heading_tags=("h3",)):
        return EpubParser._split_html_on_numeric_headings(markup, parent_index, heading_tags)

    # --- None / insufficient headings ---

    def test_returns_none_when_no_numeric_headings(self):
        markup = "<p>Some content without headings.</p>"
        self.assertIsNone(self._split(markup))

    def test_returns_none_when_only_one_numeric_heading(self):
        markup = "<h3>1</h3><p>Only one section.</p>"
        self.assertIsNone(self._split(markup))

    def test_returns_none_when_only_non_numeric_headings(self):
        markup = "<h3>Introduction</h3><p>First.</p><h3>Conclusion</h3><p>Last.</p>"
        self.assertIsNone(self._split(markup))

    def test_returns_none_for_empty_markup(self):
        self.assertIsNone(self._split(""))

    # --- Correct splitting ---

    def test_splits_at_two_numeric_headings(self):
        markup = "<h3>1</h3><p>Section one content.</p><h3>2</h3><p>Section two content.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)

    def test_splits_at_three_numeric_headings(self):
        markup = "<h3>1</h3><p>Alpha.</p>" "<h3>2</h3><p>Beta.</p>" "<h3>3</h3><p>Gamma.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 3)

    # --- Sub-index format ---

    def test_sub_index_format_uses_parent_dot_n(self):
        markup = "<h3>1</h3><p>A.</p><h3>2</h3><p>B.</p>"
        result = self._split(markup, parent_index="5.1")
        self.assertIsNotNone(result)
        indices = [item[0] for item in result]
        self.assertEqual(indices, ["5.1.1", "5.1.2"])

    def test_sub_index_format_with_simple_parent_index(self):
        markup = "<h3>1</h3><p>A.</p><h3>2</h3><p>B.</p><h3>3</h3><p>C.</p>"
        result = self._split(markup, parent_index="3")
        self.assertIsNotNone(result)
        indices = [item[0] for item in result]
        self.assertEqual(indices, ["3.1", "3.2", "3.3"])

    # --- Non-numeric headings are ignored ---

    def test_non_numeric_headings_are_ignored(self):
        markup = (
            "<h3>Introduction</h3><p>Preamble text.</p>"
            "<h3>1</h3><p>First section.</p>"
            "<h3>2</h3><p>Second section.</p>"
        )
        result = self._split(markup, parent_index="4")
        self.assertIsNotNone(result)
        # Only the two numeric headings produce sections
        self.assertEqual(len(result), 2)
        indices = [item[0] for item in result]
        self.assertEqual(indices, ["4.1", "4.2"])

    def test_mixed_text_heading_does_not_qualify(self):
        markup = "<h3>Chapter One</h3><p>A.</p><h3>1</h3><p>B.</p><h3>2</h3><p>C.</p>"
        result = self._split(markup, parent_index="2")
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)

    # --- has_explicit_title is always False ---

    def test_has_explicit_title_is_false_for_all_items(self):
        markup = "<h3>1</h3><p>A.</p><h3>2</h3><p>B.</p><h3>3</h3><p>C.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        for sub_index, sub_title, html_fragment, has_explicit_title in result:
            self.assertFalse(
                has_explicit_title,
                f"has_explicit_title should be False for '{sub_index}', got {has_explicit_title}",
            )

    # --- Preamble prepended to section 1 ---

    def test_preamble_is_prepended_to_first_section_fragment(self):
        preamble = "<p>Book preamble before any section.</p>"
        markup = f"{preamble}<h3>1</h3><p>Section one.</p><h3>2</h3><p>Section two.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        # The preamble must appear only in the first fragment
        first_fragment = result[0][2]
        self.assertIn("preamble", first_fragment)
        # Second fragment should NOT contain the preamble text
        second_fragment = result[1][2]
        self.assertNotIn("preamble", second_fragment)

    def test_no_preamble_when_heading_is_first(self):
        markup = "<h3>1</h3><p>Immediate start.</p><h3>2</h3><p>Second.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        first_fragment = result[0][2]
        # Fragment starts at the heading — no extra preamble inserted
        self.assertTrue(first_fragment.startswith("<h3>1</h3>"))

    # --- Tuple structure ---

    def test_each_item_is_four_tuple(self):
        markup = "<h3>1</h3><p>A.</p><h3>2</h3><p>B.</p>"
        result = self._split(markup)
        self.assertIsNotNone(result)
        for item in result:
            self.assertEqual(len(item), 4, f"Each item must be a 4-tuple, got {item}")

    # --- Alternative heading tags ---

    def test_custom_heading_tag_h2(self):
        markup = "<h2>1</h2><p>A.</p><h2>2</h2><p>B.</p>"
        result = self._split(markup, heading_tags=("h2",))
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 2)

    def test_default_h3_does_not_match_h2(self):
        """Default heading_tags=('h3',) should not match <h2> elements."""
        markup = "<h2>1</h2><p>A.</p><h2>2</h2><p>B.</p>"
        result = self._split(markup)
        self.assertIsNone(result)


class TestParseEpubToDict(unittest.TestCase):
    """parse_epub_to_dict — iOS-friendly JSON shape used by PythonBridge."""

    FIXTURE = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"

    def test_returns_dict_with_wire_keys(self):
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        payload = parse_epub_to_dict(str(self.FIXTURE), book_id="abc123")
        self.assertIsInstance(payload, dict)
        for key in ("jobId", "bookTitle", "bookAuthor", "chapters"):
            self.assertIn(key, payload)
        self.assertEqual(payload["jobId"], "abc123")
        self.assertIsInstance(payload["chapters"], list)

    def test_chapter_shape_matches_swift_decoder(self):
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        payload = parse_epub_to_dict(str(self.FIXTURE))
        self.assertGreater(len(payload["chapters"]), 0)
        first = payload["chapters"][0]
        # Keys expected by EbookFulltext.Chapter (Swift Codable).
        for key in ("index", "name", "text", "html", "css", "charCount", "segments"):
            self.assertIn(key, first)
        self.assertIsInstance(first["index"], int)
        self.assertIsInstance(first["text"], str)
        self.assertIsInstance(first["charCount"], int)
        self.assertEqual(first["charCount"], len(first["text"]))
        # Optional fields are None on the iOS path (no raw HTML preserved).
        self.assertIsNone(first["html"])
        self.assertIsNone(first["css"])
        self.assertIsNone(first["segments"])

    def test_empty_chapters_dropped_and_indices_compact(self):
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        payload = parse_epub_to_dict(str(self.FIXTURE))
        indices = [c["index"] for c in payload["chapters"]]
        self.assertEqual(indices, list(range(1, len(indices) + 1)))
        for chapter in payload["chapters"]:
            self.assertGreater(len(chapter["text"]), 0)

    def test_json_roundtrip(self):
        """The dict must be JSON-serialisable — PythonBridge crosses
        the Swift boundary via json.dumps."""
        import json

        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        payload = parse_epub_to_dict(str(self.FIXTURE), book_id="x")
        encoded = json.dumps(payload)
        decoded = json.loads(encoded)
        self.assertEqual(decoded["jobId"], "x")
        self.assertEqual(len(decoded["chapters"]), len(payload["chapters"]))


class TestChapterNameFromToc(unittest.TestCase):
    """Regression: chapter.name must come from TOC navLabel text, NOT the file ID or href.

    Bug: _restore_chapter_entry in server.py used path.stem (e.g. "001 - chapter01")
    as chapter name.  The iOS playableChapters fallback also set name = asset.name
    (raw MP3 filename).  Both caused the UI to show "001 - chapter01" or a sanitised
    hash instead of the human-readable TOC title.
    """

    FIXTURE = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"

    def test_ncx_navlabel_used_as_chapter_name(self):
        """Chapter.name must equal the NCX <navLabel><text> value, never the href/id."""
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        reader = EbookReader(str(self.FIXTURE))
        chapters = reader.get_chapters()
        names = [ch.name for ch in chapters if ch.text.strip()]
        self.assertGreater(len(names), 0, "No chapters parsed")
        for name in names:
            # Must not look like a bare filename stem ("chapter1", "ch01.xhtml")
            self.assertFalse(
                name.lower().startswith("chapter") and (name[7:].replace(".", "").isdigit()),
                f"Chapter name looks like a raw file ID: {name!r}",
            )
        # The fixture NCX labels its first entry "Capítulo 1 - Começo"
        self.assertIn("Capítulo 1", names[0], f"First chapter name was: {names[0]!r}")

    def test_parse_epub_to_dict_name_from_toc(self):
        """parse_epub_to_dict (iOS wire format) must carry TOC names, not file IDs."""
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture missing: {self.FIXTURE}")
        payload = parse_epub_to_dict(str(self.FIXTURE))
        for chapter in payload["chapters"]:
            name = chapter.get("name") or ""
            # Must not be a bare filename like "chapter1" or "chapter1.xhtml"
            self.assertFalse(
                name.lower().startswith("chapter") and name[7:].replace(".", "").isdigit(),
                f"Chapter name looks like a raw file ID: {name!r}",
            )


class TestRestoreChapterNameStripping(unittest.TestCase):
    """Regression: _restore_chapter_entry must strip the 'NNN - ' prefix from MP3 stems.

    When a job's .jobs/ JSON is lost and the backend reconstructs progress from
    output MP3 files, it used to set name=path.stem → "001 - Chapter Title".
    The fix strips the leading numeric prefix so the iOS client sees "Chapter Title".
    """

    def test_numeric_prefix_stripped(self):
        import re

        # The canonical filename format is "{NNN:03d} - {safe_name}.mp3", so
        # the prefix always has spaces surrounding the dash.  The regex must
        # only strip "NNN - " (with surrounding spaces) to avoid eating
        # hyphens that appear inside real chapter titles like "42-Plain".
        stems = [
            ("001 - Prologue", "Prologue"),
            ("023 - The Last Chapter", "The Last Chapter"),
            ("001 – Introduction", "Introduction"),  # en-dash with spaces
            ("42-Plain", "42-Plain"),  # no surrounding spaces → keep as-is
            ("Chapter", "Chapter"),  # no prefix at all
        ]
        for raw, expected in stems:
            # Use same regex as server.py _restore_chapter_entry: spaces required
            result = re.sub(r"^\d+\s+[-–]\s+", "", raw).strip() or raw
            self.assertEqual(result, expected, f"Input: {raw!r}")


class TestFootnoteNotInTocRegression(unittest.TestCase):
    """Regression tests for parser bugs fixed in ebook_reader.py.

    Bug batch 1 — endnote containers + empty chapters:
      1. Spine items whose body opens with role="doc-endnotes" / epub:type="endnotes"
         (e.g. Hobbit_note_N.xhtml) must NOT be promoted to chapters.
      2. Spine items that produce empty text (cover images, blank separators)
         must be dropped from the chapter list.

    Bug batch 2 — heading-embedded footnote refs + spurious navigation footnotes:
      3. A footnote reference inside a chapter heading (<h1 role="doc-noteref">)
         must cause the note to appear at the END of the chapter prose, not
         before the first paragraph (i.e. the heading text must be the first
         thing in chapter.text).
      4. A navigation anchor (long anchor text ≥ 3 words, e.g. "Chapter Title")
         must NOT be collected as a footnote — only short symbols/numbers qualify.

    Fixture: python_app/tests/fixtures/epubs/footnote_not_in_toc.epub
      Spine:  cover | chap1 | chap2 | note1 | note2
      TOC:              chap1   chap2
      Expected chapters: 2 (chap1 with heading-embedded noteref, chap2 with body noteref)
      cover: empty → dropped; note1/2: endnote containers → excluded.
    """

    FIXTURE = Path(__file__).parent / "fixtures" / "epubs" / "footnote_not_in_toc.epub"

    def setUp(self):
        if not self.FIXTURE.exists():
            self.skipTest(f"Fixture not found: {self.FIXTURE}")

    def _load(self):
        return EbookReader(self.FIXTURE).get_chapters()

    def test_endnote_containers_not_in_toc_are_excluded(self):
        """note1.xhtml (doc-endnotes) and note2.xhtml (epub:type=endnotes) must be excluded."""
        chapters = self._load()
        sources = [ch.source_path for ch in chapters]
        self.assertFalse(
            any("note1" in s or "note2" in s for s in sources),
            "Endnote container files must not become chapters",
        )

    def test_empty_spine_items_are_excluded(self):
        """cover.xhtml has no prose text -> must not appear as a chapter."""
        chapters = self._load()
        for ch in chapters:
            self.assertTrue(
                ch.text and ch.text.strip(),
                f"Chapter {ch.index!r} ({ch.name!r}) has empty text — should have been dropped",
            )

    def test_exactly_two_toc_chapters_returned(self):
        """Only the 2 TOC-listed chapters (chap1, chap2) should survive."""
        chapters = self._load()
        self.assertEqual(
            len(chapters),
            2,
            f"Expected 2 chapters, got {len(chapters)}: {[c.name for c in chapters]}",
        )

    def test_chapter_names_match_ncx_labels(self):
        """Chapter names must come from NCX navLabel, not from raw text."""
        chapters = self._load()
        names = [ch.name for ch in chapters]
        self.assertIn("Chapter One", names)
        self.assertIn("Chapter Two", names)

    def test_heading_embedded_footnote_appears_after_prose(self):
        """Bug batch 2 / bug 3: footnote ref inside <h1> must not prefix chapter prose.

        chap1.xhtml has <h1>Chapter One<a role="doc-noteref">*</a></h1>.
        The footnote text must NOT appear before the first paragraph;
        the chapter's first line must be the heading ("Chapter One").
        The footnote text must appear only AFTER the main prose.
        """
        chapters = self._load()
        ch1 = next(c for c in chapters if c.name == "Chapter One")
        text = ch1.text or ""

        # First line must be the clean heading, not footnote text
        first_line = text.split("\n")[0]
        self.assertEqual(
            first_line, "Chapter One", f"First line must be chapter title, got: {first_line!r}"
        )

        # The prose must come before the footnote announcement
        prose_marker = "first chapter prose"
        fn_marker = "nota de rodapé"
        prose_pos = text.find(prose_marker)
        fn_pos = text.find(fn_marker)
        self.assertGreater(prose_pos, -1, "Prose text not found in chapter")
        if fn_pos != -1:  # footnote may or may not be rendered
            self.assertLess(
                prose_pos,
                fn_pos,
                "Footnote announcement must come AFTER the prose, not before it",
            )

    def test_nav_link_in_heading_not_collected_as_footnote(self):
        """Bug batch 2 / bug 4: long-text nav anchor must not become a footnote.

        chap1.xhtml heading contains both a navigation <a> (long text = nav link)
        and a real noteref <a role='doc-noteref'>*.  Only the noteref should be
        collected; the nav link must be ignored even if its href fragment looks
        note-like (e.g. href='toc.xhtml#ch1name').
        """
        chapters = self._load()
        ch1 = next(c for c in chapters if c.name == "Chapter One")
        for fn in ch1.footnotes or []:
            fn_text = fn.get("text", "")
            # The nav link's resolved text is "Chapter One" (the chapter title).
            # That must NOT appear as a footnote.
            self.assertNotEqual(
                fn_text.strip().lower(),
                "chapter one",
                "Navigation link with full chapter title must not be collected as a footnote",
            )


class TestCueLocaleFollowsBookLanguage(unittest.TestCase):
    """Regression: English books must get English verbal cues, not pt-BR ones.

    Bug: TextFormattingProcessor.DEFAULT_CUE_LOCALE was 'pt', and
    _prepare_speech_text() created it without passing the book's language.
    Result: 'em itálico' / 'fim do itálico' were injected into English chapters.
    Fix: _extract_chapters derives cue_locale from book_language and propagates it.
    """

    def _make_epub_with_italic(self, lang: str) -> bytes:
        """Build a minimal EPUB with one chapter containing italic text."""
        import io
        import zipfile

        container_xml = b"""<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"""

        opf_lang = lang
        opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">test-cue-locale</dc:identifier>
    <dc:title>Cue Locale Test</dc:title>
    <dc:language>{opf_lang}</dc:language>
  </metadata>
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
  </spine>
</package>""".encode()

        ncx = b"""<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="test-cue-locale"/></head>
  <docTitle><text>Cue Locale Test</text></docTitle>
  <navMap>
    <navPoint id="ch1" playOrder="1">
      <navLabel><text>Chapter One</text></navLabel>
      <content src="chapter1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>"""

        chapter_xhtml = b"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter One</title></head>
  <body>
    <h1>Chapter One</h1>
    <p>This sentence has <em>italic words</em> in it.</p>
    <p>Another paragraph follows.</p>
  </body>
</html>"""

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("mimetype", "application/epub+zip")
            zf.writestr("META-INF/container.xml", container_xml)
            zf.writestr("OEBPS/content.opf", opf)
            zf.writestr("OEBPS/toc.ncx", ncx)
            zf.writestr("OEBPS/chapter1.xhtml", chapter_xhtml)
        buf.seek(0)
        return buf.read()

    def _parse_epub(self, lang: str):
        import os
        import tempfile

        from python_app.src.ebook_reader import EpubParser

        epub_bytes = self._make_epub_with_italic(lang)
        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as f:
            f.write(epub_bytes)
            path = f.name
        try:
            parser = EpubParser(path)
            book = parser.parse()
            return book.chapters
        finally:
            os.unlink(path)

    def test_english_book_no_ptbr_cues(self):
        """English EPUB must not produce em itálico / fim do itálico cues.

        The verbal cues live in speech_text (TTS payload), not ch.text
        (plain-text store).  We check speech_text.
        """
        chapters = self._parse_epub("en")
        self.assertTrue(chapters, "Must parse at least one chapter")
        ch = chapters[0]
        speech = getattr(ch, "speech_text", None) or ch.text or ""
        self.assertNotIn(
            "em itálico",
            speech,
            "English book must not emit pt-BR cue 'em itálico' in speech_text",
        )
        self.assertNotIn(
            "fim do itálico",
            speech,
            "English book must not emit pt-BR cue 'fim do itálico' in speech_text",
        )

    def test_portuguese_book_gets_ptbr_cues(self):
        """pt-BR EPUB must produce pt-BR cues in speech_text (TTS payload)."""
        chapters = self._parse_epub("pt-BR")
        self.assertTrue(chapters, "Must parse at least one chapter")
        ch = chapters[0]
        speech = getattr(ch, "speech_text", None) or ch.text or ""
        self.assertIn(
            "em itálico",
            speech,
            "Portuguese book must emit pt-BR cue 'em itálico' in speech_text",
        )

    def test_english_book_gets_english_cues(self):
        """English EPUB must produce English verbal cues in speech_text."""
        chapters = self._parse_epub("en")
        self.assertTrue(chapters, "Must parse at least one chapter")
        ch = chapters[0]
        speech = getattr(ch, "speech_text", None) or ch.text or ""
        # The italic source word must be present; pt-BR cue must not be.
        self.assertIn(
            "italic words",
            speech,
            "English book: italic source text must be present in speech_text",
        )
        self.assertNotIn(
            "em itálico",
            speech,
            "English book must not have pt-BR cue 'em itálico' in speech_text",
        )

    def _make_epub_with_footnote(self, lang: str) -> bytes:
        """Build a minimal EPUB with one chapter containing a footnote reference."""
        import io
        import zipfile

        container_xml = b"""<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"""

        opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">test-fn-locale</dc:identifier>
    <dc:title>Footnote Locale Test</dc:title>
    <dc:language>{lang}</dc:language>
  </metadata>
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
  </spine>
</package>""".encode()

        ncx = b"""<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="test-fn-locale"/></head>
  <docTitle><text>Footnote Locale Test</text></docTitle>
  <navMap>
    <navPoint id="ch1" playOrder="1">
      <navLabel><text>Chapter One</text></navLabel>
      <content src="chapter1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>"""

        # Chapter with an inline footnote reference (doc-noteref / aside)
        chapter_xhtml = b"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Chapter One</title></head>
  <body>
    <h1>Chapter One</h1>
    <p>The main prose continues here.<a id="fnref1" href="#fn1" role="doc-noteref">*</a></p>
    <p>Second paragraph.</p>
    <aside id="fn1" epub:type="footnote">
      <p>This is the footnote body text.</p>
    </aside>
  </body>
</html>"""

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("mimetype", "application/epub+zip")
            zf.writestr("META-INF/container.xml", container_xml)
            zf.writestr("OEBPS/content.opf", opf)
            zf.writestr("OEBPS/toc.ncx", ncx)
            zf.writestr("OEBPS/chapter1.xhtml", chapter_xhtml)
        buf.seek(0)
        return buf.read()

    def _parse_epub_fn(self, lang: str):
        import os
        import tempfile

        from python_app.src.ebook_reader import EpubParser

        epub_bytes = self._make_epub_with_footnote(lang)
        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as f:
            f.write(epub_bytes)
            path = f.name
        try:
            parser = EpubParser(path)
            book = parser.parse()
            return book.chapters
        finally:
            os.unlink(path)

    def test_english_book_footnote_labels_in_english(self):
        """English EPUB footnote labels must be 'footnote N' / 'end of footnote'.

        Regression: _render_footnotes had pt-BR defaults ('nota de rodapé', 'fim
        da nota de rodapé') hard-coded and no locale was passed from call sites.
        """
        chapters = self._parse_epub_fn("en")
        self.assertTrue(chapters, "Must parse at least one chapter")
        ch = chapters[0]
        speech = getattr(ch, "speech_text", None) or ch.text or ""
        self.assertNotIn(
            "nota de rodapé",
            speech,
            "English EPUB footnote must not contain pt-BR label 'nota de rodapé'",
        )
        self.assertIn(
            "footnote",
            speech,
            "English EPUB footnote must contain English label 'footnote'",
        )

    def test_portuguese_book_footnote_labels_in_portuguese(self):
        """pt-BR EPUB footnote labels must remain 'nota de rodapé' / 'fim da nota de rodapé'."""
        chapters = self._parse_epub_fn("pt-BR")
        self.assertTrue(chapters, "Must parse at least one chapter")
        ch = chapters[0]
        speech = getattr(ch, "speech_text", None) or ch.text or ""
        self.assertIn(
            "nota de rodapé",
            speech,
            "Portuguese EPUB footnote must contain pt-BR label 'nota de rodapé'",
        )
        self.assertNotIn(
            "end of footnote",
            speech,
            "Portuguese EPUB footnote must not use English label 'end of footnote'",
        )


if __name__ == "__main__":
    unittest.main()
