# -*- coding: utf-8 -*-
"""
Unit tests for simplified utils module
"""

import unittest
import tempfile
import asyncio
import os
from pathlib import Path
from unittest.mock import patch, Mock, AsyncMock

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.utils import FileManager, AudioProcessor, TextValidator


class TestFileManager(unittest.TestCase):
    """Test cases for FileManager class"""

    def test_sanitize_filename_normal(self):
        """Test sanitizing normal filename"""
        result = FileManager.sanitize_filename("Normal Filename")
        self.assertEqual(result, "Normal Filename")

    def test_sanitize_filename_with_invalid_chars(self):
        """Test sanitizing filename with invalid characters"""
        result = FileManager.sanitize_filename('Test<File>Name:With"Invalid|Chars?*')
        self.assertEqual(result, "Test_File_Name_With_Invalid_Chars__")

    def test_sanitize_filename_empty(self):
        """Test sanitizing empty filename"""
        result = FileManager.sanitize_filename("")
        self.assertEqual(result, "untitled")

    def test_sanitize_filename_none(self):
        """Test sanitizing None filename"""
        result = FileManager.sanitize_filename(None)
        self.assertEqual(result, "untitled")

    def test_sanitize_filename_long(self):
        """Test sanitizing very long filename"""
        long_name = "A" * 200
        result = FileManager.sanitize_filename(long_name, max_length=50)
        self.assertEqual(len(result), 50)

    def test_sanitize_filename_whitespace(self):
        """Test sanitizing filename with excessive whitespace"""
        result = FileManager.sanitize_filename("   Multiple   Spaces   ")
        self.assertEqual(result, "Multiple Spaces")

    def test_sanitize_filename_only_invalid(self):
        """Test sanitizing filename with only invalid characters"""
        result = FileManager.sanitize_filename("<>:\"/\\|?*")
        self.assertEqual(result, "_________")

    def test_ensure_directory_new(self):
        """Test ensuring new directory exists"""
        with tempfile.TemporaryDirectory() as temp_dir:
            new_dir = Path(temp_dir) / "new_directory"
            
            result = FileManager.ensure_directory(new_dir)
            
            self.assertEqual(result, new_dir)
            self.assertTrue(new_dir.exists())
            self.assertTrue(new_dir.is_dir())

    def test_ensure_directory_existing(self):
        """Test ensuring existing directory"""
        with tempfile.TemporaryDirectory() as temp_dir:
            existing_dir = Path(temp_dir)
            
            result = FileManager.ensure_directory(existing_dir)
            
            self.assertEqual(result, existing_dir)
            self.assertTrue(existing_dir.exists())

    def test_ensure_directory_nested(self):
        """Test ensuring nested directory creation"""
        with tempfile.TemporaryDirectory() as temp_dir:
            nested_dir = Path(temp_dir) / "level1" / "level2" / "level3"
            
            result = FileManager.ensure_directory(nested_dir)
            
            self.assertEqual(result, nested_dir)
            self.assertTrue(nested_dir.exists())

    def test_cleanup_temp_files(self):
        """Test cleaning up temporary files"""
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            
            # Create some temp files
            temp1 = temp_path / "file1.tmp"
            temp2 = temp_path / "file2.tmp"
            regular_file = temp_path / "regular.txt"
            
            temp1.write_text("temp1")
            temp2.write_text("temp2")
            regular_file.write_text("regular")
            
            FileManager.cleanup_temp_files(temp_path, "*.tmp")
            
            # Temp files should be gone, regular file should remain
            self.assertFalse(temp1.exists())
            self.assertFalse(temp2.exists())
            self.assertTrue(regular_file.exists())

    def test_cleanup_temp_files_nonexistent_directory(self):
        """Test cleaning up temp files in non-existent directory"""
        nonexistent = Path("/nonexistent/directory")
        
        # Should not raise exception
        FileManager.cleanup_temp_files(nonexistent)


