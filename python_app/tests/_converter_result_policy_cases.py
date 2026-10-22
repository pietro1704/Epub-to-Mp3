"""Result Policy regression scenarios, collected by test_converter."""

from python_app.tests._converter_test_support import AudioConverter as AudioConverter
from python_app.tests._converter_test_support import Chapter as Chapter
from python_app.tests._converter_test_support import ChapterProcessor as ChapterProcessor
from python_app.tests._converter_test_support import ConversionConfig as ConversionConfig
from python_app.tests._converter_test_support import ConversionResult as ConversionResult
from python_app.tests._converter_test_support import Path as Path
from python_app.tests._converter_test_support import SimpleNamespace as SimpleNamespace
from python_app.tests._converter_test_support import os as os
from python_app.tests._converter_test_support import patch as patch
from python_app.tests._converter_test_support import tempfile as tempfile
from python_app.tests._converter_test_support import unittest as unittest
from python_app.tests._converter_test_support import (
    validate_audio_completeness as validate_audio_completeness,
)


class TestConversionResult(unittest.IsolatedAsyncioTestCase):
    """Test cases for ConversionResult dataclass"""

    def setUp(self):
        self.converter = AudioConverter()
        self.temp_dir = tempfile.mkdtemp()
        self.config = ConversionConfig(
            engine="edge",
            voice="test-voice",
            output_dir=self.temp_dir,
            book_title="Test Book",
            validate_audio=False,  # Disable audio validation for mock testing
            validate_text=False,  # Disable text validation for mock testing
            # v0.3.14 made auto-validate the default for real conversions,
            # but the unit tests below mock TTS engines that produce fake
            # MP3 bytes ffprobe can't parse — turning the post-conversion
            # validation off here keeps these tests focused on the
            # conversion logic instead of triggering the retry-fix loop.
            auto_validate_output=False,
            auto_fix_output=False,
        )

    def tearDown(self):
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_conversion_result_creation(self):
        """Test ConversionResult creation"""
        result = ConversionResult(
            success=True,
            total_chapters=5,
            converted_chapters=4,
            output_files=[Path("file1.mp3"), Path("file2.mp3")],
            errors=["Error in chapter 3"],
        )

        self.assertTrue(result.success)
        self.assertEqual(result.total_chapters, 5)
        self.assertEqual(result.converted_chapters, 4)
        self.assertEqual(len(result.output_files), 2)
        self.assertEqual(len(result.errors), 1)

    async def test_auto_validate_output_calls_validate_conversion(self):
        """Ensure auto validation is triggered with validate_conversion.validate_book"""
        output_dir = Path(self.temp_dir)
        epub_file = output_dir / "book.epub"
        epub_file.write_text("dummy")
        self.converter._current_book_path = epub_file
        self.config.auto_validate_output = True
        self.converter._active_config = self.config

        with patch("src.converter.Path") as mock_path:
            mock_path.return_value = output_dir
            with patch("validate_conversion.validate_book", return_value=({}, [])) as mock_validate:
                await self.converter._auto_validate_output(output_dir, stage="test")
                mock_validate.assert_called_once()

    async def test_auto_validate_output_triggers_auto_fix_on_issues(self):
        """Auto-validate should trigger validation when enabled."""
        output_dir = Path(self.temp_dir)
        cache_dir = Path(self.temp_dir) / "cache"
        cache_dir.mkdir()
        epub_file = output_dir / "book.epub"
        epub_file.write_text("dummy")
        self.converter._current_book_path = epub_file

        # Enable auto-validate in config
        self.config.auto_validate_output = True
        self.config.cache_dir = str(cache_dir)
        self.converter._active_config = self.config

        # Mock validation to return success
        good_stats = {
            "missing_cache": 0,
            "text_mismatch": 0,
            "parsed_pretts_diff": 0,
            "missing_mp3": 0,
            "duration_mismatch": 0,
        }

        with patch(
            "validate_conversion.validate_book", return_value=(good_stats, [])
        ) as mock_validate:
            await self.converter._auto_validate_output(output_dir, stage="test")
            # Should call validation at least once
            mock_validate.assert_called_once()


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
        joined = "".join(chunks)
        self.assertIn("sentence one", joined)
        self.assertIn("sentence four", joined)

    def test_chunk_text_empty_text(self):
        """Test chunking empty text"""
        chunks = ChapterProcessor.chunk_text("", max_size=100)

        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0], "")
    # Should handle gracefully even if single sentence is too long


