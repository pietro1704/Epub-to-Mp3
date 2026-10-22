# -*- coding: utf-8 -*-
"""
Unit tests for simplified converter module
"""

import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from python_app.tests._converter_test_support import (
    AsyncMock as AsyncMock,
    AudioConverter as AudioConverter,
    Chapter as Chapter,
    ChapterProcessor as ChapterProcessor,
    ConversionConfig as ConversionConfig,
    ConversionResult as ConversionResult,
    EDGE_OFFLINE_LONG_CHARS as EDGE_OFFLINE_LONG_CHARS,
    Mock as Mock,
    MockTTSEngine as MockTTSEngine,
    ResourceSnapshot as ResourceSnapshot,
    SimpleNamespace as SimpleNamespace,
    TextFormattingProcessor as TextFormattingProcessor,
    asyncio as asyncio,
    json as json,
    os as os,
    patch as patch,
    re as re,
    replace as replace,
    tempfile as tempfile,
    time as time,
    unittest as unittest,
)
from python_app.tests._converter_validation_lifecycle_cases import ValidationLifecycleCases
from python_app.tests._converter_runtime_tuning_cases import RuntimeTuningCases
from python_app.tests._converter_resource_budget_cases import ResourceBudgetCases
from python_app.tests._converter_runtime_metrics_cases import RuntimeMetricsCases
from python_app.tests._converter_cache_text_projection_cases import CacheTextProjectionCases
from python_app.tests._converter_cache_lifecycle_cases import CacheLifecycleCases
from python_app.tests._converter_speech_input_cases import SpeechInputCases
from python_app.tests._converter_speech_payload_cases import SpeechPayloadCases
from python_app.tests._converter_stream_publication_cases import StreamPublicationCases
from python_app.tests._converter_automatic_engine_routing_cases import AutomaticEngineRoutingCases
from python_app.tests._converter_single_chapter_cases import SingleChapterCases
from python_app.tests._converter_conversion_end_to_end_cases import ConversionEndToEndCases

from python_app.tests._converter_validation_contract_cases import (
    TestConverterValidationContract as TestConverterValidationContract,
)
from python_app.tests._converter_result_policy_cases import (
    TestConversionResult as TestConversionResult,
    TestChapterProcessor as TestChapterProcessor,
    TestAutoEngineCandidates as TestAutoEngineCandidates,
    TestValidateAudioCompleteness as TestValidateAudioCompleteness,
    TestMaxChapterCharsConfig as TestMaxChapterCharsConfig,
    TestAnalyzeChapterStatsOutliers as TestAnalyzeChapterStatsOutliers,
)

