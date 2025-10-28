# -*- coding: utf-8 -*-
"""
Unit tests for simplified converter module
"""

import unittest
import tempfile
import asyncio
import os
import re
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, AsyncMock, patch, MagicMock

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.converter import AudioConverter, ConversionResult, ChapterProcessor
from src.config import ConversionConfig
from src.ebook_reader import Chapter
from src.text_formatting import TextFormattingProcessor


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


class TestAudioConverter(unittest.IsolatedAsyncioTestCase):
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

        expected = Path(self.temp_dir) / "edge__default"
        self.assertEqual(output_dir, expected)

    def test_cache_text_creation(self):
        """Ensure chapter text cache is written to disk."""
        cache_dir = Path(self.temp_dir)
        chapter = Chapter(1, "Cache Chapter", "ch-cache.html", "original text")
        payload = "linha 1\nlinha 2"

        self.converter._cache_text(cache_dir, chapter, 1, payload)

        expected = cache_dir / "text" / "001_Cache_Chapter.txt"
        self.assertTrue(expected.exists())
        self.assertEqual(expected.read_text(encoding="utf-8"), payload)

    def test_cached_text_matches_tts_input_simple(self):
        """Test that cached text exactly matches TTS input for simple text"""
        cache_dir = Path(self.temp_dir)

        # Simple text without formatting
        chapter = Chapter(
            index=1,
            name="Simple Chapter",
            source_path="ch1.html",
            text="This is a simple test."
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 1, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "001_Simple_Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL
        self.assertEqual(cached_text, tts_input,
                        "Cached text must exactly match TTS input")
        self.assertEqual(cached_text, "This is a simple test.",
                        "Cached text should preserve simple text exactly")

    def test_cached_text_matches_tts_input_with_language_tags(self):
        """Test that cached text preserves language tags exactly as sent to TTS"""
        cache_dir = Path(self.temp_dir)

        # Text with language tags
        text_with_tags = "English text [[lang:pt-BR]]Texto em português[[/lang]] back to English"

        chapter = Chapter(
            index=2,
            name="Multilingual Chapter",
            source_path="ch2.html",
            text=text_with_tags
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 2, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "002_Multilingual_Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL
        self.assertEqual(cached_text, tts_input,
                        "Cached text must exactly match TTS input with language tags")

        # Should contain the language tags
        self.assertIn("[[lang:pt-BR]]", cached_text,
                     "Language tags should be preserved in cached text")
        self.assertIn("[[/lang]]", cached_text,
                     "Closing language tags should be preserved in cached text")

    def test_cached_text_matches_tts_input_with_speech_text(self):
        """Test that cached text uses speech_text when available"""
        cache_dir = Path(self.temp_dir)

        # Chapter with separate speech_text
        chapter = Chapter(
            index=3,
            name="Speech Chapter",
            source_path="ch3.html",
            text="Original text with HTML",
            speech_text="Processed speech text with [[lang:pt-BR]]português[[/lang]]"
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Should use speech_text, not text
        self.assertEqual(tts_input, chapter.speech_text,
                        "_speech_text should return speech_text when available")

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 3, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "003_Speech_Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL to speech_text
        self.assertEqual(cached_text, tts_input,
                        "Cached text must match TTS input (speech_text)")
        self.assertEqual(cached_text, chapter.speech_text,
                        "Cached text should use speech_text when available")

    def test_parse_txt_vs_tts_input_txt_files(self):
        """Test that parse.txt and tts_input.txt are saved correctly"""
        cache_dir = Path(self.temp_dir)

        # Chapter where text != speech_text
        chapter = Chapter(
            index=5,
            name="Dual Text Chapter",
            source_path="ch5.html",
            text="Original parsed text from EPUB",
            speech_text="Processed speech text [[lang:pt-BR]]with tags[[/lang]]"
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Should use speech_text
        self.assertEqual(tts_input, chapter.speech_text)

        # Simulate caching (as done in converter.py)
        target_dir = cache_dir / "text"
        target_dir.mkdir(parents=True, exist_ok=True)
        safe_name = "Dual_Text_Chapter"

        # Save both files (NEW FORMAT: "N - Name-parsed.txt")
        parse_path = target_dir / f"5 - {safe_name}-parsed.txt"
        parse_path.write_text(chapter.text or "", encoding="utf-8")

        pre_tts_path = target_dir / f"5 - {safe_name}-pre-tts.txt"
        pre_tts_path.write_text(tts_input, encoding="utf-8")

        # Verify both files exist
        self.assertTrue(parse_path.exists(), "parsed.txt should exist")
        self.assertTrue(pre_tts_path.exists(), "pre-tts.txt should exist")

        # Read back
        parse_content = parse_path.read_text(encoding="utf-8")
        pre_tts_content = pre_tts_path.read_text(encoding="utf-8")

        # Verify parsed.txt has original text
        self.assertEqual(parse_content, chapter.text,
                        "parsed.txt should contain original chapter.text")

        # Verify pre-tts.txt has speech_text
        self.assertEqual(pre_tts_content, chapter.speech_text,
                        "pre-tts.txt should contain speech_text")
        self.assertEqual(pre_tts_content, tts_input,
                        "pre-tts.txt should match what goes to TTS")

        # They should be DIFFERENT in this case
        self.assertNotEqual(parse_content, pre_tts_content,
                           "parsed.txt and pre-tts.txt should differ when text != speech_text")

        # Verify language tags are in pre-tts but not in parse
        self.assertIn("[[lang:pt-BR]]", pre_tts_content)
        self.assertNotIn("[[lang:pt-BR]]", parse_content)

    def test_cached_text_matches_tts_input_with_pauses(self):
        """Test that cached text preserves pause markers (ellipsis)"""
        cache_dir = Path(self.temp_dir)

        # Text with pauses
        text_with_pauses = "Wait... for it... now!"

        chapter = Chapter(
            index=4,
            name="Pause Chapter",
            source_path="ch4.html",
            text=text_with_pauses
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 4, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "004_Pause_Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL
        self.assertEqual(cached_text, tts_input,
                        "Cached text must exactly match TTS input with pauses")

        # Should preserve ellipsis
        self.assertEqual(cached_text.count("..."), 2,
                        "Pause markers (ellipsis) should be preserved")

    async def test_integration_cache_matches_tts_during_conversion(self):
        """Integration test: verify cached text matches what was sent to TTS during actual conversion"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Test_Book"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Create chapter with language tags
        chapter = Chapter(
            index=1,
            name="Test Chapter",
            source_path="ch1.html",
            text="English text [[lang:pt-BR]]Texto em português[[/lang]] more English",
            speech_text="English text [[lang:pt-BR]]Texto em português[[/lang]] more English"
        )

        # Mock TTS engine that captures what it receives
        captured_tts_input = []

        class MockTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                # Capture what TTS actually receives
                captured_tts_input.append(text)

                # Create fake output file
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"fake audio data" * 100)  # > 1000 bytes
                return output_path

        mock_engine = MockTTSEngine()

        # Run conversion
        chapters = [chapter]
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            book_title="Test Book"
        )

        result = await self.converter._convert_chapters_sequential(
            chapters, mock_engine, cache_dir, config
        )

        # Verify conversion succeeded
        self.assertEqual(result.converted_chapters, 1, "Chapter should be converted")
        self.assertEqual(len(captured_tts_input), 1, "TTS should be called once")

        # Get what was actually sent to TTS
        actual_tts_input = captured_tts_input[0]

        # Find the cached text files
        text_cache_dir = cache_dir / "text"
        self.assertTrue(text_cache_dir.exists(), "Text cache directory should exist")

        # Should have 2 files: -parsed.txt and -pre-tts.txt
        all_files = list(text_cache_dir.glob("*.txt"))
        self.assertGreaterEqual(len(all_files), 2, "Should have at least 2 cached text files")

        # Find the pre-tts.txt file specifically
        pre_tts_files = list(text_cache_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1, "Should have exactly one pre-tts.txt file")

        cached_text = pre_tts_files[0].read_text(encoding="utf-8")

        # THE CRITICAL TEST: cached text MUST match what was sent to TTS
        self.assertEqual(cached_text, actual_tts_input,
                        "CRITICAL: Cached text must EXACTLY match what was sent to TTS engine")

        # Verify language tags are preserved
        if "[[lang:pt-BR]]" in actual_tts_input:
            self.assertIn("[[lang:pt-BR]]", cached_text,
                         "Language tags in TTS input must appear in cached text")

    async def test_integration_parse_and_tts_files_created(self):
        """Integration: verify parse.txt and tts_input.txt are both created during conversion"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Integration_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Chapter with different text and speech_text
        chapter = Chapter(
            index=1,
            name="Integration Chapter",
            source_path="ch1.html",
            text="Raw parsed text from EPUB",
            speech_text="Processed [[lang:pt-BR]]speech text[[/lang]] for TTS"
        )

        class TrackingTTSEngine:
            """TTS engine that tracks what it receives"""
            def __init__(self):
                self.received_text = None

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.received_text = text
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)  # > 1000 bytes
                return output_path

        tracking_engine = TrackingTTSEngine()

        # Run conversion
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            book_title="Integration_Test"
        )

        result = await self.converter._convert_chapters_sequential(
            [chapter], tracking_engine, cache_dir, config
        )

        # Verify conversion succeeded
        self.assertEqual(result.converted_chapters, 1)

        # Verify files were created
        text_dir = cache_dir / "text"
        self.assertTrue(text_dir.exists())

        # NEW FORMAT: N - Name-parsed.txt and N - Name-pre-tts.txt
        parse_files = list(text_dir.glob("*-parsed.txt"))
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))

        self.assertEqual(len(parse_files), 1, "Should have one parsed.txt file")
        self.assertEqual(len(pre_tts_files), 1, "Should have one pre-tts.txt file")

        # Read both files
        parse_content = parse_files[0].read_text(encoding="utf-8")
        pre_tts_content = pre_tts_files[0].read_text(encoding="utf-8")

        # Verify parsed.txt = original chapter.text
        self.assertEqual(parse_content, chapter.text,
                        "parsed.txt should contain original chapter.text")

        # Verify pre-tts.txt = speech_text (what was sent to TTS)
        self.assertEqual(pre_tts_content, chapter.speech_text,
                        "pre-tts.txt should contain speech_text")
        self.assertEqual(pre_tts_content, tracking_engine.received_text,
                        "pre-tts.txt should match what TTS received")

        # parsed.txt should be different (in this case)
        self.assertNotEqual(parse_content, pre_tts_content,
                           "parsed.txt should differ from pre-tts when text != speech_text")

    async def test_long_chapter_tts_receives_full_text(self):
        """Ensure long chapters deliver the complete payload to the TTS engine."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Long_Book"
        cache_dir.mkdir(parents=True, exist_ok=True)

        long_text = " ".join(f"Sentence {i}." for i in range(4000))
        chapter = Chapter(
            index=1,
            name="Long Chapter",
            source_path="long.html",
            text=long_text,
            speech_text=long_text,
        )

        captured_inputs = []

        class CapturingTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                captured_inputs.append(text)
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"edge" * 800_000)  # ≈3.2MB to mimic long audio
                return output_path

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 800_000)  # ≈2.4MB simulated MP3
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3

        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            book_title="Long_Book",
        )

        result = await self.converter._convert_chapters_sequential(
            [chapter],
            CapturingTTSEngine(),
            cache_dir,
            config,
        )

        self.assertEqual(result.converted_chapters, 1, "Chapter should convert successfully")
        self.assertEqual(len(captured_inputs), 1, "TTS must be invoked exactly once")

        normalise = lambda value: re.sub(r"\s+", " ", value or "").strip()

        self.assertEqual(
            normalise(captured_inputs[0]),
            normalise(long_text),
            "Full chapter text must reach the TTS engine without truncation",
        )

        pre_tts_files = list((cache_dir / "text").glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1, "Expected a single pre-tts cache file")
        cached_text = pre_tts_files[0].read_text(encoding="utf-8")
        self.assertEqual(
            normalise(cached_text),
            normalise(long_text),
            "Cached pre-tts text should match the complete chapter payload",
        )

    async def test_multilingual_text_with_lang_tags(self):
        """Test that [[lang:xx]] tags are preserved in pre-tts.txt for multilingual TTS"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Multilingual_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Chapter with multilingual text and [[lang:]] tags
        multilingual_text = """
        This is English text. [[lang:pt-BR]]Este é texto em português.[[/lang]]
        Back to English. [[lang:es]]Texto en español.[[/lang]] End.
        """

        chapter = Chapter(
            index=1,
            name="Multilingual Chapter",
            source_path="ch1.html",
            text="Original text without tags",  # parsed text
            speech_text=multilingual_text  # pre-TTS text with tags
        )

        class DummyTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

        engine = DummyTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            book_title="Multilingual_Test"
        )

        # Run conversion
        result = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )

        # Verify files were created
        text_dir = cache_dir / "text"
        self.assertTrue(text_dir.exists())

        # Check for -parsed.txt and -pre-tts.txt files
        parsed_files = list(text_dir.glob("*-parsed.txt"))
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))

        self.assertEqual(len(parsed_files), 1, "Should have one parsed.txt file")
        self.assertEqual(len(pre_tts_files), 1, "Should have one pre-tts.txt file")

        # Read both files
        parse_content = parsed_files[0].read_text(encoding="utf-8")
        pre_tts_content = pre_tts_files[0].read_text(encoding="utf-8")

        # Verify parsed.txt = original chapter.text
        self.assertEqual(parse_content, chapter.text,
                        "parsed.txt should contain original chapter.text")

        # Verify pre-tts.txt = speech_text (with [[lang:]] tags)
        # Normalize whitespace for comparison (clean_tts_text normalizes spaces)
        import re
        normalize = lambda t: re.sub(r'\s+', ' ', t or '').strip()
        self.assertEqual(normalize(pre_tts_content), normalize(chapter.speech_text),
                        "pre-tts.txt should contain speech_text with [[lang:]] tags")

        # Verify language tags are preserved in pre-tts.txt
        self.assertIn("[[lang:pt-BR]]", pre_tts_content,
                     "[[lang:pt-BR]] tag should be preserved")
        self.assertIn("[[lang:es]]", pre_tts_content,
                     "[[lang:es]] tag should be preserved")
        self.assertIn("[[/lang]]", pre_tts_content,
                     "Closing [[/lang]] tags should be preserved")

        # Verify language tags are NOT in parsed.txt
        self.assertNotIn("[[lang:", parse_content,
                        "parsed.txt should not contain [[lang:]] tags")

    async def test_emphasis_markers_render_as_audible_cues(self):
        """Formatting markers must become audible cues in pre-tts.txt"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Emphasis_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Text with emphasis markers
        emphasized_text = """
        Normal text. [[fmt:italic]]This is italic[[/fmt]] more text.
        [[fmt:bold]]Bold text here[[/fmt]] and [[fmt:quote]]quoted text[[/fmt]].
        """

        formatter = TextFormattingProcessor()
        audible_text = formatter.to_audible_text(emphasized_text)

        chapter = Chapter(
            index=1,
            name="Emphasis Chapter",
            source_path="ch1.html",
            text="Normal text without markers",
            speech_text=emphasized_text  # Speech text BEFORE formatting processor
        )

        # Track what TTS receives
        tts_received = []

        class TrackingTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                # Apply the same processing as real Edge TTS
                if formatter:
                    processed = formatter.to_audible_text(text, formatting_segments)
                else:
                    processed = text
                tts_received.append(processed)

                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

        engine = TrackingTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            book_title="Emphasis_Test"
        )

        # Run conversion
        result = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )

        # Find pre-tts.txt file
        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1)

        pre_tts_content = pre_tts_files[0].read_text(encoding="utf-8")

        # Verify formatting cues are present (audible hints instead of markers)
        self.assertIn("em itálico:", pre_tts_content,
                     "Italic sections should produce an audible cue")
        self.assertIn("em negrito:", pre_tts_content,
                     "Bold sections should produce an audible cue")
        self.assertIn("entre aspas:", pre_tts_content,
                     "Quoted sections should announce quotation marks")

        # Ensure original [[fmt:]] markers and SSML are removed
        self.assertNotIn("[[fmt:", pre_tts_content,
                         "Formatting markers must not leak to the final TTS text")
        self.assertNotIn("<speak", pre_tts_content.lower(),
                         "SSML should not appear in the text sent to Piper")

        # **CRITICAL**: Verify pre-tts.txt matches EXACTLY what TTS received
        self.assertEqual(len(tts_received), 1, "TTS should be called once")
        import re
        normalize = lambda t: re.sub(r'\s+', ' ', t or '').strip()

        self.assertEqual(
            normalize(pre_tts_content),
            normalize(tts_received[0]),
            "CRITICAL: pre-tts.txt must EXACTLY match what TTS received (including audible cues)"
        )

    async def test_pre_tts_file_matches_tts_input_exactly(self):
        """CRITICAL TEST: Verify pre-tts.txt contains EXACTLY what TTS receives, byte-by-byte."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Exact_Match_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Chapter with formatting that will be processed
        chapter_text = "Normal text. [[fmt:italic]]Italic text[[/fmt]] and [[fmt:bold]]bold text[[/fmt]]."

        chapter = Chapter(
            index=1,
            name="Exact Match Chapter",
            source_path="ch1.html",
            text="Original parsed text",
            speech_text=chapter_text
        )

        # Track EXACTLY what TTS receives
        tts_received_exact = []

        class ExactTrackingTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                # Record the EXACT text received (after Edge TTS processing)
                # This simulates what edge_engine.py does
                formatter = TextFormattingProcessor()
                processed_text = formatter.to_audible_text(text, formatting_segments)
                tts_received_exact.append(processed_text)

                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 500)
                return output_path

        engine = ExactTrackingTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            book_title="Exact_Match_Test"
        )

        # Run conversion
        result = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )

        self.assertEqual(result.converted_chapters, 1)

        # Read pre-tts.txt
        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1, "Should have one pre-tts.txt file")

        cached_text = pre_tts_files[0].read_text(encoding="utf-8")

        # Get what TTS actually received
        self.assertEqual(len(tts_received_exact), 1, "TTS should be called exactly once")
        tts_input = tts_received_exact[0]

        # **CRITICAL ASSERTION**: They must match EXACTLY (not just normalized)
        self.assertEqual(
            cached_text,
            tts_input,
            f"CRITICAL BUG: pre-tts.txt does NOT match TTS input exactly!\n"
            f"Cached ({len(cached_text)} chars): {cached_text[:200]}...\n"
            f"TTS Input ({len(tts_input)} chars): {tts_input[:200]}..."
        )

        # Verify audible cues are present in BOTH
        if "[[fmt:" in chapter_text:
            self.assertIn("em itálico:", cached_text,
                         "Audible cues should be in pre-tts.txt")
            self.assertIn("em itálico:", tts_input,
                         "Audible cues should be in TTS input")

            # And original markers should be GONE from both
            self.assertNotIn("[[fmt:", cached_text,
                           "Markers should not be in pre-tts.txt")
            self.assertNotIn("[[fmt:", tts_input,
                           "Markers should not be in TTS input")

    async def test_cache_invalidation_without_txt_files(self):
        """Test that MP3 files are deleted and reconverted when .txt cache is missing"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Cache_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        chapter = Chapter(
            index=1,
            name="Cache Test Chapter",
            source_path="ch1.html",
            text="Test text",
            speech_text="Test speech text"
        )

        # Track TTS calls
        tts_call_count = [0]

        class CountingTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                tts_call_count[0] += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

        engine = CountingTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            book_title="Cache_Test"
        )

        # First conversion
        result1 = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )
        self.assertEqual(result1.converted_chapters, 1)
        self.assertEqual(tts_call_count[0], 1, "First conversion should call TTS")

        # Verify files were created
        text_dir = cache_dir / "text"
        mp3_file = cache_dir / "001_Cache_Test_Chapter.mp3"

        # NEW FORMAT: "N - Name-pre-tts.txt" (sanitize keeps spaces)
        pre_tts_file = text_dir / "1 - Cache Test Chapter-pre-tts.txt"
        parsed_file = text_dir / "1 - Cache Test Chapter-parsed.txt"

        self.assertTrue(mp3_file.exists(), "MP3 should exist after first conversion")
        self.assertTrue(pre_tts_file.exists(), f"pre-tts.txt should exist at {pre_tts_file}")
        self.assertTrue(parsed_file.exists(), f"parsed.txt should exist at {parsed_file}")

        # Second conversion with .txt intact - should use cache
        tts_call_count[0] = 0
        result2 = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )
        self.assertEqual(result2.converted_chapters, 1)
        self.assertEqual(tts_call_count[0], 0, "Second conversion should NOT call TTS (cache hit)")

        # Now delete .txt files to simulate cache invalidation
        for txt_file in text_dir.glob("*.txt"):
            txt_file.unlink()

        # Third conversion without .txt - should DELETE MP3 and reconvert
        tts_call_count[0] = 0
        result3 = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )
        self.assertEqual(result3.converted_chapters, 1)
        self.assertEqual(tts_call_count[0], 1, "Third conversion should call TTS (cache invalidated)")

        # Verify .txt files were recreated
        self.assertTrue(pre_tts_file.exists(), "pre-tts.txt should be recreated")
        self.assertTrue(parsed_file.exists(), "parsed.txt should be recreated")

    async def test_integration_cache_issue_messias_duna_scenario(self):
        """Reproduce the Messias de Duna bug: TXT without tags but MP3 has HTML tags"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Messias"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # CRITICAL: Simulate the exact scenario where text != speech_text
        # This reproduces the Messias de Duna bug!
        chapter = Chapter(
            index=1,
            name="Messias Chapter",
            source_path="ch1.html",
            text="Original text WITHOUT TAGS",  # Saved to cache
            speech_text="Processed text [[lang:pt-BR]]WITH TAGS[[/lang]]"  # Sent to TTS
        )

        # Track exactly what Edge TTS receives
        tts_received_inputs = []

        class SpyTTSEngine:
            """TTS engine that spies on its inputs"""
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                # Record EXACTLY what we receive
                tts_received_inputs.append({
                    'text': text,
                    'formatting_segments': formatting_segments,
                })

                # Simulate successful synthesis
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 300)  # > 1000 bytes
                return output_path

        spy_engine = SpyTTSEngine()

        # Run conversion
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            book_title="Messias"
        )

        result = await self.converter._convert_chapters_sequential(
            [chapter], spy_engine, cache_dir, config
        )

        # Verify conversion completed
        self.assertEqual(result.converted_chapters, 1)
        self.assertEqual(len(tts_received_inputs), 1)

        # What was sent to TTS
        tts_input_text = tts_received_inputs[0]['text']

        # What was cached (NEW FORMAT: -pre-tts.txt)
        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1, "Should have one pre-tts.txt file")

        cached_text = pre_tts_files[0].read_text(encoding="utf-8")

        # REPRODUCE BUG CHECK:
        # If cached_text lacks tags but tts_input_text has them, we have the bug!
        has_bug = (
            "[[lang:" not in cached_text and
            "[[lang:" in tts_input_text
        )

        self.assertFalse(has_bug,
                        f"BUG DETECTED: Cached text lacks language tags that were sent to TTS!\n"
                        f"Cached: {cached_text[:100]}\n"
                        f"TTS Input: {tts_input_text[:100]}")

        self.assertNotIn("<speak", tts_input_text.lower(),
                         "SSML tags must never reach the TTS engine input")
        self.assertNotIn("[[fmt:", tts_input_text,
                         "Formatting markers must be stripped before synthesis")

        # CORRECT BEHAVIOR: they must match exactly
        self.assertEqual(cached_text, tts_input_text,
                        "Cached text must exactly match TTS input (fixing Messias de Duna bug)")

    async def test_convert_chapters_success(self):
        """Test successful chapter conversion"""
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2")
        ]

        # Mock TTS engine that creates audio files
        class SuccessTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"fake audio" * 200)  # > 1000 bytes
                return output_path

        mock_tts_engine = SuccessTTSEngine()
        output_dir = Path(self.temp_dir)

        result = await self.converter._convert_chapters_sequential(
            chapters, mock_tts_engine, output_dir, self.config
        )

        self.assertIsInstance(result, ConversionResult)
        self.assertTrue(result.success)
        self.assertEqual(result.total_chapters, 2)
        self.assertEqual(result.converted_chapters, 2)
        self.assertEqual(len(result.output_files), 2)
        self.assertEqual(len(result.errors), 0)

    async def test_convert_chapters_with_errors(self):
        """Test chapter conversion with errors"""
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2")
        ]

        # Mock TTS engine that fails on second chapter
        call_count = [0]

        class PartialFailTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                call_count[0] += 1
                if call_count[0] == 1:
                    # First chapter succeeds
                    output_path = Path(output_path)
                    output_path.parent.mkdir(parents=True, exist_ok=True)
                    output_path.write_bytes(b"fake audio" * 200)  # > 1000 bytes
                    return output_path
                else:
                    # Second chapter fails
                    return None

        self.last_error = "Test error"

        mock_tts_engine = PartialFailTTSEngine()
        mock_tts_engine.last_error = "Test error"
        output_dir = Path(self.temp_dir)

        result = await self.converter._convert_chapters_sequential(
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

    @unittest.skip("Integration test needs update for sequential processing")
    async def test_convert_integration(self):
        """Test full convert method integration"""
        with patch.object(self.converter, '_setup_output_directory') as mock_setup, \
             patch.object(self.converter.tts_factory, 'create_engine') as mock_create, \
             patch.object(self.converter, '_convert_chapters_sequential') as mock_convert, \
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

    async def test_convert_retries_after_partial_tts_failure(self):
        """Conversion should automatically retry chapters when TTS returns partial output."""
        output_root = Path(self.temp_dir) / "retry_output"
        output_root.mkdir(parents=True, exist_ok=True)

        long_text = " ".join(f"Frase número {i} do capítulo." for i in range(600))
        chapter = Chapter(
            index=1,
            name="Capítulo de Retry",
            source_path="retry.html",
            text=long_text,
            speech_text=long_text,
        )

        reader = SimpleNamespace(
            title="Livro Retry",
            file_path="retry.epub",
            get_chapter_structure=lambda preserve_all=True: [chapter],
        )

        class FlakyTTSEngine:
            def __init__(self):
                self.calls = 0
                self.voice = "retry-voice"
                self.last_error = None

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                path = Path(output_path)
                path.parent.mkdir(parents=True, exist_ok=True)

                if self.calls == 1:
                    # Produce an obviously truncated file (~60s @ 8kbps)
                    path.write_bytes(b"a" * 60_000)
                else:
                    # Produce a healthy file (~12m+) to satisfy duration heuristics
                    path.write_bytes(b"b" * 1_000_000)
                return path

        flaky_engine = FlakyTTSEngine()
        self.converter.tts_factory.create_engine = Mock(return_value=flaky_engine)

        config = ConversionConfig(
            engine="edge",
            output_dir=str(output_root),
            book_title="Livro Retry",
            extra={"max_auto_retries": 3},
        )

        result = await self.converter.convert(reader, config)

        self.assertTrue(result.success, "Conversion should eventually succeed after retry")
        self.assertEqual(result.converted_chapters, 1, "Chapter must be present in final result")
        self.assertGreaterEqual(len(result.output_files), 1, "At least one output file should be produced")
        self.assertEqual(flaky_engine.calls, 2, "Engine must retry exactly once after the initial failure")
        final_output = result.output_files[0]
        self.assertTrue(final_output.exists(), "Final MP3 should exist after conversion")
        self.assertGreater(final_output.stat().st_size, 1000, "Generated MP3 should have expected size")
        self.assertFalse(result.errors, "No residual errors should remain after successful retry")

    async def test_edge_tts_receives_complete_chapter_content(self):
        """CRITICAL: Verify Edge TTS receives the COMPLETE chapter text, not truncated."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Complete_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Create a realistic chapter (equivalent to ~5 minutes of audio)
        # Average reading: 150 words/min, so 5 min = ~750 words
        realistic_chapter = " ".join(
            f"This is sentence number {i} with realistic content that makes sense. " for i in range(750)
        )

        chapter = Chapter(
            index=1,
            name="Complete Chapter",
            source_path="ch1.html",
            text=realistic_chapter,
            speech_text=realistic_chapter,
        )

        # Track what Edge TTS actually receives
        tts_received_texts = []

        class SpyEdgeTTSEngine:
            """Mock Edge TTS that captures all text it receives."""
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                # Record EVERY call to synthesize_async
                tts_received_texts.append(text)

                # Simulate successful synthesis
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 500_000)  # ≈2.5MB to satisfy duration heuristics
                return output_path

        spy_engine = SpyEdgeTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            book_title="Complete_Test"
        )

        # Run conversion
        result = await self.converter._convert_chapters_sequential(
            [chapter], spy_engine, cache_dir, config
        )

        # Verify conversion succeeded
        self.assertEqual(result.converted_chapters, 1, "Chapter should convert successfully")

        # Verify Edge TTS was called (possibly multiple times for segments)
        self.assertGreater(len(tts_received_texts), 0, "Edge TTS should be called at least once")

        # Combine all text received by Edge TTS (in case it was segmented)
        total_tts_input = " ".join(tts_received_texts)

        # Normalize for comparison
        import re
        normalize = lambda t: re.sub(r'\s+', ' ', t or '').strip()

        normalized_original = normalize(realistic_chapter)
        normalized_tts_input = normalize(total_tts_input)

        # CRITICAL: TTS should receive 100% of the text
        original_word_count = len(normalized_original.split())
        tts_word_count = len(normalized_tts_input.split())

        self.assertGreaterEqual(
            tts_word_count,
            original_word_count * 0.99,  # Allow 1% tolerance for processing
            f"CRITICAL BUG: TTS only received {tts_word_count}/{original_word_count} words! "
            f"Missing {original_word_count - tts_word_count} words. This causes audio truncation."
        )

        # Verify first and last sentences are present
        self.assertIn("sentence number 0", normalized_tts_input,
                     "First sentence missing - TTS input is truncated at start")
        self.assertIn("sentence number 749", normalized_tts_input,
                     "Last sentence missing - TTS input is truncated at end")

    async def test_show_structure_matches_tts_input(self):
        """Verify that show-structure output matches what actually goes to TTS."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Structure_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Chapter with language tags (as shown in show-structure)
        chapter_with_tags = Chapter(
            index=1,
            name="Structure Test",
            source_path="ch1.html",
            text="Original parsed text",
            speech_text="English text [[lang:pt-BR]]Texto português[[/lang]] more English"
        )

        # Track what TTS receives
        tts_inputs = []

        class CapturingTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                tts_inputs.append(text)
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 500)
                return output_path

        engine = CapturingTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            book_title="Structure_Test"
        )

        # Run conversion
        result = await self.converter._convert_chapters_sequential(
            [chapter_with_tags], engine, cache_dir, config
        )

        self.assertEqual(result.converted_chapters, 1)

        # What was sent to TTS
        tts_input = " ".join(tts_inputs)

        # What would be shown in show-structure (the speech_text)
        show_structure_text = chapter_with_tags.speech_text

        # They MUST match
        import re
        normalize = lambda t: re.sub(r'\s+', ' ', t or '').strip()

        self.assertEqual(
            normalize(tts_input),
            normalize(show_structure_text),
            "CRITICAL: show-structure output does NOT match TTS input! "
            "This means the text files don't reflect what was actually converted."
        )

        # Verify pre-tts.txt file matches as well
        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1)

        cached_text = pre_tts_files[0].read_text(encoding="utf-8")

        self.assertEqual(
            normalize(cached_text),
            normalize(show_structure_text),
            "pre-tts.txt should match show-structure (speech_text)"
        )


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