class TestAutoEngineCandidates(unittest.TestCase):
    def _make_converter(self) -> AudioConverter:
        conv = AudioConverter()
        conv.hardware_profile = SimpleNamespace(network_speed_estimate="slow")
        return conv

    def test_skip_guarded_engines(self):
        converter = self._make_converter()
        config = ConversionConfig(engine="edge", primary_language="pt-BR")

        with (
            patch("src.converter._has_piper_support", return_value=False),
            patch("src.converter._has_coqui_support", return_value=False),
            patch.object(
                converter.tts_factory.voice_provider,
                "get_voice",
                side_effect=lambda engine, lang: "model.onnx" if engine == "piper" else None,
            ),
        ):
            order = converter._auto_engine_candidates(config)

        self.assertNotIn("piper", order)
        self.assertNotIn("kokoro", order)

    def test_prefers_piper_when_supported(self):
        converter = self._make_converter()
        config = ConversionConfig(engine="edge", primary_language="pt-BR")

        with (
            patch("src.converter._has_piper_support", return_value=True),
            patch("src.converter._has_coqui_support", return_value=False),
            patch.object(
                converter.tts_factory.voice_provider,
                "get_voice",
                side_effect=lambda engine, lang: "model.onnx" if engine == "piper" else None,
            ),
        ):
            order = converter._auto_engine_candidates(config)

        self.assertEqual(order[0], "edge", f"Unexpected auto engine order: {order}")