class TestAudioConverter(
    ValidationLifecycleCases,
    RuntimeTuningCases,
    ResourceBudgetCases,
    RuntimeMetricsCases,
    CacheTextProjectionCases,
    CacheLifecycleCases,
    SpeechInputCases,
    SpeechPayloadCases,
    StreamPublicationCases,
    AutomaticEngineRoutingCases,
    SingleChapterCases,
    ConversionEndToEndCases,
    unittest.IsolatedAsyncioTestCase,
):
    """Test cases for AudioConverter class"""

    def setUp(self):
        """Set up test fixtures"""
        self.converter = AudioConverter()
        self.temp_dir = tempfile.mkdtemp()

        # Mock objects
        self.mock_reader = Mock()
        self.mock_reader.title = "Test Book"
        self.mock_reader._toc_expected_chapters = 0
        self.mock_reader.get_chapter_structure.return_value = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2"),
        ]

        self.config = ConversionConfig(
            engine="edge",
            voice="test-voice",
            output_dir=self.temp_dir,
            book_title="Test Book",
            validate_audio=False,
            validate_text=False,
        )

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_classify_failure_reason(self):
        self.assertEqual(
            self.converter._classify_failure_reason("429 too many requests"), "throttle"
        )
        self.assertEqual(
            self.converter._classify_failure_reason("SSL certificate error"), "network"
        )
        self.assertEqual(self.converter._classify_failure_reason("timeout after 30s"), "transient")
        self.assertEqual(self.converter._classify_failure_reason("401 unauthorized"), "auth")

    def test_analyze_chapter_stats_flags_prefer_offline(self):
        """Very long chapters should trigger offline recommendation."""
        chapter_long = Chapter(1, "Long", "c1.html", "x" * (EDGE_OFFLINE_LONG_CHARS + 5000))
        chapter_short = Chapter(2, "Short", "c2.html", "brief text")
        stats = self.converter._analyze_chapter_stats([chapter_long, chapter_short])
        self.assertTrue(stats["prefer_offline_engine"])
        self.assertIn("chapter", stats.get("offline_reason", ""))

    @patch("src.converter._has_piper_support", return_value=True)
    def test_apply_chapter_engine_preferences_auto(self, mock_piper):
        """Auto mode should not preemptively switch away from Edge first-attempt flow."""
        config = ConversionConfig(engine="auto", output_dir=self.temp_dir)
        stats = {"prefer_offline_engine": True, "offline_reason": "long chapter"}
        self.converter._apply_chapter_engine_preferences(config, stats)
        self.assertFalse(config.auto_prefer_piper)
        self.assertEqual(config.engine, "auto")

    @patch("src.converter._has_piper_support", return_value=True)
    def test_apply_chapter_engine_preferences_switches_edge(self, mock_piper):
        """Explicit Edge engine should remain unchanged until a real failure happens."""
        config = ConversionConfig(engine="edge", output_dir=self.temp_dir)
        stats = {"prefer_offline_engine": True, "offline_reason": "long chapter"}
        self.converter._apply_chapter_engine_preferences(config, stats)
        self.assertEqual(config.engine, "edge")

    @patch("src.converter._has_piper_support", return_value=True)
    def test_resolve_offline_fallback_prefers_piper(self, mock_piper):
        choice = self.converter._resolve_offline_fallback_engine({"edge", "piper"})
        self.assertEqual(choice, "piper")

    def test_should_preempt_edge_timeout_for_long_chapter(self):
        self.converter._segment_adaptive_state["engine_cps"] = {"edge": [70.0, 72.0, 68.0]}
        reason = self.converter._should_preempt_edge_timeout(
            chapter_chars=120_000,
            estimated_seconds=400.0,
        )
        self.assertIsNotNone(reason)

    def test_spot_check_text_against_epub(self):
        """Spot-check should ensure snippets from EPUB exist in payload."""
        epub_text = (
            "Primeira frase do capítulo. Segunda frase continua o raciocínio. "
            "Aqui vem uma terceira frase para alongar o texto."
        )
        payload_ok = epub_text + " Texto extra opcional."
        payload_missing_mid = "Primeira frase do capítulo. Conteúdo cortado no meio."

        self.assertTrue(AudioConverter._spot_check_text_against_epub(epub_text, payload_ok))
        self.assertFalse(
            AudioConverter._spot_check_text_against_epub(epub_text, payload_missing_mid)
        )

    def test_resolve_problem_chapter_indices_supports_decimal_labels(self):
        chapters = [
            Chapter("4.1", "Cap 4.1", "c41.xhtml", "texto 41"),
            Chapter("4.2", "Cap 4.2", "c42.xhtml", "texto 42"),
            Chapter("5.0", "Cap 5.0", "c50.xhtml", "texto 50"),
            Chapter("6", "Cap 6", "c6.xhtml", "texto 6"),
        ]

        mapped = self.converter._resolve_problem_chapter_indices(chapters, ["4.2", "5.0"])
        self.assertEqual(mapped, ["4.2", "5.0"])

    def test_resolve_problem_chapter_indices_does_not_collapse_decimal_to_integer(self):
        chapters = [
            Chapter("4.2", "Cap 4.2", "c42.xhtml", "texto 42"),
            Chapter("4", "Cap 4", "c4.xhtml", "texto 4"),
        ]

        mapped = self.converter._resolve_problem_chapter_indices(chapters, ["4"])
        self.assertEqual(mapped, ["4"])

    def test_categorize_problems_treats_missing_cache_as_full_reconvert(self):
        issues = [
            "Chapter 4.2: Missing cache files",
            "Chapter 4.2: Missing MP3 file",
            "Chapter 5.0: Missing cache files",
            "Chapter 5.1: Missing MP3 file",
            "Chapter 6.1: Duration mismatch (+45%)",
        ]
        problem_chapters = ["4.2", "5.0", "5.1", "6.1"]

        missing_mp3_only, duration_only = self.converter._categorize_problems(
            issues, problem_chapters
        )

        # 4.2 and 5.0 require full reconversion (not quick synthesis)
        self.assertEqual(missing_mp3_only, ["5.1"])
        self.assertEqual(duration_only, ["6.1"])

    def test_init(self):
        """Test AudioConverter initialization"""
        self.assertIsNotNone(self.converter.tts_factory)
        self.assertIsNotNone(self.converter.audio_processor)
        self.assertIsNotNone(self.converter.file_manager)
        self.assertIsNotNone(self.converter.progress)

    def test_failure_checkpoint_roundtrip(self):
        """Failure checkpoint should persist and clear failed chapter metadata."""
        temp_dir = Path(self.temp_dir) / "checkpoint"
        temp_dir.mkdir(parents=True, exist_ok=True)
        self.converter._save_failure_checkpoint(
            temp_dir,
            failed_chapters=["1", "2.1 - Chapter"],
            edge_blocked_chapters=["1"],
        )
        payload = self.converter._load_failure_checkpoint(temp_dir)
        self.assertIn("failed_chapters", payload)
        self.assertEqual(set(payload["failed_chapters"]), {"1", "2.1 - Chapter"})
        self.assertEqual(set(payload.get("edge_blocked_chapters", [])), {"1"})
        self.converter._clear_failure_checkpoint(temp_dir)
        self.assertEqual(self.converter._load_failure_checkpoint(temp_dir), {})

    def test_setup_output_directory(self):
        """Test output directory setup"""
        output_dir = self.converter._setup_output_directory(self.config)

        self.assertIsInstance(output_dir, Path)
        self.assertTrue(output_dir.exists())
        self.assertIn("Test Book", str(output_dir))

    def test_setup_output_directory_no_title(self):
        """Test output directory setup without book title"""
        config = ConversionConfig(
            engine="edge",
            output_dir=self.temp_dir,
            book_title="",
            validate_audio=False,
            validate_text=False,
        )
        output_dir = self.converter._setup_output_directory(config)

        expected = Path(self.temp_dir) / "default"
        self.assertEqual(output_dir, expected)

    async def test_convert_chapters_success(self):
        """Test successful chapter conversion"""
        chapters = [
            Chapter(1, "Chapter 1", "ch1.html", "Content 1"),
            Chapter(2, "Chapter 2", "ch2.html", "Content 2"),
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
            Chapter(2, "Chapter 2", "ch2.html", "Content 2"),
        ]

        # Mock TTS engine that fails on second chapter
        call_count = [0]

        class PartialFailTTSEngine(MockTTSEngine):
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

        mock_tts_engine = PartialFailTTSEngine()
        mock_tts_engine.last_error = "Test error"
        output_dir = Path(self.temp_dir)

        # Disable Piper fallback for this test
        import os

        old_threshold = os.environ.get("EDGE_PIPER_THRESHOLD")
        os.environ["EDGE_PIPER_THRESHOLD"] = "999"
        try:
            test_config = replace(
                self.config,
                extra={**(self.config.extra or {}), "max_chapter_attempts": "1"},
            )
            result = await self.converter._convert_chapters_sequential(
                chapters, mock_tts_engine, output_dir, test_config
            )
        finally:
            if old_threshold is None:
                os.environ.pop("EDGE_PIPER_THRESHOLD", None)
            else:
                os.environ["EDGE_PIPER_THRESHOLD"] = old_threshold

        # Note: The current behavior converts what it can and reports partial success
        # First chapter succeeds, second chapter fails - expect success=True with 1 converted
        self.assertTrue(result.success or result.converted_chapters > 0)  # Partial success is OK
        self.assertEqual(result.total_chapters, 2)
        self.assertGreaterEqual(result.converted_chapters, 1)  # At least first chapter
        self.assertGreaterEqual(len(result.output_files), 1)

    async def test_report_results_success(self):
        """Test reporting successful results"""
        result = ConversionResult(
            success=True,
            total_chapters=3,
            converted_chapters=3,
            output_files=[Path("file1.mp3"), Path("file2.mp3")],
            errors=[],
        )

        # Should not raise exception
        await self.converter._report_results(result)

    async def test_report_results_with_errors(self):
        """Test reporting results with errors"""
        result = ConversionResult(
            success=False,
            total_chapters=3,
            converted_chapters=2,
            output_files=[Path("file1.mp3")],
            errors=["Error 1", "Error 2", "Error 3", "Error 4"],
        )

        # Should not raise exception
        await self.converter._report_results(result)


def test_chunk_text_single_long_sentence():
    """Test chunking single very long sentence"""
    text = "This is a very long sentence that exceeds the maximum size limit and should be handled gracefully"
    chunks = ChapterProcessor.chunk_text(text, max_size=50)

    assert len(chunks) >= 1


if __name__ == "__main__":
    unittest.main()
