# -*- coding: utf-8 -*-
"""
Unit tests for PdfParser class
"""

import os
import tempfile
import unittest
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
