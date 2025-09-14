# -*- coding: utf-8 -*-
"""
Unit tests for simplified converter module
"""

import unittest
import tempfile
import asyncio
import os
from pathlib import Path
from unittest.mock import Mock, AsyncMock, patch, MagicMock

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.converter import AudioConverter, ConversionResult, ChapterProcessor
from src.config import ConversionConfig
from src.ebook_reader import Chapter


class TestConversionResult(unittest.TestCase):
    """Test cases for ConversionResult dataclass"""

    def test_conversion_result_creation(self):
        """Test ConversionResult creation"""
        result = ConversionResult(
            success=True,
            total_chapters=5,
            converted_chapters=4,
            output_files=[Path("file1.mp3"), Path("file2.mp3")],
            errors=["Error in chapter 3"]
        )
        
        self.assertTrue(result.success)
        self.assertEqual(result.total_chapters, 5)
        self.assertEqual(result.converted_chapters, 4)
        self.assertEqual(len(result.output_files), 2)
        self.assertEqual(len(result.errors), 1)


class TestAudioConverter(unittest.TestCase):
    """Test cases for AudioConverter class"""

    def setUp(self):
        """Set up test fixtures"""
        self.converter = AudioConverter()
        self.temp_dir = tempfile.mkdtemp()
        
        # Mock objects
        self.mock_reader = Mock()
        self.mock_reader.title = "Test Book"
        self.mock_reader.get_chapter_structure.return_value = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2")
        ]
        
        self.config = ConversionConfig(
            engine="edge",
            voice="test-voice",
            output_dir=self.temp_dir,
            book_title="Test Book"
        )

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_init(self):
        """Test AudioConverter initialization"""
        self.assertIsNotNone(self.converter.tts_factory)
        self.assertIsNotNone(self.converter.audio_processor)
        self.assertIsNotNone(self.converter.file_manager)
        self.assertIsNotNone(self.converter.progress)

    def test_setup_output_directory(self):
        """Test output directory setup"""
        output_dir = self.converter._setup_output_directory(self.config)
        
        self.assertIsInstance(output_dir, Path)
        self.assertTrue(output_dir.exists())
        self.assertIn("Test Book", str(output_dir))

    def test_setup_output_directory_no_title(self):
        """Test output directory setup without book title"""
        config = ConversionConfig(engine="edge", output_dir=self.temp_dir, book_title="")
        output_dir = self.converter._setup_output_directory(config)
        
        self.assertEqual(output_dir, Path(self.temp_dir))

    @patch('src.converter.asyncio.gather')
    async def test_convert_chapters_success(self, mock_gather):
        """Test successful chapter conversion"""
        # Mock gather to return successful results
        mock_gather.return_value = [
            Path("output1.mp3"),
            Path("output2.mp3")
        ]
        
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2")
        ]
        
        mock_tts_engine = Mock()
        output_dir = Path(self.temp_dir)
        
        result = await self.converter._convert_chapters(
            chapters, mock_tts_engine, output_dir, self.config
        )
        
        self.assertIsInstance(result, ConversionResult)
        self.assertTrue(result.success)
        self.assertEqual(result.total_chapters, 2)
        self.assertEqual(result.converted_chapters, 2)
        self.assertEqual(len(result.output_files), 2)
        self.assertEqual(len(result.errors), 0)

    @patch('src.converter.asyncio.gather')
    async def test_convert_chapters_with_errors(self, mock_gather):
        """Test chapter conversion with errors"""
        # Mock gather to return mixed results
        mock_gather.return_value = [
            Path("output1.mp3"),
            Exception("Test error")
        ]
        
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2")
        ]
        
        mock_tts_engine = Mock()
        output_dir = Path(self.temp_dir)
        
        result = await self.converter._convert_chapters(
            chapters, mock_tts_engine, output_dir, self.config
        )
        
        self.assertFalse(result.success)
        self.assertEqual(result.total_chapters, 2)
        self.assertEqual(result.converted_chapters, 1)
        self.assertEqual(len(result.output_files), 1)
        self.assertEqual(len(result.errors), 1)

    async def test_convert_single_chapter_success(self):
        """Test successful single chapter conversion"""
        semaphore = asyncio.Semaphore(1)
        chapter = Chapter(1, "Test Chapter", "test.html", "Test content")
        
        # Mock TTS engine
        mock_tts_engine = AsyncMock()
        temp_wav = Path(self.temp_dir) / "temp.wav"
        temp_wav.write_text("dummy wav")
        mock_tts_engine.synthesize_async.return_value = temp_wav
        
        # Mock audio processor
        output_mp3 = Path(self.temp_dir) / "output.mp3"
        output_mp3.write_text("dummy mp3")
        self.converter.audio_processor.convert_to_mp3 = AsyncMock(return_value=output_mp3)
        
        output_dir = Path(self.temp_dir)
        
        result = await self.converter._convert_single_chapter(
            semaphore, chapter, mock_tts_engine, output_dir, 1
        )
        
        self.assertEqual(result, output_mp3)
        mock_tts_engine.synthesize_async.assert_called_once()
        self.converter.audio_processor.convert_to_mp3.assert_called_once()

    async def test_convert_single_chapter_file_exists(self):
        """Test single chapter conversion when file already exists"""
        semaphore = asyncio.Semaphore(1)
        chapter = Chapter(1, "Test Chapter", "test.html", "Test content")
        
        # Create existing output file
        output_dir = Path(self.temp_dir)
        existing_file = output_dir / "001_Test_Chapter.mp3"
        existing_file.write_text("existing content")
        
        mock_tts_engine = Mock()
        
        result = await self.converter._convert_single_chapter(
            semaphore, chapter, mock_tts_engine, output_dir, 1
        )
        
        self.assertEqual(result, existing_file)

    async def test_convert_single_chapter_tts_failure(self):
        """Test single chapter conversion with TTS failure"""
        semaphore = asyncio.Semaphore(1)
        chapter = Chapter(1, "Test Chapter", "test.html", "Test content")
        
        # Mock TTS engine to return None (failure)
        mock_tts_engine = AsyncMock()
        mock_tts_engine.synthesize_async.return_value = None
        
        output_dir = Path(self.temp_dir)
        
        result = await self.converter._convert_single_chapter(
            semaphore, chapter, mock_tts_engine, output_dir, 1
        )
        
        self.assertIsNone(result)

    async def test_convert_single_chapter_exception(self):
        """Test single chapter conversion with exception"""
        semaphore = asyncio.Semaphore(1)
        chapter = Chapter(1, "Test Chapter", "test.html", "Test content")
        
        # Mock TTS engine to raise exception
        mock_tts_engine = AsyncMock()
        mock_tts_engine.synthesize_async.side_effect = Exception("Test error")
        
        output_dir = Path(self.temp_dir)
        
        with self.assertRaises(Exception):
            await self.converter._convert_single_chapter(
                semaphore, chapter, mock_tts_engine, output_dir, 1
            )

    def test_report_results_success(self):
        """Test reporting successful results"""
        result = ConversionResult(
            success=True,
            total_chapters=3,
            converted_chapters=3,
            output_files=[Path("file1.mp3"), Path("file2.mp3")],
            errors=[]
        )
        
        # Should not raise exception
        self.converter._report_results(result)

    def test_report_results_with_errors(self):
        """Test reporting results with errors"""
        result = ConversionResult(
            success=False,
            total_chapters=3,
            converted_chapters=2,
            output_files=[Path("file1.mp3")],
            errors=["Error 1", "Error 2", "Error 3", "Error 4"]
        )
        
        # Should not raise exception
        self.converter._report_results(result)

    async def test_convert_integration(self):
        """Test full convert method integration"""
        with patch.object(self.converter, '_setup_output_directory') as mock_setup, \
             patch.object(self.converter.tts_factory, 'create_engine') as mock_create, \
             patch.object(self.converter, '_convert_chapters') as mock_convert, \
             patch.object(self.converter, '_report_results') as mock_report:

            mock_setup.return_value = Path(self.temp_dir)
            mock_create.return_value = Mock()
            expected_result = ConversionResult(
                success=True,
                total_chapters=2,
                converted_chapters=2,
                output_files=[],
                errors=[],
            )
            mock_convert.return_value = expected_result

            result = await self.converter.convert(self.mock_reader, self.config)

            self.assertIs(result, expected_result)
            mock_setup.assert_called_once()
            mock_create.assert_called_once()
            mock_convert.assert_called_once()
            mock_report.assert_called_once_with(expected_result)

    async def test_convert_with_exception(self):
        """Test convert method propagates exceptions"""

        with patch.object(self.converter.tts_factory, 'create_engine') as mock_create:
            mock_create.side_effect = Exception("Test error")

            with self.assertRaises(Exception):
                await self.converter.convert(self.mock_reader, self.config)


