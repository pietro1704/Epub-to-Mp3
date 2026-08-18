# -*- coding: utf-8 -*-
"""
Unit tests for PdfParser class
"""

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from src.ebook_reader import Book, PdfParser


class TestPdfParser(unittest.TestCase):
    """Test cases for PdfParser class"""

    def setUp(self):
        """Set up test fixtures"""
        self.temp_dir = tempfile.mkdtemp()
        self.sample_pdf_path = os.path.join(self.temp_dir, "test.pdf")

        # Create a dummy PDF file (just for file existence)
        with open(self.sample_pdf_path, "wb") as f:
            f.write(b"dummy pdf content")

    def tearDown(self):
        """Clean up test fixtures"""
        if os.path.exists(self.sample_pdf_path):
            os.remove(self.sample_pdf_path)
        os.rmdir(self.temp_dir)

    def test_init(self):
        """Test PdfParser initialization"""
        parser = PdfParser("test.pdf")
        self.assertEqual(parser.file_path, "test.pdf")

    @patch("src.ebook_reader.PDF_AVAILABLE", False)
    def test_parse_pdf_not_available(self):
        """Test parsing when PDF library is not available"""
        parser = PdfParser(self.sample_pdf_path)

        with self.assertRaises(ImportError) as context:
            parser.parse()

        self.assertIn("pypdf library not installed", str(context.exception))

    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_simple_pdf(self, mock_pypdf):
        """Test parsing a simple PDF file"""
        # Mock PDF reader and pages
        mock_page1 = Mock()
        mock_page1.extract_text.return_value = "Content of page 1."

        mock_page2 = Mock()
        mock_page2.extract_text.return_value = "Content of page 2."

        mock_reader = Mock()
        mock_reader.pages = [mock_page1, mock_page2]
        mock_reader.metadata = {"/Title": "Test PDF Book", "/Author": "Test PDF Author"}

        mock_pypdf.PdfReader.return_value = mock_reader

        parser = PdfParser(self.sample_pdf_path)
        book = parser.parse()

        self.assertIsInstance(book, Book)
        self.assertEqual(book.title, "Test PDF Book")
        self.assertEqual(book.author, "Test PDF Author")
        self.assertEqual(len(book.chapters), 2)

        # Check first page/chapter
        chapter1 = book.chapters[0]
        self.assertEqual(chapter1.index, 1)
        self.assertEqual(chapter1.name, "Página 1")
        self.assertEqual(chapter1.text, "Content of page 1.")
        self.assertEqual(chapter1.source_path, "page_1")
        self.assertEqual(chapter1.speech_text, "Página 1.\nContent of page 1.")

        # Check second page/chapter
        chapter2 = book.chapters[1]
        self.assertEqual(chapter2.index, 2)
        self.assertEqual(chapter2.name, "Página 2")
        self.assertEqual(chapter2.text, "Content of page 2.")
        self.assertEqual(chapter2.source_path, "page_2")

    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_pdf_no_metadata(self, mock_pypdf):
        """Test parsing PDF with no metadata"""
        mock_page = Mock()
        mock_page.extract_text.return_value = "Some content."

        mock_reader = Mock()
        mock_reader.pages = [mock_page]
        mock_reader.metadata = None

        mock_pypdf.PdfReader.return_value = mock_reader

        parser = PdfParser(self.sample_pdf_path)
        book = parser.parse()

        # Should use filename as title
        self.assertEqual(book.title, "test")
        self.assertEqual(book.author, "")

    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_pdf_empty_metadata(self, mock_pypdf):
        """Test parsing PDF with empty metadata"""
        mock_page = Mock()
        mock_page.extract_text.return_value = "Some content."

        mock_reader = Mock()
        mock_reader.pages = [mock_page]
        mock_reader.metadata = {}

        mock_pypdf.PdfReader.return_value = mock_reader

        parser = PdfParser(self.sample_pdf_path)
        book = parser.parse()

        # Should use filename as title when metadata is empty
        self.assertEqual(book.title, "test")
        self.assertEqual(book.author, "")

    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_pdf_partial_metadata(self, mock_pypdf):
        """Test parsing PDF with partial metadata"""
        mock_page = Mock()
        mock_page.extract_text.return_value = "Some content."

        mock_reader = Mock()
        mock_reader.pages = [mock_page]
        mock_reader.metadata = {"/Author": "Only Author"}

        mock_pypdf.PdfReader.return_value = mock_reader

        parser = PdfParser(self.sample_pdf_path)
        book = parser.parse()

        # Should use filename for missing title
        self.assertEqual(book.title, "test")
        self.assertEqual(book.author, "Only Author")

    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_pdf_empty_pages(self, mock_pypdf):
        """Test parsing PDF with empty pages"""
        mock_page1 = Mock()
        mock_page1.extract_text.return_value = "Content here."

        mock_page2 = Mock()
        mock_page2.extract_text.return_value = ""  # Empty page

        mock_page3 = Mock()
        mock_page3.extract_text.return_value = "   "  # Only whitespace

        mock_page4 = Mock()
        mock_page4.extract_text.return_value = "More content."

        mock_reader = Mock()
        mock_reader.pages = [mock_page1, mock_page2, mock_page3, mock_page4]
        mock_reader.metadata = {"Title": "Test"}

        mock_pypdf.PdfReader.return_value = mock_reader

        parser = PdfParser(self.sample_pdf_path)
        book = parser.parse()

        # Should only include pages with content
        self.assertEqual(len(book.chapters), 2)
        self.assertEqual(book.chapters[0].text, "Content here.")
        self.assertEqual(book.chapters[1].text, "More content.")

        # Check page numbering is preserved
        self.assertEqual(book.chapters[0].index, 1)
        self.assertEqual(book.chapters[1].index, 4)

    @patch("src.ebook_reader.CacheManager")
    @patch("src.ebook_reader.PdfScanOcr")
    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_scanned_two_up_pdf_uses_ocr_in_reading_order(
        self, mock_pypdf, mock_ocr_type, mock_cache_manager_type
    ):
        """Scanned spreads should become ordered, independently playable pages."""
        mock_page = Mock()
        mock_page.extract_text.return_value = ""
        mock_reader = Mock()
        mock_reader.pages = [mock_page]
        mock_reader.metadata = {"Title": "Scanned Book"}
        mock_pypdf.PdfReader.return_value = mock_reader

        mock_ocr = mock_ocr_type.return_value
        mock_ocr.extract.return_value = [
            Mock(source_page_index=1, part_index=1, text="First scanned page."),
            Mock(source_page_index=1, part_index=2, text="Second scanned page."),
        ]

        book = PdfParser(self.sample_pdf_path).parse()

        mock_ocr.extract.assert_called_once_with(Path(self.sample_pdf_path), [1])
        self.assertEqual(book.source_format, "pdf_scan_ocr")
        self.assertEqual([chapter.index for chapter in book.chapters], ["1.1", "1.2"])
        self.assertEqual([chapter.name for chapter in book.chapters], ["Página 1.1", "Página 1.2"])
        self.assertEqual(
            [chapter.source_path for chapter in book.chapters],
            ["page_1_part_1", "page_1_part_2"],
        )
        self.assertEqual(
            [chapter.text for chapter in book.chapters],
            ["First scanned page.", "Second scanned page."],
        )
        mock_cache_manager_type.return_value.save_chapters_to_cache.assert_called_once()

    @patch("src.ebook_reader.CacheManager")
    @patch("src.ebook_reader.PdfScanOcr")
    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_pdf_uses_ocr_when_all_text_extractions_raise(
        self, mock_pypdf, mock_ocr_type, mock_cache_manager_type
    ):
        """Parser extraction failures must still receive the scan fallback."""
        mock_page = Mock()
        mock_page.extract_text.side_effect = RuntimeError("Broken text layer")
        mock_reader = Mock()
        mock_reader.pages = [mock_page]
        mock_reader.metadata = {"Title": "Damaged Scan"}
        mock_pypdf.PdfReader.return_value = mock_reader
        mock_ocr_type.return_value.extract.return_value = [
            Mock(source_page_index=1, part_index=1, text="Recovered after parser failure."),
        ]

        book = PdfParser(self.sample_pdf_path).parse()

        mock_ocr_type.return_value.extract.assert_called_once_with(Path(self.sample_pdf_path), [1])
        self.assertEqual(book.source_format, "pdf_scan_ocr")
        self.assertEqual(
            [chapter.text for chapter in book.chapters], ["Recovered after parser failure."]
        )
        self.assertEqual([chapter.name for chapter in book.chapters], ["Página 1.1"])
        mock_cache_manager_type.return_value.save_chapters_to_cache.assert_called_once()

    @patch("src.ebook_reader.PdfScanOcr")
    @patch("src.ebook_reader.CacheManager")
    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_scanned_pdf_reuses_valid_ocr_cache(
        self, mock_pypdf, mock_cache_manager_type, mock_ocr_type
    ):
        """A repeated scan must reuse the complete OCR cache without Vision."""
        mock_page = Mock()
        mock_page.extract_text.return_value = ""
        mock_reader = Mock()
        mock_reader.pages = [mock_page]
        mock_reader.metadata = {"Title": "Scanned Book"}
        mock_pypdf.PdfReader.return_value = mock_reader
        mock_cache_manager_type.return_value.get_cached_chapters.return_value = {
            "title": "Scanned Book",
            "author": "",
            "source_format": "pdf_scan_ocr",
            "chapters": [
                {
                    "index": "1.1",
                    "title": "Página 1.1",
                    "source_path": "page_1_part_1",
                    "text": "Recovered text.",
                    "speech_text": "Recovered text.",
                }
            ],
        }

        book = PdfParser(self.sample_pdf_path).parse()

        mock_ocr_type.return_value.extract.assert_not_called()
        self.assertEqual(book.title, "Scanned Book")
        self.assertEqual(book.source_format, "pdf_scan_ocr")
        self.assertEqual(book.chapters[0].index, "1.1")
        self.assertEqual(book.chapters[0].text, "Recovered text.")

    @patch("src.ebook_reader.PdfScanOcr")
    @patch("src.ebook_reader.CacheManager")
    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_scanned_pdf_legacy_cache_drops_display_labels(
        self, mock_pypdf, mock_cache_manager_type, mock_ocr_type
    ):
        """Legacy structure caches must not reuse display text as chapter names."""
        mock_page = Mock()
        mock_page.extract_text.return_value = ""
        mock_reader = Mock()
        mock_reader.pages = [mock_page]
        mock_reader.metadata = {"Title": "Scanned Book"}
        mock_pypdf.PdfReader.return_value = mock_reader
        mock_cache_manager_type.return_value.get_cached_chapters.return_value = {
            "title": "Scanned Book",
            "author": "",
            "source_format": "pdf_scan_ocr",
            "chapters": [{"title": "1.0 - Page preview", "text": "Recovered text."}],
        }

        book = PdfParser(self.sample_pdf_path).parse()

        mock_ocr_type.return_value.extract.assert_not_called()
        self.assertEqual(book.chapters[0].index, 1)
        self.assertEqual(book.chapters[0].name, "Página 1")
        self.assertEqual(book.chapters[0].text, "Recovered text.")

    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_pdf_extraction_errors(self, mock_pypdf):
        """Test parsing PDF with text extraction errors"""
        mock_page1 = Mock()
        mock_page1.extract_text.return_value = "Good content."

        mock_page2 = Mock()
        mock_page2.extract_text.side_effect = Exception("Extraction failed")

        mock_page3 = Mock()
        mock_page3.extract_text.return_value = "More good content."

        mock_reader = Mock()
        mock_reader.pages = [mock_page1, mock_page2, mock_page3]
        mock_reader.metadata = {"Title": "Test"}

        mock_pypdf.PdfReader.return_value = mock_reader

        parser = PdfParser(self.sample_pdf_path)
        book = parser.parse()

        self.assertEqual(len(book.chapters), 3)

        # First page should work normally
        self.assertEqual(book.chapters[0].text, "Good content.")
        self.assertEqual(book.chapters[0].name, "Página 1")

        # Second page should have error message
        self.assertEqual(book.chapters[1].text, "")
        self.assertEqual(book.chapters[1].name, "Página 2 (erro)")
        self.assertEqual(book.chapters[1].index, 2)

        # Third page should work normally
        self.assertEqual(book.chapters[2].text, "More good content.")
        self.assertEqual(book.chapters[2].name, "Página 3")

    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_pdf_no_pages(self, mock_pypdf):
        """Test parsing PDF with no pages"""
        mock_reader = Mock()
        mock_reader.pages = []
        mock_reader.metadata = {"/Title": "Empty PDF"}

        mock_pypdf.PdfReader.return_value = mock_reader

        parser = PdfParser(self.sample_pdf_path)
        book = parser.parse()

        self.assertEqual(book.title, "Empty PDF")
        self.assertEqual(len(book.chapters), 0)

    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_pdf_whitespace_text(self, mock_pypdf):
        """Test parsing PDF where pages only have whitespace"""
        mock_page1 = Mock()
        mock_page1.extract_text.return_value = "\n\n   \t  \r\n"

        mock_page2 = Mock()
        mock_page2.extract_text.return_value = "Real content here."

        mock_reader = Mock()
        mock_reader.pages = [mock_page1, mock_page2]
        mock_reader.metadata = {}

        mock_pypdf.PdfReader.return_value = mock_reader

        parser = PdfParser(self.sample_pdf_path)
        book = parser.parse()

        # Should skip whitespace-only pages
        self.assertEqual(len(book.chapters), 1)
        self.assertEqual(book.chapters[0].text, "Real content here.")
        self.assertEqual(book.chapters[0].index, 2)  # Should keep original page number

    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("src.ebook_reader.pypdf")
    def test_parse_pdf_text_stripping(self, mock_pypdf):
        """Test that PDF text content is properly stripped"""
        mock_page = Mock()
        mock_page.extract_text.return_value = "  \n\n  Content with spaces  \n\n  "

        mock_reader = Mock()
        mock_reader.pages = [mock_page]
        mock_reader.metadata = {}

        mock_pypdf.PdfReader.return_value = mock_reader

        parser = PdfParser(self.sample_pdf_path)
        book = parser.parse()

        self.assertEqual(len(book.chapters), 1)
        self.assertEqual(book.chapters[0].text, "Content with spaces")

    @patch("src.ebook_reader.PDF_AVAILABLE", True)
    @patch("builtins.open")
    @patch("src.ebook_reader.pypdf")
    def test_parse_pdf_file_operations(self, mock_pypdf, mock_open_func):
        """Test that PDF file is opened in binary mode"""
        mock_page = Mock()
        mock_page.extract_text.return_value = "Test content"

        mock_reader = Mock()
        mock_reader.pages = [mock_page]
        mock_reader.metadata = {}

        mock_pypdf.PdfReader.return_value = mock_reader

        parser = PdfParser(self.sample_pdf_path)
        book = parser.parse()

        # Verify file was opened in binary mode
        mock_open_func.assert_called_once_with(self.sample_pdf_path, "rb")


if __name__ == "__main__":
    unittest.main()
