"""Cache lifecycle scenarios sharing the original unittest fixture."""

from python_app.tests._converter_test_support import (
    Chapter as Chapter,
    ConversionConfig as ConversionConfig,
    MockTTSEngine as MockTTSEngine,
    Path as Path,
)

class CacheLifecycleCases:
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
            speech_text="English text [[lang:pt-BR]]Texto em português[[/lang]] more English",
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
            validate_audio=False,
            validate_text=False,
            book_title="Test Book",
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
        self.assertEqual(
            cached_text,
            actual_tts_input,
            "CRITICAL: Cached text must EXACTLY match what was sent to TTS engine",
        )

        # Verify language tags are preserved
        if "[[lang:pt-BR]]" in actual_tts_input:
            self.assertIn(
                "[[lang:pt-BR]]",
                cached_text,
                "Language tags in TTS input must appear in cached text",
            )

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
            speech_text="Processed [[lang:pt-BR]]speech text[[/lang]] for TTS",
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
            book_title="Integration_Test",
            validate_audio=False,
            validate_text=False,
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
        self.assertEqual(
            parse_content, chapter.text, "parsed.txt should contain original chapter.text"
        )

        # Verify pre-tts.txt = speech_text (what was sent to TTS)
        self.assertEqual(
            pre_tts_content, chapter.speech_text, "pre-tts.txt should contain speech_text"
        )
        self.assertEqual(
            pre_tts_content,
            tracking_engine.received_text,
            "pre-tts.txt should match what TTS received",
        )

        # parsed.txt should be different (in this case)
        self.assertNotEqual(
            parse_content,
            pre_tts_content,
            "parsed.txt should differ from pre-tts when text != speech_text",
        )

    async def test_cache_invalidation_without_txt_files(self):
        """Test that MP3 files are deleted and reconverted when .txt cache is missing"""
        cache_dir = Path(self.temp_dir) / ".cache" / "Cache_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        chapter = Chapter(
            index=1,
            name="Cache Test Chapter",
            source_path="ch1.html",
            text="Test text",
            speech_text="Test speech text",
        )

        # Track TTS calls
        tts_call_count = [0]

        class CountingTTSEngine(MockTTSEngine):
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
            validate_audio=False,
            validate_text=False,
            book_title="Cache_Test",
            # Skip silence padding — the post-v0.3.13 default `intro=300ms`
            # would invoke real ffmpeg here and rewrite the mock MP3 data
            # into something whose size no longer matches the estimator,
            # which is irrelevant to what this test exercises (cache hit).
            chapter_intro_silence_ms=0,
            chapter_outro_silence_ms=0,
        )

        # First conversion
        result1 = await self.converter._convert_chapters_sequential(
            [chapter], engine, cache_dir, config
        )
        self.assertEqual(result1.converted_chapters, 1)
        self.assertEqual(tts_call_count[0], 1, "First conversion should call TTS")

        # Verify files were created
        text_dir = cache_dir / "text"
        mp3_file = cache_dir / "1 - Cache Test Chapter.mp3"

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
        self.assertEqual(
            tts_call_count[0], 1, "Third conversion should call TTS (cache invalidated)"
        )

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
            speech_text="Processed text [[lang:pt-BR]]WITH TAGS[[/lang]]",  # Sent to TTS
        )

        # Track exactly what Edge TTS receives
        tts_received_inputs = []

        class SpyTTSEngine:
            """TTS engine that spies on its inputs"""

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                # Record EXACTLY what we receive
                tts_received_inputs.append(
                    {
                        "text": text,
                        "formatting_segments": formatting_segments,
                    }
                )

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
            validate_audio=False,
            validate_text=False,
            book_title="Messias",
        )

        result = await self.converter._convert_chapters_sequential(
            [chapter], spy_engine, cache_dir, config
        )

        # Verify conversion completed
        self.assertEqual(result.converted_chapters, 1)
        self.assertEqual(len(tts_received_inputs), 1)

        # What was sent to TTS
        tts_input_text = tts_received_inputs[0]["text"]

        # What was cached (NEW FORMAT: -pre-tts.txt)
        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1, "Should have one pre-tts.txt file")

        cached_text = pre_tts_files[0].read_text(encoding="utf-8")

        # REPRODUCE BUG CHECK:
        # If cached_text lacks tags but tts_input_text has them, we have the bug!
        has_bug = "[[lang:" not in cached_text and "[[lang:" in tts_input_text

        self.assertFalse(
            has_bug,
            f"BUG DETECTED: Cached text lacks language tags that were sent to TTS!\n"
            f"Cached: {cached_text[:100]}\n"
            f"TTS Input: {tts_input_text[:100]}",
        )

        self.assertNotIn(
            "<speak", tts_input_text.lower(), "SSML tags must never reach the TTS engine input"
        )
        self.assertNotIn(
            "[[fmt:", tts_input_text, "Formatting markers must be stripped before synthesis"
        )

        # CORRECT BEHAVIOR: they must match exactly
        self.assertEqual(
            cached_text,
            tts_input_text,
            "Cached text must exactly match TTS input (fixing Messias de Duna bug)",
        )
