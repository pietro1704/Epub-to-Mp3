# -*- coding: utf-8 -*-
"""
Unit tests for text_integrity_validator module
"""

import tempfile
import unittest
from pathlib import Path

from python_app.src.ebook_reader import Chapter
from python_app.src.text_integrity_validator import TextIntegrityValidator


class TestTextIntegrityValidator(unittest.TestCase):
    """Test cases for TextIntegrityValidator class"""

    def setUp(self):
        """Set up test fixtures"""
        self.temp_dir = tempfile.mkdtemp()
        self.cache_dir = Path(self.temp_dir)
        self.validator = TextIntegrityValidator(cache_dir=self.cache_dir, verbose=False)

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_normalize_text(self):
        """Test text normalization"""
        text = "Hello   world  \n  This   is   a   test"
        normalized = self.validator.normalize_text(text)
        self.assertEqual(normalized, "Hello world This is a test")

    def test_count_words(self):
        """Test word counting"""
        text = "Hello world! This is a test."
        word_count = self.validator.count_words(text)
        self.assertEqual(word_count, 6)

    def test_calculate_text_hash(self):
        """Test text hash calculation"""
        text1 = "Hello world"
        text2 = "Hello world"
        text3 = "Different text"

        hash1 = self.validator.calculate_text_hash(text1)
        hash2 = self.validator.calculate_text_hash(text2)
        hash3 = self.validator.calculate_text_hash(text3)

        self.assertEqual(hash1, hash2)
        self.assertNotEqual(hash1, hash3)

    def test_save_and_load_parsed_text(self):
        """Test saving and loading parsed text"""
        chapter = Chapter(1, "Test Chapter", "test.html", "Hello world test content")
        chapter.speech_text = "Hello world test content"

        # Save text
        saved_path = self.validator.save_parsed_text(chapter, 1)
        self.assertTrue(saved_path.exists())

        # Load text
        loaded_text = self.validator.load_parsed_text(1, "Test Chapter")
        self.assertIsNotNone(loaded_text)
        self.assertEqual(loaded_text, "Hello world test content")

    def test_validate_chapter_text_no_cache(self):
        """Test validation when no cache exists"""
        chapter = Chapter(1, "Test Chapter", "test.html", "Hello world test content")
        chapter.speech_text = "Hello world test content"

        validation = self.validator.validate_chapter_text(chapter, 1)

        self.assertTrue(validation.is_valid)
        self.assertEqual(validation.cached_char_count, 0)
        self.assertIsNone(validation.error_message)

    def test_validate_chapter_text_with_matching_cache(self):
        """Test validation when cache matches EPUB"""
        chapter = Chapter(1, "Test Chapter", "test.html", "Hello world test content")
        chapter.speech_text = "Hello world test content"

        # Save text first
        self.validator.save_parsed_text(chapter, 1)

        # Validate
        validation = self.validator.validate_chapter_text(chapter, 1)

        self.assertTrue(validation.is_valid)
        self.assertEqual(validation.epub_char_count, validation.cached_char_count)

    def test_validate_chapter_text_with_mismatched_cache(self):
        """Test validation when cache doesn't match EPUB"""
        # Create chapter and save it
        chapter = Chapter(1, "Test Chapter", "test.html", "Hello world")
        chapter.speech_text = "Hello world"
        self.validator.save_parsed_text(chapter, 1)

        # Now change the chapter text significantly
        chapter.text = "Completely different text that is much longer than the original"
        chapter.speech_text = "Completely different text that is much longer than the original"

        # Validate
        validation = self.validator.validate_chapter_text(chapter, 1)

        self.assertFalse(validation.is_valid)
        self.assertIsNotNone(validation.error_message)
        self.assertGreater(abs(validation.char_diff), 50)
        self.assertGreater(validation.char_diff_percent, 5.0)

    def test_validate_chapter_text_empty(self):
        """Empty chapter text should be invalid"""
        chapter = Chapter(1, "Empty Chapter", "ch-empty.html", "")
        validation = self.validator.validate_chapter_text(chapter, 1)

        self.assertFalse(validation.is_valid)
        self.assertEqual(
            validation.error_message, "Texto do capítulo vazio ou não extraído do EPUB"
        )

    def test_validate_all_chapters_no_cache(self):
        """Test validating all chapters when no cache exists"""
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2"),
            Chapter(3, "Chapter 3", "ch3.html", "Content 3"),
        ]

        for ch in chapters:
            ch.speech_text = ch.text

        report = self.validator.validate_all_chapters(chapters, show_progress=False)

        self.assertEqual(report.total_chapters, 3)
        self.assertEqual(report.valid_chapters, 3)
        self.assertEqual(report.invalid_chapters, 0)
        self.assertFalse(report.has_cache_corruption)

    def test_validate_all_chapters_with_corruption(self):
        """Test validating all chapters when cache is corrupted"""
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2"),
            Chapter(3, "Chapter 3", "ch3.html", "Content 3"),
        ]

        for ch in chapters:
            ch.speech_text = ch.text

        # Save original texts
        self.validator.save_all_chapters_text(chapters, show_progress=False)

        # Now change one chapter significantly
        chapters[1].text = "Completely different content that is much longer" * 10
        chapters[1].speech_text = chapters[1].text

        # Validate
        report = self.validator.validate_all_chapters(chapters, show_progress=False)

        self.assertEqual(report.total_chapters, 3)
        self.assertEqual(report.invalid_chapters, 1)
        self.assertTrue(report.has_cache_corruption)
        self.assertEqual(len(report.chapters_with_issues), 1)

    def test_validate_all_chapters_with_duplicates(self):
        """Duplicate chapter contents should be flagged"""
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Same text"),
            Chapter(2, "Chapter 2", "ch2.html", "Same text"),
            Chapter(3, "Chapter 3", "ch3.html", "Different text"),
        ]

        for ch in chapters:
            ch.speech_text = ch.text

        report = self.validator.validate_all_chapters(chapters, show_progress=False)

        self.assertTrue(report.has_cache_corruption)
        self.assertGreaterEqual(report.invalid_chapters, 2)
        self.assertTrue(any("Conteúdo duplicado" in err for err in report.errors))

    def test_save_all_chapters_text(self):
        """Test saving text for all chapters"""
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1 with some text"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2 with more text"),
            Chapter(3, "Chapter 3", "ch3.html", "Content 3 with even more text"),
        ]

        for ch in chapters:
            ch.speech_text = ch.text

        saved_files = self.validator.save_all_chapters_text(chapters, show_progress=False)

        self.assertEqual(len(saved_files), 3)
        for idx, path in saved_files.items():
            self.assertTrue(path.exists())
            self.assertGreater(path.stat().st_size, 0)

    def test_detect_engine_mismatch(self):
        """Test detection of engine mismatch"""
        # No engine directories exist
        self.assertFalse(self.validator._detect_engine_mismatch())

        # Create an engine directory
        (self.cache_dir / "kokoro").mkdir(parents=True, exist_ok=True)
        self.assertTrue(self.validator._detect_engine_mismatch())


if __name__ == "__main__":
    unittest.main()
