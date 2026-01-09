# -*- coding: utf-8 -*-
"""
Unit tests for EbookReader class
"""

import os
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
