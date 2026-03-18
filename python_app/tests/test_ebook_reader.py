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

from src.ebook_reader import Book, Chapter, EbookReader, EpubParser, PdfParser


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
            mock_load.assert_called_once_with("test.epub")

    def test_init_with_path_object(self):
        """Test EbookReader initialization with Path object"""
        path_obj = Path("test.epub")
        with patch.object(EbookReader, "load") as mock_load:
            reader = EbookReader(path_obj)
            self.assertEqual(reader.file_path, path_obj)
            mock_load.assert_called_once_with(path_obj)

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

            mock_epub_init.assert_called_once_with(self.sample_epub_path)

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
        """A number element not followed by a title element within 500 chars is ignored."""
        html = (
            '<p class="class_s42-0">2</p>'
            # 600 chars of noise before any title — outside the 500-char window
            + '<p class="noise">'
            + "x" * 600
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
        for i, (idx, title, _) in enumerate(result, start=1):
            self.assertEqual(idx, f"11.{i}")
            self.assertEqual(title, f"Section {i}")

    def test_paragraph_split_oversized_chapter(self):
        """Chapters exceeding SUBCHAPTER_MAX_CHARS are split at line boundaries."""
        # EPUB plain text uses single \n between paragraphs.
        para = "Word " * 200  # ~1 000 chars each
        text = "\n".join([para] * 60)  # ~60 000 chars total

        result = EpubParser._split_text_at_paragraph_boundaries(text, 50_000, 7)

        self.assertGreater(len(result), 1)
        for idx, chunk in result:
            self.assertTrue(idx.startswith("7."), f"Expected decimal index, got {idx!r}")
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


if __name__ == "__main__":
    unittest.main()
