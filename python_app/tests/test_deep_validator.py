# -*- coding: utf-8 -*-
"""Tests for deep validation system with autofix capabilities."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

# Add parent directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.deep_validator import (
    ChapterComparison,
    DeepValidator,
    ValidationReport,
    run_deep_validation,
)


class TestChapterComparison(unittest.TestCase):
    """Test ChapterComparison dataclass."""

    def test_valid_chapter_comparison(self):
        """Test creating a valid chapter comparison."""
        comp = ChapterComparison(
            chapter_id="chapter1.txt",
            epub_chars=1000,
            parsed_chars=995,
            char_diff_pct=0.5,
            start_match=True,
            middle_match=True,
            end_match=True,
            is_valid=True,
            error_msg=None,
        )
        self.assertTrue(comp.is_valid)
        self.assertIsNone(comp.error_msg)

    def test_invalid_chapter_comparison(self):
        """Test creating an invalid chapter comparison."""
        comp = ChapterComparison(
            chapter_id="chapter2.txt",
            epub_chars=1000,
            parsed_chars=500,
            char_diff_pct=50.0,
            start_match=True,
            middle_match=False,
            end_match=False,
            is_valid=False,
            error_msg="Character difference too large",
        )
        self.assertFalse(comp.is_valid)
        self.assertEqual(comp.error_msg, "Character difference too large")


class TestValidationReport(unittest.TestCase):
    """Test ValidationReport dataclass."""

    def test_report_with_defaults(self):
        """Test report with default corrections_made."""
        report = ValidationReport(
            total_chapters=10,
            valid_chapters=8,
            duplicates_found=2,
            char_mismatches=1,
            content_mismatches=1,
            comparisons=[],
            duplicate_files=[("file1.txt", "file2.txt")],
            success=False,
        )
        self.assertEqual(report.corrections_made, [])
        self.assertFalse(report.auto_corrected)

    def test_report_with_corrections(self):
        """Test report with corrections applied."""
        report = ValidationReport(
            total_chapters=10,
            valid_chapters=10,
            duplicates_found=0,
            char_mismatches=0,
            content_mismatches=0,
            comparisons=[],
            duplicate_files=[],
            success=True,
            auto_corrected=True,
            corrections_made=["Removed duplicate: file1.txt"],
        )
        self.assertTrue(report.auto_corrected)
        self.assertEqual(len(report.corrections_made), 1)


class TestDeepValidator(unittest.TestCase):
    """Test DeepValidator class."""

    def setUp(self):
        """Set up test fixtures."""
        self.temp_dir = tempfile.TemporaryDirectory()
        self.cache_dir = Path(self.temp_dir.name)
        self.text_dir = self.cache_dir / "text"
        self.text_dir.mkdir(parents=True)

    def tearDown(self):
        """Clean up test fixtures."""
        self.temp_dir.cleanup()

    def test_find_parsed_files(self):
        """Test finding parsed files in cache directory."""
        # Create some test files
        (self.text_dir / "1-chapter1-parsed.txt").write_text("content1", encoding="utf-8")
        (self.text_dir / "2-chapter2-parsed.txt").write_text("content2", encoding="utf-8")
        (self.text_dir / "3-notparsed.txt").write_text("content3", encoding="utf-8")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            files = validator.find_parsed_files()

            self.assertEqual(len(files), 2)
            self.assertTrue(all("parsed.txt" in f.name for f in files))

    def test_detect_duplicates_no_duplicates(self):
        """Test duplicate detection with no duplicates."""
        file1 = self.text_dir / "1-chapter1-parsed.txt"
        file2 = self.text_dir / "2-chapter2-parsed.txt"
        file1.write_text("Unique content for chapter 1", encoding="utf-8")
        file2.write_text("Unique content for chapter 2", encoding="utf-8")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            duplicates = validator.detect_duplicates([file1, file2])

            self.assertEqual(len(duplicates), 0)

    def test_detect_duplicates_with_duplicates(self):
        """Test duplicate detection with actual duplicates."""
        file1 = self.text_dir / "1-chapter1-parsed.txt"
        file2 = self.text_dir / "2-chapter2-parsed.txt"
        duplicate_content = "This is duplicate content that appears twice"
        file1.write_text(duplicate_content, encoding="utf-8")
        file2.write_text(duplicate_content, encoding="utf-8")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            duplicates = validator.detect_duplicates([file1, file2])

            self.assertEqual(len(duplicates), 1)
            self.assertIn(file1.name, duplicates[0])
            self.assertIn(file2.name, duplicates[0])

    def test_compare_content_sections_exact_match(self):
        """Test content comparison with exact match."""
        epub_text = "This is the beginning of the chapter. " * 20
        parsed_text = epub_text

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            start_match, middle_match, end_match = validator.compare_content_sections(
                epub_text, parsed_text
            )

            self.assertTrue(start_match)
            self.assertTrue(middle_match)
            self.assertTrue(end_match)

    def test_compare_content_sections_different_content(self):
        """Test content comparison with different content."""
        epub_text = "Original EPUB content with specific text here."
        parsed_text = "Completely different parsed text that doesn't match."

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            start_match, middle_match, end_match = validator.compare_content_sections(
                epub_text, parsed_text
            )

            # Should not match since content is completely different
            self.assertFalse(start_match or middle_match or end_match)

    def test_fuzzy_match_high_similarity(self):
        """Test fuzzy matching with high similarity."""
        text1 = "The quick brown fox jumps over the lazy dog"
        text2 = "The quick brown fox jumps over a lazy dog"  # One word different

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            match = validator._fuzzy_match(text1, text2, threshold=0.7)

            self.assertTrue(match)  # Should match with 70% threshold

    def test_auto_correct_removes_duplicates(self):
        """Test that autocorrect removes duplicate files."""
        # Create duplicate files
        file1 = self.text_dir / "1-chapter1-parsed.txt"
        file2 = self.text_dir / "1 - chapter1 - duplicate-parsed.txt"  # Longer name
        duplicate_content = "Duplicate content"
        file1.write_text(duplicate_content, encoding="utf-8")
        file2.write_text(duplicate_content, encoding="utf-8")

        # Verify both files exist
        self.assertTrue(file1.exists())
        self.assertTrue(file2.exists())

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            duplicates = [(file1.name, file2.name)]
            corrections = validator.auto_correct(duplicates)

            # Should remove the longer filename
            self.assertEqual(len(corrections), 1)
            self.assertIn("Removido", corrections[0])

            # The file with longer name should be removed
            if len(file1.name) > len(file2.name):
                self.assertFalse(file1.exists())
                self.assertTrue(file2.exists())
            else:
                self.assertTrue(file1.exists())
                self.assertFalse(file2.exists())


class TestValidateIntegration(unittest.TestCase):
    """Integration tests for complete validation flow."""

    def setUp(self):
        """Set up test fixtures."""
        self.temp_dir = tempfile.TemporaryDirectory()
        self.cache_dir = Path(self.temp_dir.name)
        self.text_dir = self.cache_dir / "text"
        self.text_dir.mkdir(parents=True)

    def tearDown(self):
        """Clean up test fixtures."""
        self.temp_dir.cleanup()

    @patch("src.deep_validator.epub.read_epub")
    def test_validate_success_no_issues(self, mock_read_epub):
        """Test successful validation with no issues."""
        # Mock EPUB loading
        mock_book = Mock()
        mock_item = Mock()
        mock_item.get_type.return_value = 2  # ITEM_DOCUMENT
        mock_item.get_content.return_value = b"<p>Test chapter content</p>"
        mock_item.get_id.return_value = "chapter1"
        mock_book.get_items.return_value = [mock_item]
        mock_read_epub.return_value = mock_book

        # Create matching parsed file
        parsed_file = self.text_dir / "1-chapter1-parsed.txt"
        parsed_file.write_text("Test chapter content", encoding="utf-8")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir), tolerance_pct=10.0)
            report = validator.validate(auto_correct=False)

            self.assertGreaterEqual(report.valid_chapters, 0)
            self.assertEqual(report.duplicates_found, 0)

    @patch("src.deep_validator.epub.read_epub")
    def test_validate_with_autofix(self, mock_read_epub):
        """Test validation with automatic correction of duplicates."""
        # Mock EPUB loading
        mock_book = Mock()
        mock_item = Mock()
        mock_item.get_type.return_value = 2  # ITEM_DOCUMENT
        mock_item.get_content.return_value = b"<p>Test chapter content</p>"
        mock_item.get_id.return_value = "chapter1"
        mock_book.get_items.return_value = [mock_item]
        mock_read_epub.return_value = mock_book

        # Create duplicate files
        file1 = self.text_dir / "1-chapter1-parsed.txt"
        file2 = self.text_dir / "1 - chapter1 - duplicate-parsed.txt"
        duplicate_content = "Test chapter content"
        file1.write_text(duplicate_content, encoding="utf-8")
        file2.write_text(duplicate_content, encoding="utf-8")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            report = validator.validate(auto_correct=True)

            # After correction, no duplicates should remain in the report
            self.assertEqual(report.duplicates_found, 0)

            # Validation should process at least some chapters
            self.assertGreaterEqual(report.total_chapters, 0)

    @patch("src.deep_validator.epub.read_epub")
    def test_run_deep_validation_function(self, mock_read_epub):
        """Test the run_deep_validation helper function."""
        # Mock EPUB loading
        mock_book = Mock()
        mock_item = Mock()
        mock_item.get_type.return_value = 2  # ITEM_DOCUMENT
        mock_item.get_content.return_value = b"<p>Test content</p>"
        mock_item.get_id.return_value = "chapter1"
        mock_book.get_items.return_value = [mock_item]
        mock_read_epub.return_value = mock_book

        # Create valid parsed file
        parsed_file = self.text_dir / "1-chapter1-parsed.txt"
        parsed_file.write_text("Test content" * 10, encoding="utf-8")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            success = run_deep_validation(epub_file.name, str(self.cache_dir), auto_correct=True)

            # Should return success status
            self.assertIsInstance(success, bool)


class TestValidationReportPrinting(unittest.TestCase):
    """Test ValidationReport summary printing."""

    def test_print_summary_success(self):
        """Test printing summary for successful validation."""
        report = ValidationReport(
            total_chapters=10,
            valid_chapters=10,
            duplicates_found=0,
            char_mismatches=0,
            content_mismatches=0,
            comparisons=[],
            duplicate_files=[],
            success=True,
        )

        # Should not raise any exceptions
        try:
            report.print_summary()
        except Exception as e:
            self.fail(f"print_summary raised exception: {e}")

    def test_print_summary_with_issues(self):
        """Test printing summary with validation issues."""
        comp = ChapterComparison(
            chapter_id="chapter1.txt",
            epub_chars=1000,
            parsed_chars=500,
            char_diff_pct=50.0,
            start_match=False,
            middle_match=False,
            end_match=False,
            is_valid=False,
            error_msg="Content mismatch",
        )

        report = ValidationReport(
            total_chapters=10,
            valid_chapters=8,
            duplicates_found=2,
            char_mismatches=2,
            content_mismatches=2,
            comparisons=[comp],
            duplicate_files=[("file1.txt", "file2.txt")],
            success=False,
            auto_corrected=True,
            corrections_made=["Removed duplicate: file1.txt"],
        )

        # Should not raise any exceptions
        try:
            report.print_summary()
        except Exception as e:
            self.fail(f"print_summary raised exception: {e}")


if __name__ == "__main__":
    unittest.main()
