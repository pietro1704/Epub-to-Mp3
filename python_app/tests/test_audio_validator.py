# -*- coding: utf-8 -*-
"""
Unit tests for audio_validator module
"""

import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from python_app.src.audio_validator import AudioValidator, ValidationResult


class TestAudioValidator(unittest.TestCase):
    """Test cases for AudioValidator class"""

    def setUp(self):
        """Set up test fixtures"""
        self.validator = AudioValidator(words_per_minute=150)

    def test_initialization(self):
        """Test AudioValidator initialization"""
        self.assertEqual(self.validator.words_per_minute, 150)

    def test_initialization_custom_wpm(self):
        """Test AudioValidator with custom WPM"""
        validator = AudioValidator(words_per_minute=200)
        self.assertEqual(validator.words_per_minute, 200)

    def test_estimate_duration_simple_text(self):
        """Test duration estimation for simple text"""
        # 150 words at 150 WPM = 1 minute = 60 seconds
        text = " ".join(["word"] * 150)
        duration = self.validator.estimate_duration(text)

        self.assertAlmostEqual(duration, 60.0, delta=0.1)

    def test_estimate_duration_empty_text(self):
        """Test duration estimation for empty text"""
        duration = self.validator.estimate_duration("")
        self.assertEqual(duration, 0.0)

    def test_estimate_duration_single_word(self):
        """Test duration estimation for single word"""
        duration = self.validator.estimate_duration("Hello")
        # 1 word at 150 WPM = 1/150 * 60 = 0.4 seconds
        self.assertAlmostEqual(duration, 0.4, delta=0.1)

    def test_estimate_duration_with_punctuation(self):
        """Test duration estimation with punctuation"""
        text = "Hello, world! How are you doing today?"
        # 7 words at 150 WPM = 7/150 * 60 = 2.8 seconds
        duration = self.validator.estimate_duration(text)
        self.assertAlmostEqual(duration, 2.8, delta=0.1)

    def test_estimate_duration_realistic_paragraph(self):
        """Test duration estimation for realistic paragraph"""
        # 50 words should take ~20 seconds at 150 WPM
        text = " ".join([f"word{i}" for i in range(50)])
        duration = self.validator.estimate_duration(text)
        expected = 50 / 150 * 60  # 20 seconds
        self.assertAlmostEqual(duration, expected, delta=1.0)

    def test_get_audio_duration_file_not_exists(self):
        """Test getting duration of non-existent file"""
        duration = self.validator.get_audio_duration(Path("/nonexistent/file.mp3"))
        self.assertIsNone(duration)

    def test_get_audio_duration_with_mutagen(self):
        """Test getting audio duration using mutagen library"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            # Write fake MP3 data (minimum valid MP3)
            tmp.write(b"ID3" + b"\x00" * 1000)

        try:
            # Mock mutagen to return fake duration
            with patch("python_app.src.audio_validator.MP3") as mock_mp3:
                mock_info = Mock()
                mock_info.length = 42.5
                mock_audio = Mock()
                mock_audio.info = mock_info
                mock_mp3.return_value = mock_audio

                duration = self.validator.get_audio_duration(tmp_path)
                self.assertEqual(duration, 42.5)
        finally:
            tmp_path.unlink()

    def test_get_audio_duration_fallback_to_pydub(self):
        """Test fallback to pydub when mutagen fails"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(b"fake mp3 data" * 100)

        try:
            # Mock mutagen to raise ImportError, pydub to succeed
            with patch("python_app.src.audio_validator.MP3", side_effect=ImportError):
                with patch("python_app.src.audio_validator.AudioSegment") as mock_pydub:
                    mock_audio = Mock()
                    mock_audio.__len__ = Mock(return_value=30000)  # 30 seconds in ms
                    mock_pydub.from_mp3.return_value = mock_audio

                    duration = self.validator.get_audio_duration(tmp_path)
                    self.assertEqual(duration, 30.0)
        finally:
            tmp_path.unlink()

    def test_get_audio_duration_all_libraries_unavailable(self):
        """Test when all audio libraries are unavailable"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(b"fake data" * 100)

        try:
            # Mock all libraries to raise ImportError
            with patch("python_app.src.audio_validator.MP3", side_effect=ImportError):
                with patch("python_app.src.audio_validator.AudioSegment", side_effect=ImportError):
                    with patch("python_app.src.audio_validator.sf", side_effect=ImportError):
                        duration = self.validator.get_audio_duration(tmp_path)
                        self.assertIsNone(duration)
        finally:
            tmp_path.unlink()

    def test_validate_audio_file_not_exists(self):
        """Test validation of non-existent file"""
        result = self.validator.validate_audio_file(Path("/nonexistent/file.mp3"))
        self.assertFalse(result)

    def test_validate_audio_file_too_small(self):
        """Test validation of file that's too small"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(b"tiny")  # Less than 1KB

        try:
            result = self.validator.validate_audio_file(tmp_path)
            self.assertFalse(result)
        finally:
            tmp_path.unlink()

    def test_validate_audio_file_no_duration(self):
        """Test validation when duration cannot be determined"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(b"data" * 300)  # > 1KB but invalid MP3

        try:
            # Mock get_audio_duration to return None
            with patch.object(self.validator, "get_audio_duration", return_value=None):
                result = self.validator.validate_audio_file(tmp_path)
                self.assertFalse(result)
        finally:
            tmp_path.unlink()

    def test_validate_audio_file_valid(self):
        """Test validation of valid audio file"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(b"valid audio data" * 100)  # > 1KB

        try:
            # Mock get_audio_duration to return valid duration
            with patch.object(self.validator, "get_audio_duration", return_value=42.5):
                result = self.validator.validate_audio_file(tmp_path)
                self.assertTrue(result)
        finally:
            tmp_path.unlink()

    def test_validate_duration_success(self):
        """Test duration validation when duration matches"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(b"audio" * 500)

        try:
            # Text with 150 words = 60 seconds expected
            text = " ".join(["word"] * 150)

            # Mock audio duration to be within 15% tolerance (60 ± 9 seconds)
            with patch.object(self.validator, "get_audio_duration", return_value=58.0):
                result = self.validator.validate_duration(text, tmp_path, tolerance=0.15)

                self.assertTrue(result.is_valid)
                self.assertAlmostEqual(result.expected_duration, 60.0, delta=1.0)
                self.assertEqual(result.actual_duration, 58.0)
                self.assertLess(abs(result.duration_diff_percent), 15.0)
                self.assertIsNone(result.error_message)
        finally:
            tmp_path.unlink()

    def test_validate_duration_mismatch(self):
        """Test duration validation when duration doesn't match"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(b"audio" * 500)

        try:
            # Text with 150 words = 60 seconds expected
            text = " ".join(["word"] * 150)

            # Mock audio duration to be way off (> 15% tolerance)
            with patch.object(self.validator, "get_audio_duration", return_value=30.0):
                result = self.validator.validate_duration(text, tmp_path, tolerance=0.15)

                self.assertFalse(result.is_valid)
                self.assertAlmostEqual(result.expected_duration, 60.0, delta=1.0)
                self.assertEqual(result.actual_duration, 30.0)
                self.assertGreater(abs(result.duration_diff_percent), 15.0)
                self.assertIsNotNone(result.error_message)
                self.assertIn("Duration mismatch", result.error_message)
        finally:
            tmp_path.unlink()

    def test_validate_duration_no_audio(self):
        """Test duration validation when audio file cannot be read"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(b"corrupted")

        try:
            text = "Some test text"

            # Mock get_audio_duration to return None
            with patch.object(self.validator, "get_audio_duration", return_value=None):
                result = self.validator.validate_duration(text, tmp_path)

                self.assertFalse(result.is_valid)
                self.assertEqual(result.actual_duration, 0.0)
                self.assertIsNotNone(result.error_message)
                self.assertIn("Could not determine", result.error_message)
        finally:
            tmp_path.unlink()

    def test_validate_chapter_file_corrupted(self):
        """Test chapter validation with corrupted file"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(b"tiny")  # Too small

        try:
            chapter_text = "Chapter text with multiple words here"

            # Mock validate_audio_file to return False
            with patch.object(self.validator, "validate_audio_file", return_value=False):
                result = self.validator.validate_chapter(chapter_text, tmp_path)

                self.assertFalse(result.is_valid)
                self.assertIsNotNone(result.error_message)
                self.assertIn("corrupted or missing", result.error_message)
        finally:
            tmp_path.unlink()

    def test_validate_chapter_success(self):
        """Test successful chapter validation"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(b"valid audio" * 200)

        try:
            chapter_text = " ".join(["word"] * 100)  # 100 words = ~40 seconds

            # Mock validate_audio_file to return True
            with patch.object(self.validator, "validate_audio_file", return_value=True):
                # Mock validate_duration to return valid result
                mock_result = ValidationResult(
                    is_valid=True,
                    expected_duration=40.0,
                    actual_duration=38.5,
                    duration_diff_percent=-3.75,
                    error_message=None,
                )
                with patch.object(self.validator, "validate_duration", return_value=mock_result):
                    result = self.validator.validate_chapter(chapter_text, tmp_path)

                    self.assertTrue(result.is_valid)
                    self.assertAlmostEqual(result.expected_duration, 40.0)
        finally:
            tmp_path.unlink()

    def test_custom_tolerance(self):
        """Test validation with custom tolerance"""
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
            tmp.write(b"audio" * 500)

        try:
            text = " ".join(["word"] * 100)  # 100 words = ~40 seconds

            # Mock audio duration to be 10% off
            with patch.object(self.validator, "get_audio_duration", return_value=44.0):
                # With 15% tolerance, should pass
                result1 = self.validator.validate_duration(text, tmp_path, tolerance=0.15)
                self.assertTrue(result1.is_valid)

                # With 5% tolerance, should fail
                result2 = self.validator.validate_duration(text, tmp_path, tolerance=0.05)
                self.assertFalse(result2.is_valid)
        finally:
            tmp_path.unlink()


class TestValidationResult(unittest.TestCase):
    """Test cases for ValidationResult dataclass"""

    def test_creation_valid(self):
        """Test creating a valid ValidationResult"""
        result = ValidationResult(
            is_valid=True,
            expected_duration=60.0,
            actual_duration=58.5,
            duration_diff_percent=-2.5,
            error_message=None,
        )

        self.assertTrue(result.is_valid)
        self.assertEqual(result.expected_duration, 60.0)
        self.assertEqual(result.actual_duration, 58.5)
        self.assertAlmostEqual(result.duration_diff_percent, -2.5)
        self.assertIsNone(result.error_message)

    def test_creation_invalid(self):
        """Test creating an invalid ValidationResult"""
        result = ValidationResult(
            is_valid=False,
            expected_duration=100.0,
            actual_duration=50.0,
            duration_diff_percent=-50.0,
            error_message="Duration too short",
        )

        self.assertFalse(result.is_valid)
        self.assertEqual(result.expected_duration, 100.0)
        self.assertEqual(result.actual_duration, 50.0)
        self.assertAlmostEqual(result.duration_diff_percent, -50.0)
        self.assertEqual(result.error_message, "Duration too short")


if __name__ == "__main__":
    unittest.main()
