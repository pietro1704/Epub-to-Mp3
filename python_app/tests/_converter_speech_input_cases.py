"""Speech input scenarios sharing the original unittest fixture."""

from python_app.tests._converter_test_support import Chapter as Chapter
from python_app.tests._converter_test_support import ConversionConfig as ConversionConfig
from python_app.tests._converter_test_support import Path as Path
from python_app.tests._converter_test_support import (
    TextFormattingProcessor as TextFormattingProcessor,
)
from python_app.tests._converter_test_support import re as re


class SpeechInputCases:
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
            validate_audio=False,
            validate_text=False,
            book_title="Long_Book",
            edge_auto_offline_chars=0,
            edge_auto_offline_seconds=0,
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
            speech_text=multilingual_text,  # pre-TTS text with tags
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
            validate_audio=False,
            validate_text=False,
            book_title="Multilingual_Test",
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
        self.assertEqual(
            parse_content, chapter.text, "parsed.txt should contain original chapter.text"
        )

        # Verify pre-tts.txt = speech_text (with [[lang:]] tags)
        # Normalize whitespace for comparison (clean_tts_text normalizes spaces)
        import re

        normalize = lambda t: re.sub(r"\s+", " ", t or "").strip()
        self.assertEqual(
            normalize(pre_tts_content),
            normalize(chapter.speech_text),
            "pre-tts.txt should contain speech_text with [[lang:]] tags",
        )

        # Verify language tags are preserved in pre-tts.txt
        self.assertIn("[[lang:pt-BR]]", pre_tts_content, "[[lang:pt-BR]] tag should be preserved")
        self.assertIn("[[lang:es]]", pre_tts_content, "[[lang:es]] tag should be preserved")
        self.assertIn("[[/lang]]", pre_tts_content, "Closing [[/lang]] tags should be preserved")

        # Verify language tags are NOT in parsed.txt
        self.assertNotIn("[[lang:", parse_content, "parsed.txt should not contain [[lang:]] tags")

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
            speech_text=emphasized_text,  # Speech text BEFORE formatting processor
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
            validate_audio=False,
            validate_text=False,
            book_title="Emphasis_Test",
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
        self.assertIn(
            "em itálico:", pre_tts_content, "Italic sections should produce an audible cue"
        )
        self.assertIn("em negrito:", pre_tts_content, "Bold sections should produce an audible cue")
        self.assertIn(
            "entre aspas:", pre_tts_content, "Quoted sections should announce quotation marks"
        )

        # Ensure original [[fmt:]] markers and SSML are removed
        self.assertNotIn(
            "[[fmt:", pre_tts_content, "Formatting markers must not leak to the final TTS text"
        )
        self.assertNotIn(
            "<speak", pre_tts_content.lower(), "SSML should not appear in the text sent to Piper"
        )

        # **CRITICAL**: Verify pre-tts.txt matches EXACTLY what TTS received
        self.assertEqual(len(tts_received), 1, "TTS should be called once")
        import re

        normalize = lambda t: re.sub(r"\s+", " ", t or "").strip()

        self.assertEqual(
            normalize(pre_tts_content),
            normalize(tts_received[0]),
            "CRITICAL: pre-tts.txt must EXACTLY match what TTS received (including audible cues)",
        )

    async def test_pre_tts_file_matches_tts_input_exactly(self):
        """CRITICAL TEST: Verify pre-tts.txt contains EXACTLY what TTS receives, byte-by-byte."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Exact_Match_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Chapter with formatting that will be processed
        chapter_text = (
            "Normal text. [[fmt:italic]]Italic text[[/fmt]] and [[fmt:bold]]bold text[[/fmt]]."
        )

        chapter = Chapter(
            index=1,
            name="Exact Match Chapter",
            source_path="ch1.html",
            text="Original parsed text",
            speech_text=chapter_text,
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
            validate_audio=False,
            validate_text=False,
            book_title="Exact_Match_Test",
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
            f"TTS Input ({len(tts_input)} chars): {tts_input[:200]}...",
        )

        # Verify audible cues are present in BOTH
        if "[[fmt:" in chapter_text:
            self.assertIn("em itálico:", cached_text, "Audible cues should be in pre-tts.txt")
            self.assertIn("em itálico:", tts_input, "Audible cues should be in TTS input")

            # And original markers should be GONE from both
            self.assertNotIn("[[fmt:", cached_text, "Markers should not be in pre-tts.txt")
            self.assertNotIn("[[fmt:", tts_input, "Markers should not be in TTS input")