class TestChapterProcessor(unittest.TestCase):
    """Test cases for ChapterProcessor class"""

    def test_chunk_text_short_text(self):
        """Test chunking short text"""
        text = "This is a short text."
        chunks = ChapterProcessor.chunk_text(text, max_size=100)
        
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0], text)

    def test_chunk_text_long_text(self):
        """Test chunking long text"""
        text = "This is sentence one. This is sentence two! This is sentence three? This is sentence four."
        chunks = ChapterProcessor.chunk_text(text, max_size=40)
        
        self.assertGreater(len(chunks), 1)
        
        # Check that all chunks are within size limit
        for chunk in chunks:
            self.assertLessEqual(len(chunk), 50)  # Allow some buffer
        
        # Check that joining chunks gives original text (approximately)
        joined = ''.join(chunks)
        self.assertIn("sentence one", joined)
        self.assertIn("sentence four", joined)

    def test_chunk_text_empty_text(self):
        """Test chunking empty text"""
        chunks = ChapterProcessor.chunk_text("", max_size=100)
        
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0], "")

    def test_chunk_text_single_long_sentence(self):
        """Test chunking single very long sentence"""
        text = "This is a very long sentence that exceeds the maximum size limit and should be handled gracefully"
        chunks = ChapterProcessor.chunk_text(text, max_size=50)
        
        self.assertGreaterEqual(len(chunks), 1)
        # Should handle gracefully even if single sentence is too long


if __name__ == '__main__':
    unittest.main()
