"""Validation lifecycle scenarios sharing the original unittest fixture."""

from python_app.tests._converter_test_support import AsyncMock as AsyncMock
from python_app.tests._converter_test_support import Chapter as Chapter
from python_app.tests._converter_test_support import ConversionConfig as ConversionConfig
from python_app.tests._converter_test_support import ConversionResult as ConversionResult
from python_app.tests._converter_test_support import Path as Path


class ValidationLifecycleCases:
    def test_initial_validation_is_deferred_when_output_audio_exists(self):
        output_dir = Path(self.temp_dir)
        (output_dir / "1 - chapter.mp3").write_bytes(b"audio")
        config = ConversionConfig(engine="edge", output_dir=output_dir)

        self.assertFalse(self.converter._should_run_initial_validation(output_dir, config))

    def test_initial_validation_is_deferred_when_cached_audio_exists(self):
        output_dir = Path(self.temp_dir)
        cache_dir = output_dir / "cache"
        cache_dir.mkdir()
        (cache_dir / "1 - chapter.mp3").write_bytes(b"audio")
        config = ConversionConfig(engine="edge", output_dir=output_dir, cache_dir=cache_dir)

        self.assertFalse(self.converter._should_run_initial_validation(output_dir, config))

    def test_initial_validation_remains_enabled_for_new_conversion(self):
        output_dir = Path(self.temp_dir)
        config = ConversionConfig(engine="edge", output_dir=output_dir)

        self.assertTrue(self.converter._should_run_initial_validation(output_dir, config))

    async def test_report_results_surfaces_validation_stats_breakdown_on_failure(self):
        """Final-validation failure must explain *why* in result.errors, not
        just flip success=False — a run that converts every chapter
        (chapters_failed=0) but fails the post-hoc cross-validation
        previously logged as outcome=partial with no way to tell which
        validate_book bucket (duration_mismatch, missing_mp3, ...) caused
        it. See LOTR 2026-07-16 session (95/95 converted, outcome=partial)."""
        output_dir = Path(self.temp_dir)
        self.converter._last_output_dir = output_dir
        self.converter._active_config = self.config
        self.converter._last_chapters_for_text = []
        self.converter._auto_validate_output = AsyncMock(return_value=False)
        self.converter._last_validation_stats = {
            "total_chapters": 95,
            "perfect": 92,
            "duration_mismatch": 2,
            "missing_mp3": 1,
        }

        result = ConversionResult(
            success=True,
            total_chapters=95,
            converted_chapters=95,
            output_files=[],
            errors=[],
        )

        await self.converter._report_results(result)

        self.assertFalse(result.success)
        self.assertEqual(len(result.errors), 1)
        self.assertIn("duration_mismatch=2", result.errors[0])
        self.assertIn("missing_mp3=1", result.errors[0])
        self.assertNotIn("perfect=", result.errors[0])
        self.assertNotIn("total_chapters=", result.errors[0])

    def test_duplicate_cleanup_is_opt_in(self):
        config = ConversionConfig(engine="edge")

        self.assertFalse(self.converter._duplicate_cleanup_enabled(config))
        config.cleanup_duplicate_files = True
        self.assertTrue(self.converter._duplicate_cleanup_enabled(config))

    def test_split_cached_chapters_respects_force_reprocess(self):
        """Force reprocess should ignore any cached MP3s that already exist."""
        chapter = Chapter(1, "Chapter 1", "ch1.html", "Content 1")
        output_dir = Path(self.temp_dir)
        config = ConversionConfig(
            engine="edge",
            output_dir=output_dir,
            force_reprocess=True,
            validate_audio=False,
            validate_text=False,
        )
        cached_mp3 = self.converter._expected_output_path(chapter, 1, output_dir)
        cached_mp3.parent.mkdir(parents=True, exist_ok=True)
        cached_mp3.write_bytes(b"audio" * 400)  # Ensure file > 1000 bytes

        cached, pending = self.converter._split_cached_chapters([chapter], output_dir, config)

        self.assertEqual(cached, [], "Cached MP3s must be ignored when force_reprocess=True")
        self.assertEqual(pending, [chapter], "All chapters should be reprocessed")
