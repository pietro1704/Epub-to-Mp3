"""Single chapter scenarios sharing the original unittest fixture."""

import python_app.tests._converter_test_support as _shared_test_exports
from python_app.tests._converter_test_support import AsyncMock as AsyncMock
from python_app.tests._converter_test_support import Chapter as Chapter
from python_app.tests._converter_test_support import ConversionConfig as ConversionConfig
from python_app.tests._converter_test_support import Mock as Mock
from python_app.tests._converter_test_support import MockTTSEngine as MockTTSEngine
from python_app.tests._converter_test_support import Path as Path
from python_app.tests._converter_test_support import SimpleNamespace as SimpleNamespace
from python_app.tests._converter_test_support import asyncio as asyncio
from python_app.tests._converter_test_support import patch as patch

re = _shared_test_exports.re


class SingleChapterCases:
    async def test_edge_retries_after_truncated_audio_and_succeeds(self):
        """Edge conversion should retry the chapter when truncation is detected."""
        chapter = Chapter(1, "Retry Chapter", "retry.html", "retry content " * 800)
        output_dir = Path(self.temp_dir)

        class FlakyEdgeTTS(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                if self.calls == 1:
                    output_path.write_bytes(b"x" * 80_000)
                else:
                    output_path.write_bytes(b"y" * 220_000)
                return output_path

        engine = FlakyEdgeTTS()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            force_reprocess=True,
            book_title="Retry Book",
        )

        with patch.object(
            self.converter,
            "_detect_short_audio_output",
            side_effect=["Audio possibly truncated", None],
        ):
            result = await self.converter._convert_chapters_sequential(
                [chapter],
                engine,
                output_dir,
                config,
            )

        self.assertTrue(result.success)
        self.assertEqual(result.converted_chapters, 1)
        self.assertFalse(result.errors)
        self.assertEqual(engine.calls, 2, "chapter should be retried once after truncation")
        self.assertEqual(len(result.output_files), 1)

    async def test_convert_single_chapter_success(self):
        """Test successful single chapter conversion"""
        semaphore = asyncio.Semaphore(1)
        chapter = Chapter(1, "Test Chapter", "test.html", "Test content")

        # Mock TTS engine
        mock_tts_engine = AsyncMock()
        temp_wav = Path(self.temp_dir) / "temp.wav"
        temp_wav.write_text("dummy wav")
        mock_tts_engine.synthesize_async.return_value = temp_wav
        # Configure Protocol methods for validation system
        mock_tts_engine.get_synthesis_tracker = Mock(return_value=None)
        mock_tts_engine.get_synthesis_log = Mock(return_value=[])

        # Mock audio processor
        output_mp3 = Path(self.temp_dir) / "output.mp3"
        output_mp3.write_text("dummy mp3")
        self.converter.audio_processor.convert_to_mp3 = AsyncMock(return_value=output_mp3)
        self.converter._auto_validate_output = AsyncMock()

        output_dir = Path(self.temp_dir)

        result = await self.converter._convert_single_chapter(
            semaphore, chapter, mock_tts_engine, output_dir, 1
        )

        self.assertEqual(result, output_mp3)
        mock_tts_engine.synthesize_async.assert_called_once()
        self.converter.audio_processor.convert_to_mp3.assert_called_once()
        self.converter._auto_validate_output.assert_called()

    async def test_convert_single_chapter_file_exists(self):
        """Test single chapter conversion when file already exists"""
        semaphore = asyncio.Semaphore(1)
        chapter = Chapter(1, "Test Chapter", "test.html", "Test content")

        # Create existing output file
        output_dir = Path(self.temp_dir)
        existing_file = output_dir / "001 - Test Chapter.mp3"
        existing_file.write_bytes(b"\x00" * 2048)  # Non-empty placeholder
        temp_wav = output_dir / "temp.wav"
        temp_wav.write_bytes(b"wavdata")

        mock_tts_engine = AsyncMock()
        mock_tts_engine.synthesize_async = AsyncMock(return_value=temp_wav)
        # Configure Protocol methods for validation system
        mock_tts_engine.get_synthesis_tracker = Mock(return_value=None)
        mock_tts_engine.get_synthesis_log = Mock(return_value=[])

        valid_result = SimpleNamespace(
            is_valid=True,
            expected_duration=1.0,
            actual_duration=1.0,
            duration_diff_percent=0.0,
            error_message=None,
        )

        with patch.object(
            self.converter.file_manager, "get_temp_output_path", return_value=existing_file
        ):
            with patch.object(
                self.converter.audio_processor,
                "convert_to_mp3",
                AsyncMock(return_value=existing_file),
            ):
                with patch(
                    "python_app.src.audio_validator.AudioValidator.validate_duration",
                    return_value=valid_result,
                ):
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
        # Configure Protocol methods for validation system
        mock_tts_engine.get_synthesis_tracker = Mock(return_value=None)
        mock_tts_engine.get_synthesis_log = Mock(return_value=[])

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
        # Configure Protocol methods for validation system
        mock_tts_engine.get_synthesis_tracker = Mock(return_value=None)
        mock_tts_engine.get_synthesis_log = Mock(return_value=[])

        output_dir = Path(self.temp_dir)

        with self.assertRaises(Exception):
            await self.converter._convert_single_chapter(
                semaphore, chapter, mock_tts_engine, output_dir, 1
            )

    async def test_convert_retries_after_tts_exception(self):
        """Conversion should automatically retry chapters when TTS raises an exception."""
        output_root = Path(self.temp_dir) / "retry_output"
        output_root.mkdir(parents=True, exist_ok=True)

        long_text = " ".join(f"Sentence number {i} of the chapter." for i in range(600))
        chapter = Chapter(
            index=1,
            name="Retry Chapter",
            source_path="retry.html",
            text=long_text,
            speech_text=long_text,
        )

        reader = SimpleNamespace(
            title="Retry Book",
            file_path="retry.epub",
            get_chapter_structure=lambda preserve_all=True: [chapter],
        )

        class FlakyTTSEngine(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0
                self.voice = "retry-voice"

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                path = Path(output_path)
                path.parent.mkdir(parents=True, exist_ok=True)

                if self.calls == 1:
                    # Simulate a TTS failure so the retry logic is triggered
                    raise RuntimeError("Simulated TTS failure on first attempt")
                else:
                    # Succeed on retry
                    path.write_bytes(b"b" * 1_000_000)
                return path

        flaky_engine = FlakyTTSEngine()
        self.converter.tts_factory.create_engine = Mock(return_value=flaky_engine)

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 500_000)
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3

        config = ConversionConfig(
            engine="piper",
            output_dir=str(output_root),
            validate_audio=False,
            validate_text=False,
            book_title="Retry Book",
            extra={"max_auto_retries": 3},
            edge_auto_offline_chars=0,
            edge_auto_offline_seconds=0,
            force_reprocess=True,
        )

        result = await self.converter.convert(reader, config)

        self.assertTrue(
            result.success or len(result.output_files) > 0,
            "Conversion should eventually succeed after retry",
        )
        self.assertGreaterEqual(
            len(result.output_files), 1, "At least one output file should be produced"
        )
        self.assertGreaterEqual(
            flaky_engine.calls, 2, "Engine must be called at least twice (initial + retry)"
        )
        final_output = result.output_files[0]
        self.assertTrue(final_output.exists(), "Final MP3 should exist after conversion")
        self.assertGreater(
            final_output.stat().st_size, 1000, "Generated MP3 should have expected size"
        )

    async def test_edge_tts_receives_complete_chapter_content(self):
        """CRITICAL: Verify Edge TTS receives the COMPLETE chapter text, not truncated."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Complete_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Create a realistic chapter (equivalent to ~5 minutes of audio)
        # Average reading: 150 words/min, so 5 min = ~750 words
        realistic_chapter = " ".join(
            f"This is sentence number {i} with realistic content that makes sense. "
            for i in range(750)
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
            validate_audio=False,
            validate_text=False,
            book_title="Complete_Test",
            edge_auto_offline_chars=0,
            edge_auto_offline_seconds=0,
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

        normalize = lambda t: re.sub(r"\s+", " ", t or "").strip()

        normalized_original = normalize(realistic_chapter)
        normalized_tts_input = normalize(total_tts_input)

        # CRITICAL: TTS should receive 100% of the text
        original_word_count = len(normalized_original.split())
        tts_word_count = len(normalized_tts_input.split())

        self.assertGreaterEqual(
            tts_word_count,
            original_word_count * 0.99,  # Allow 1% tolerance for processing
            f"CRITICAL BUG: TTS only received {tts_word_count}/{original_word_count} words! "
            f"Missing {original_word_count - tts_word_count} words. This causes audio truncation.",
        )

        # Verify first and last sentences are present
        self.assertIn(
            "sentence number 0",
            normalized_tts_input,
            "First sentence missing - TTS input is truncated at start",
        )
        self.assertIn(
            "sentence number 749",
            normalized_tts_input,
            "Last sentence missing - TTS input is truncated at end",
        )
