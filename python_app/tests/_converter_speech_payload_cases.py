"""Speech payload scenarios sharing the original unittest fixture."""

from python_app.tests._converter_test_support import Chapter as Chapter
from python_app.tests._converter_test_support import ConversionConfig as ConversionConfig
from python_app.tests._converter_test_support import Path as Path


class SpeechPayloadCases:
    async def test_prepare_payload_preserves_structural_heading_pauses(self):
        """_prepare_payload must NOT discard '...' pauses added by apply_structural_speech_cues.

        Regression: previously it re-called to_audible_text with original
        formatting_segments, which reconstructed text from raw HTML and silently
        dropped the heading pauses written by the parser.
        """
        cache_dir = Path(self.temp_dir) / ".cache" / "HeadingPause_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Simulate a chapter whose speech_text was already prepared by
        # _prepare_speech_text: heading lines have trailing "..." for TTS pauses.
        prepared_speech = (
            "Capítulo 4...\nBen Hanscom sofre uma queda...\nPor volta das 23h45, o avião"
        )
        # The original formatting_segments that would have come from HTML parsing.
        # These do NOT contain the "..." — they reflect the raw parsed text.
        from src.text_formatting import FormattingSegment

        raw_segments = [
            FormattingSegment(text="Capítulo 4\n", formatting=""),
            FormattingSegment(text="Ben Hanscom sofre uma queda\n", formatting=""),
            FormattingSegment(text="Por volta das 23h45, o avião", formatting=""),
        ]

        chapter = Chapter(
            index=1,
            name="Capítulo 4 – Ben Hanscom sofre uma queda",
            source_path="ch.html",
            text="Capítulo 4\nBen Hanscom sofre uma queda\nPor volta das 23h45, o avião",
            speech_text=prepared_speech,
            formatting_segments=raw_segments,
        )

        class NoOpEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

            last_error = None
            last_segment_report = None
            partial_failure_detected = False

            def get_synthesis_tracker(self):
                return None

        engine = NoOpEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="HeadingPause_Test",
        )

        await self.converter._convert_chapters_sequential([chapter], engine, cache_dir, config)

        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1)
        content = pre_tts_files[0].read_text(encoding="utf-8")

        # The heading pauses must survive into the pre-TTS file
        self.assertIn(
            "Capítulo 4...",
            content,
            "Structural heading pause '...' must be preserved in pre-tts.txt",
        )
        self.assertIn(
            "Ben Hanscom sofre uma queda...",
            content,
            "Subtitle heading pause '...' must be preserved in pre-tts.txt",
        )
        # Body text must follow immediately after the last heading (no merging)
        self.assertIn("Por volta das 23h45", content)

    async def test_prepare_payload_converts_fmt_markers_in_speech_text(self):
        """When speech_text still has [[fmt:]] markers, they must be converted to audible
        cues — not silently stripped — in the written pre-TTS file."""
        cache_dir = Path(self.temp_dir) / ".cache" / "FmtMarker_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        chapter = Chapter(
            index=1,
            name="Fmt Marker Chapter",
            source_path="ch.html",
            text="Original text",
            speech_text="Normal. [[fmt:italic]]Italic here[[/fmt]] done.",
        )

        class NoOpEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

            last_error = None
            last_segment_report = None
            partial_failure_detected = False

            def get_synthesis_tracker(self):
                return None

        engine = NoOpEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="FmtMarker_Test",
        )

        await self.converter._convert_chapters_sequential([chapter], engine, cache_dir, config)

        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1)
        content = pre_tts_files[0].read_text(encoding="utf-8")

        # Markers must be converted, not left raw
        self.assertNotIn("[[fmt:", content, "[[fmt:]] markers must not appear in pre-tts.txt")
        # Audible cue must be present
        self.assertIn("em itálico", content, "Italic marker must produce an audible cue")

    async def test_prepare_payload_falls_back_when_speech_text_is_none(self):
        """When speech_text is None, _prepare_payload falls back to processing chapter.text
        via the full formatting pipeline (original formatting_segments path)."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Fallback_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        from src.text_formatting import FormattingSegment

        raw_text = "Normal. [[fmt:bold]]Bold here[[/fmt]] done."
        raw_segments = [
            FormattingSegment(text="Normal. ", formatting=""),
            FormattingSegment(text="Bold here", formatting="bold"),
            FormattingSegment(text=" done.", formatting=""),
        ]

        chapter = Chapter(
            index=1,
            name="Fallback Chapter",
            source_path="ch.html",
            text=raw_text,
            speech_text=None,  # not set — triggers fallback path
            formatting_segments=raw_segments,
        )

        class NoOpEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 400)
                return output_path

            last_error = None
            last_segment_report = None
            partial_failure_detected = False

            def get_synthesis_tracker(self):
                return None

        engine = NoOpEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Fallback_Test",
        )

        await self.converter._convert_chapters_sequential([chapter], engine, cache_dir, config)

        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1)
        content = pre_tts_files[0].read_text(encoding="utf-8")

        # Fallback should still convert markers via segments
        self.assertNotIn("[[fmt:", content)
        self.assertIn("em negrito", content, "Bold marker must produce audible cue via fallback")
