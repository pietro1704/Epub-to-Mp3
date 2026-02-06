# -*- coding: utf-8 -*-
"""Tests for deep validation system with autofix capabilities."""

import os
import sys
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional
from unittest.mock import Mock, patch

# Add parent directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.deep_validator import (
    ChapterComparison,
    DeepValidator,
    ValidationReport,
    run_deep_validation,
)


@dataclass
class _FakeChapter:
    """Minimal Chapter stand-in for tests."""

    index: int
    name: str
    text: str
    source_path: str = ""
    level: int = 1
    raw_html: Optional[str] = None
    formatting_segments: Optional[list] = None
    speech_text: Optional[str] = None
    footnotes: Optional[list] = None


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


def _make_fake_reader(chapters: List[_FakeChapter]):
    """Return a mock EbookReader whose get_chapters() returns *chapters*."""
    reader = Mock()
    reader.get_chapters.return_value = chapters
    return reader


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

    def test_extract_chapter_index(self):
        """Test extracting chapter index from parsed filenames."""
        self.assertEqual(DeepValidator._extract_chapter_index("1 - Chapter One-parsed.txt"), "1")
        self.assertEqual(DeepValidator._extract_chapter_index("5.4 - Part Five-parsed.txt"), "5.4")
        self.assertEqual(DeepValidator._extract_chapter_index("12 - Epilogue-parsed.txt"), "12")
        self.assertIsNone(DeepValidator._extract_chapter_index("no-number-parsed.txt"))

    def test_compare_chapter_content_fingerprint_match(self):
        """Test that compare_chapter matches by content fingerprint."""
        content = "This is the full text of chapter one with enough words to pass validation " * 5

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            # Key by content fingerprint (same as what compare_chapter computes)
            fp = DeepValidator._content_fingerprint(content)
            validator.epub_chapters = {fp: content}

            # Write parsed file with matching content
            parsed_file = self.text_dir / "1 - Chapter One-parsed.txt"
            parsed_file.write_text(content, encoding="utf-8")

            comp = validator.compare_chapter(parsed_file)
            self.assertIsNotNone(comp)
            self.assertTrue(comp.is_valid)
            self.assertTrue(comp.start_match)
            self.assertTrue(comp.end_match)

    def test_compare_chapter_decimal_label_match(self):
        """Test that compare_chapter works regardless of filename label format."""
        content = "This is chapter five point four with enough text to pass the validation " * 5

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            fp = DeepValidator._content_fingerprint(content)
            validator.epub_chapters = {fp: content}

            parsed_file = self.text_dir / "5.4 - Part Five Section Four-parsed.txt"
            parsed_file.write_text(content, encoding="utf-8")

            comp = validator.compare_chapter(parsed_file)
            self.assertIsNotNone(comp)
            self.assertTrue(comp.is_valid)

    def test_compare_chapter_no_match(self):
        """Test compare_chapter when no matching content exists."""
        content = "Some chapter content that is long enough to be detected as a real chapter " * 20

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            other = "Completely different chapter with different words and different meaning " * 20
            fp = DeepValidator._content_fingerprint(other)
            validator.epub_chapters = {fp: other}

            parsed_file = self.text_dir / "99 - Missing Chapter-parsed.txt"
            parsed_file.write_text(content, encoding="utf-8")

            comp = validator.compare_chapter(parsed_file)
            self.assertIsNotNone(comp)
            self.assertFalse(comp.is_valid)


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

    @patch("src.deep_validator.DeepValidator.load_epub_chapters")
    def test_validate_success_no_issues(self, mock_load):
        """Test successful validation with no issues."""
        content = "Test chapter content that is long enough " * 10
        mock_load.side_effect = lambda: True

        # Create matching parsed file
        parsed_file = self.text_dir / "1 - chapter1-parsed.txt"
        parsed_file.write_text(content, encoding="utf-8")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir), tolerance_pct=10.0)
            fp = DeepValidator._content_fingerprint(content)
            validator.epub_chapters = {fp: content}

            report = validator.validate(auto_correct=False)

            self.assertTrue(report.success)
            self.assertEqual(report.valid_chapters, 1)
            self.assertEqual(report.duplicates_found, 0)

    @patch("src.deep_validator.DeepValidator.load_epub_chapters")
    def test_validate_with_autofix(self, mock_load):
        """Test validation with automatic correction of duplicates."""
        content = "Test chapter content that is long enough " * 10
        mock_load.return_value = True

        # Create duplicate files
        file1 = self.text_dir / "1 - chapter1-parsed.txt"
        file2 = self.text_dir / "1 - chapter1 - duplicate-parsed.txt"
        file1.write_text(content, encoding="utf-8")
        file2.write_text(content, encoding="utf-8")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            fp = DeepValidator._content_fingerprint(content)
            validator.epub_chapters = {fp: content}
            report = validator.validate(auto_correct=True)

            # After correction, no duplicates should remain in the report
            self.assertEqual(report.duplicates_found, 0)
            self.assertGreaterEqual(report.total_chapters, 0)

    @patch("src.deep_validator.DeepValidator.load_epub_chapters")
    def test_run_deep_validation_returns_report(self, mock_load):
        """Test that run_deep_validation returns a ValidationReport."""
        content = "Test content that is long enough for validation " * 10
        mock_load.return_value = True

        parsed_file = self.text_dir / "1 - chapter1-parsed.txt"
        parsed_file.write_text(content, encoding="utf-8")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            # We need to also set epub_chapters on the validator inside run_deep_validation
            # Since run_deep_validation creates its own validator, we patch load_epub_chapters
            # to set epub_chapters as a side effect
            def load_side_effect():
                return True

            mock_load.side_effect = load_side_effect

            report = run_deep_validation(epub_file.name, str(self.cache_dir), auto_correct=True)

            self.assertIsInstance(report, ValidationReport)

    @patch("src.deep_validator.DeepValidator.load_epub_chapters")
    def test_100_percent_success_required(self, mock_load):
        """Test that 100% of chapters must be valid for success."""
        good_content = (
            "This is valid chapter content with enough text to exceed the minimum threshold " * 20
        )
        bad_content = (
            "Completely different chapter text that does not match any fingerprint in the validator "
            * 20
        )
        mock_load.return_value = True

        # Create two parsed files with different content
        (self.text_dir / "1 - chapter1-parsed.txt").write_text(good_content, encoding="utf-8")
        (self.text_dir / "2 - chapter2-parsed.txt").write_text(bad_content, encoding="utf-8")

        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as epub_file:
            validator = DeepValidator(epub_file.name, str(self.cache_dir))
            # Only provide fingerprint for chapter 1 — chapter 2 will fail
            fp = DeepValidator._content_fingerprint(good_content)
            validator.epub_chapters = {fp: good_content}

            report = validator.validate(auto_correct=False)

            # Chapter 2 has no match → not valid → success should be False
            self.assertFalse(report.success)
            self.assertEqual(report.valid_chapters, 1)
            self.assertEqual(report.total_chapters, 2)


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