class TestAudioProcessor(unittest.IsolatedAsyncioTestCase):
    """Test cases for AudioProcessor class"""

    def setUp(self):
        """Set up test fixtures"""
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    async def test_convert_to_mp3_success(self):
        """Test successful MP3 conversion"""
        input_file = Path(self.temp_dir) / "input.wav"
        output_file = Path(self.temp_dir) / "output.mp3"

        # Create dummy input file
        input_file.write_text("dummy wav content")

        # Mock ffmpeg subprocess
        with patch('src.utils.asyncio.create_subprocess_exec') as mock_subprocess:
            # Mock successful ffmpeg process
            mock_process = AsyncMock()
            mock_process.wait.return_value = None
            mock_process.returncode = 0
            mock_subprocess.return_value = mock_process

            # Create output file (simulating ffmpeg success)
            output_file.write_text("dummy mp3 content")

            result = await AudioProcessor.convert_to_mp3(input_file, output_file)

            self.assertEqual(result, output_file)
            mock_subprocess.assert_called_once()

    async def test_convert_to_mp3_input_not_exists(self):
        """Test MP3 conversion with non-existent input file"""
        input_file = Path(self.temp_dir) / "nonexistent.wav"
        output_file = Path(self.temp_dir) / "output.mp3"
        
        result = await AudioProcessor.convert_to_mp3(input_file, output_file)
        
        self.assertIsNone(result)

    async def test_convert_to_mp3_ffmpeg_failure(self):
        """Test MP3 conversion with ffmpeg failure"""
        input_file = Path(self.temp_dir) / "input.wav"
        output_file = Path(self.temp_dir) / "output.mp3"
        
        input_file.write_text("dummy wav content")
        
        with patch('src.utils.asyncio.create_subprocess_exec') as mock_subprocess:
            # Mock failed ffmpeg process
            mock_process = AsyncMock()
            mock_process.wait.return_value = None
            mock_process.returncode = 1  # Failure
            mock_subprocess.return_value = mock_process
            
            result = await AudioProcessor.convert_to_mp3(input_file, output_file)
            
            self.assertIsNone(result)

    async def test_convert_to_mp3_exception(self):
        """Test MP3 conversion with exception"""
        input_file = Path(self.temp_dir) / "input.wav"
        output_file = Path(self.temp_dir) / "output.mp3"
        
        input_file.write_text("dummy wav content")
        
        with patch('src.utils.asyncio.create_subprocess_exec') as mock_subprocess:
            mock_subprocess.side_effect = Exception("Test error")
            
            result = await AudioProcessor.convert_to_mp3(input_file, output_file)
            
            self.assertIsNone(result)

    async def test_convert_to_mp3_custom_bitrate(self):
        """Test MP3 conversion with custom bitrate"""
        input_file = Path(self.temp_dir) / "input.wav"
        output_file = Path(self.temp_dir) / "output.mp3"

        input_file.write_text("dummy wav content")

        # Mock ffmpeg subprocess
        with patch('src.utils.asyncio.create_subprocess_exec') as mock_subprocess:
            mock_process = AsyncMock()
            mock_process.wait.return_value = None
            mock_process.returncode = 0
            mock_subprocess.return_value = mock_process

            output_file.write_text("dummy mp3 content")

            result = await AudioProcessor.convert_to_mp3(input_file, output_file, bitrate="64k")

            self.assertEqual(result, output_file)

            # Check that custom bitrate was used
            call_args = mock_subprocess.call_args[0][0]
            self.assertIn("64k", call_args)

    def test_validate_audio_file_valid(self):
        """Test validating valid audio file"""
        audio_file = Path(self.temp_dir) / "audio.mp3"
        audio_file.write_text("A" * 2000)  # 2KB file
        
        result = AudioProcessor.validate_audio_file(audio_file)
        self.assertTrue(result)

    def test_validate_audio_file_too_small(self):
        """Test validating audio file that's too small"""
        audio_file = Path(self.temp_dir) / "audio.mp3"
        audio_file.write_text("small")  # Very small file
        
        result = AudioProcessor.validate_audio_file(audio_file)
        self.assertFalse(result)

    def test_validate_audio_file_nonexistent(self):
        """Test validating non-existent audio file"""
        audio_file = Path(self.temp_dir) / "nonexistent.mp3"
        
        result = AudioProcessor.validate_audio_file(audio_file)
        self.assertFalse(result)


class TestTextValidator(unittest.TestCase):
    """Test cases for TextValidator class"""

    def test_is_valid_text_valid(self):
        """Test validating valid text"""
        text = "This is a valid text for TTS processing."
        result = TextValidator.is_valid_text(text)
        self.assertTrue(result)

    def test_is_valid_text_empty(self):
        """Test validating empty text"""
        result = TextValidator.is_valid_text("")
        self.assertFalse(result)

    def test_is_valid_text_none(self):
        """Test validating None text"""
        result = TextValidator.is_valid_text(None)
        self.assertFalse(result)

    def test_is_valid_text_whitespace_only(self):
        """Test validating whitespace-only text"""
        result = TextValidator.is_valid_text("   \n\t   ")
        self.assertFalse(result)

    def test_is_valid_text_too_short(self):
        """Test validating text that's too short"""
        result = TextValidator.is_valid_text("Hi", min_length=10)
        self.assertFalse(result)

    def test_is_valid_text_custom_min_length(self):
        """Test validating text with custom minimum length"""
        text = "Short"
        
        result_default = TextValidator.is_valid_text(text)
        self.assertFalse(result_default)  # Default min_length=10
        
        result_custom = TextValidator.is_valid_text(text, min_length=3)
        self.assertTrue(result_custom)

    def test_estimate_duration_normal(self):
        """Test estimating duration for normal text"""
        text = "This is a test text with exactly ten words in total."
        duration = TextValidator.estimate_duration(text, words_per_minute=150)
        
        # 11 words / 150 wpm * 60 = 4.4 seconds
        self.assertAlmostEqual(duration, 4.4, places=1)

    def test_estimate_duration_empty(self):
        """Test estimating duration for empty text"""
        duration = TextValidator.estimate_duration("")
        self.assertEqual(duration, 0.0)

    def test_estimate_duration_single_word(self):
        """Test estimating duration for single word"""
        duration = TextValidator.estimate_duration("Hello")
        expected = (1 / 150) * 60  # 0.4 seconds
        self.assertAlmostEqual(duration, expected, places=1)

    def test_estimate_duration_custom_wpm(self):
        """Test estimating duration with custom words per minute"""
        text = "One two three four five"  # 5 words
        duration = TextValidator.estimate_duration(text, words_per_minute=300)
        
        # 5 words / 300 wpm * 60 = 1 second
        self.assertAlmostEqual(duration, 1.0, places=1)


if __name__ == '__main__':
    unittest.main()