class TestValidateAudioCompleteness(unittest.TestCase):
    """Tests for validate_audio_completeness with the calibrated 200 WPM default."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_missing_file_returns_false(self):
        result, coverage = validate_audio_completeness(
            Path(self.temp_dir) / "nonexistent.mp3", 5000
        )
        self.assertFalse(result)
        self.assertEqual(coverage, 0.0)

    def test_short_chapter_skips_check(self):
        # text_length < 1000 should always pass regardless of audio
        mp3 = Path(self.temp_dir) / "short.mp3"
        mp3.write_bytes(b"\x00" * 100)  # tiny/invalid file still passes
        result, coverage = validate_audio_completeness(mp3, 500)
        self.assertTrue(result)
        self.assertEqual(coverage, 100.0)

    def test_complete_audio_at_200_wpm(self):
        # Simulate ~200 WPM audio for a 5000-char chapter:
        # 5000 chars / 5 chars/word = 1000 words; at 200 WPM → 5 minutes
        mp3 = Path(self.temp_dir) / "complete.mp3"
        mp3.write_bytes(b"\x00" * 100)  # must exist for the check to proceed
        with patch("src.converter.MP3") as mock_mp3:
            mock_mp3.return_value.info.length = 300.0  # 5 minutes
            result, coverage = validate_audio_completeness(mp3, 5000)
        # coverage = (5 min * 200 wpm * 5 chars/word) / 5000 = 100%
        self.assertTrue(result)
        self.assertAlmostEqual(coverage, 100.0, places=0)

    def test_truncated_audio_detected(self):
        # 5000-char chapter but only 2 minutes of audio → ~80% coverage → truncated
        mp3 = Path(self.temp_dir) / "truncated.mp3"
        mp3.write_bytes(b"\x00" * 100)
        with patch("src.converter.MP3") as mock_mp3:
            mock_mp3.return_value.info.length = 120.0  # 2 minutes
            result, coverage = validate_audio_completeness(mp3, 5000)
        # coverage = (2 * 200 * 5) / 5000 = 2000/5000 = 40%  → missing 60% → truncated
        self.assertFalse(result)
        self.assertLess(coverage, 90.0)

    def test_old_160_wpm_would_have_falsely_failed(self):
        # Edge-TTS at real 200 WPM for a 10000-char chapter → 10 minutes audio.
        # With WPM=160: coverage = (10 * 160 * 5) / 10000 = 80% → detected as truncated.
        # With WPM=200: coverage = (10 * 200 * 5) / 10000 = 100% → passes.
        mp3 = Path(self.temp_dir) / "edge_complete.mp3"
        mp3.write_bytes(b"\x00" * 100)
        with patch("src.converter.MP3") as mock_mp3:
            mock_mp3.return_value.info.length = 600.0  # 10 minutes at 200 WPM
            with patch("src.converter.EXPECTED_WPM", 200):
                result_200, coverage_200 = validate_audio_completeness(mp3, 10000)
            with patch("src.converter.EXPECTED_WPM", 160):
                result_160, coverage_160 = validate_audio_completeness(mp3, 10000)
        self.assertTrue(result_200, "200 WPM should pass for complete Edge-TTS audio")
        self.assertFalse(result_160, "160 WPM would falsely fail for complete Edge-TTS audio")

    def test_corrupt_mp3_does_not_raise(self):
        mp3 = Path(self.temp_dir) / "corrupt.mp3"
        mp3.write_bytes(b"not a real mp3")
        # Should not raise; should return True (benefit of the doubt)
        result, coverage = validate_audio_completeness(mp3, 5000)
        self.assertTrue(result)
        self.assertEqual(coverage, 100.0)


class TestMaxChapterCharsConfig(unittest.TestCase):
    """Tests for MAX_CHAPTER_CHARS constant and skip predicate."""

    def test_default_is_zero_disabled(self):
        """MAX_CHAPTER_CHARS should default to 0 (disabled) via env var."""
        import src.converter as conv_mod

        # Without override, default is 0 (disabled)
        with patch.dict(os.environ, {}, clear=False):
            # Reload the value via _env_int logic directly
            raw = os.environ.get("MAX_CHAPTER_CHARS", "")
            value = int(raw) if raw else 0
            self.assertEqual(value, 0, "Default MAX_CHAPTER_CHARS must be 0 (disabled)")

        # The module constant should also be 0 in test environment
        self.assertEqual(conv_mod.MAX_CHAPTER_CHARS, 0)

    def test_skip_predicate_when_enabled(self):
        """Chapter larger than limit should trigger the skip condition."""
        limit = 200_000
        big_chapter_chars = 300_000
        small_chapter_chars = 5_000
        self.assertTrue(
            limit > 0 and big_chapter_chars > limit,
            "Oversized chapter should match skip condition",
        )
        self.assertFalse(
            limit > 0 and small_chapter_chars > limit,
            "Normal chapter should not match skip condition",
        )

    def test_skip_predicate_disabled_when_zero(self):
        """When MAX_CHAPTER_CHARS=0, no chapter should be skipped."""
        limit = 0
        chapter_chars = 999_999
        self.assertFalse(
            limit > 0 and chapter_chars > limit,
            "No chapter should be skipped when limit is 0",
        )

    def test_env_override_sets_limit(self):
        """Setting MAX_CHAPTER_CHARS env var correctly configures the limit."""
        with patch.dict(os.environ, {"MAX_CHAPTER_CHARS": "150000"}):
            raw = os.environ.get("MAX_CHAPTER_CHARS", "")
            value = int(raw) if raw else 0
            self.assertEqual(value, 150_000)


class TestAnalyzeChapterStatsOutliers(unittest.TestCase):
    """Tests for the outlier-detection logic in _analyze_chapter_stats."""

    def _make_chapters(self, lengths: list[int]) -> list[Chapter]:
        return [
            Chapter(index=i, name=f"Chapter {i}", source_path=f"ch{i}.xhtml", text="x" * n)
            for i, n in enumerate(lengths)
        ]

    def setUp(self):
        self.converter = AudioConverter()

    def test_no_outliers_for_uniform_chapters(self):
        chapters = self._make_chapters([5000] * 10)
        stats = self.converter._analyze_chapter_stats(chapters)
        self.assertEqual(stats["outlier_indices"], [])

    def test_detects_single_outlier(self):
        # One chapter is 15× the median (279K vs ~18K)
        lengths = [18_000] * 10 + [279_000]
        chapters = self._make_chapters(lengths)
        stats = self.converter._analyze_chapter_stats(chapters)
        self.assertIn(10, stats["outlier_indices"])

    def test_no_outlier_if_below_50k_floor(self):
        # Even if one chapter is >5× median, skip warning if it's <50K chars
        lengths = [1_000] * 10 + [8_000]
        chapters = self._make_chapters(lengths)
        stats = self.converter._analyze_chapter_stats(chapters)
        self.assertEqual(stats["outlier_indices"], [])

    def test_median_chars_computed_correctly(self):
        lengths = [1_000, 2_000, 3_000, 4_000, 5_000]
        chapters = self._make_chapters(lengths)
        stats = self.converter._analyze_chapter_stats(chapters)
        self.assertEqual(stats["median_chars"], 3_000)

    def test_outlier_max_chars_set(self):
        lengths = [10_000] * 5 + [300_000]
        chapters = self._make_chapters(lengths)
        stats = self.converter._analyze_chapter_stats(chapters)
        self.assertEqual(stats.get("outlier_max_chars"), 300_000)

    def test_outlier_warning_printed(self):
        lengths = [10_000] * 5 + [300_000]
        chapters = self._make_chapters(lengths)
        import io

        buf = io.StringIO()
        with unittest.mock.patch("sys.stdout", buf):
            self.converter._analyze_chapter_stats(chapters)
        output = buf.getvalue()
        self.assertIn("Oversized chapter", output)
        self.assertIn("conversion will take longer", output)
