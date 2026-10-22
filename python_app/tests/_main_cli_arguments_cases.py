"""Cli Arguments regression scenarios, collected by test_main."""

from python_app.tests._main_test_support import (
    ConverterApplication as ConverterApplication,
    Namespace as Namespace,
    _apply_overnight_preset as _apply_overnight_preset,
    create_argument_parser as create_argument_parser,
    os as os,
    tempfile as tempfile,
    unittest as unittest,
)

class TestArgumentParser(unittest.TestCase):
    """Test cases for argument parser"""

    def test_create_argument_parser(self):
        """Test argument parser creation"""
        parser = create_argument_parser()

        # Test required argument
        args = parser.parse_args(["convert", "test.epub"])
        self.assertEqual(args.input_file, "test.epub")

        # Test optional arguments
        args = parser.parse_args(
            [
                "convert",
                "test.epub",
                "--engine",
                "edge",
                "--voice",
                "test-voice",
                "--model",
                "test-model",
                "--output-dir",
                "test-output",
                "--show-structure",
                "--filter-chapters",
            ]
        )

        self.assertEqual(args.engine, "edge")
        self.assertEqual(args.voice, "test-voice")
        self.assertEqual(args.model, "test-model")
        self.assertEqual(args.output_dir, "test-output")
        self.assertTrue(args.show_structure)
        self.assertTrue(args.filter_chapters)

        # --engine accepts "auto" as an alias (mapped to edge downstream, see 96bb0e7)
        args = parser.parse_args(["convert", "test.epub", "--engine", "auto"])
        self.assertEqual(args.engine, "auto")

        # --fallback-engine defaults to "none" (strict: don't silently
        # switch engines mid-chapter — the Carl regression). Accepts
        # auto/piper/none when set explicitly.
        args = parser.parse_args(["convert", "test.epub"])
        self.assertEqual(args.fallback_engine, "none")
        for choice in ("auto", "piper", "none"):
            args = parser.parse_args(["convert", "test.epub", "--fallback-engine", choice])
            self.assertEqual(args.fallback_engine, choice)
        with self.assertRaises(SystemExit):
            parser.parse_args(["convert", "test.epub", "--fallback-engine", "edge"])

        args = parser.parse_args(["convert", "test.epub", "--detect-language"])
        self.assertTrue(args.detect_language)
        args = parser.parse_args(["convert", "test.epub", "--show-metrics-summary"])
        self.assertTrue(args.show_metrics_summary)
        args = parser.parse_args(["convert", "test.epub", "--show-metrics-dashboard"])
        self.assertTrue(args.show_metrics_dashboard)
        args = parser.parse_args(["convert", "test.epub", "--open-metrics-dashboard"])
        self.assertTrue(args.open_metrics_dashboard)
        args = parser.parse_args(["convert", "test.epub", "--export-metrics-bundle"])
        self.assertTrue(args.export_metrics_bundle)
        args = parser.parse_args(
            ["convert", "test.epub", "--profile", "speed", "--speed-scenario", "offline-heavy"]
        )
        self.assertEqual(args.profile, "speed")
        self.assertEqual(args.speed_scenario, "offline-heavy")
        args = parser.parse_args(["convert", "test.epub", "--resume-from-failure"])
        self.assertTrue(args.resume_from_failure)
        args = parser.parse_args(["convert", "test.epub", "--no-resume-from-failure"])
        self.assertFalse(args.resume_from_failure)
        args = parser.parse_args(["convert", "test.epub", "--prefetch"])
        self.assertTrue(args.chapter_prefetch)
        args = parser.parse_args(["convert", "test.epub", "--no-prefetch"])
        self.assertFalse(args.chapter_prefetch)
        args = parser.parse_args(["convert", "test.epub", "--ab-auto"])
        self.assertTrue(args.auto_ab)
        args = parser.parse_args(["convert", "test.epub", "--no-ab-auto"])
        self.assertFalse(args.auto_ab)
        args = parser.parse_args(["convert", "test.epub", "--adaptive-checkpoint"])
        self.assertTrue(args.adaptive_checkpoint)
        args = parser.parse_args(["convert", "test.epub", "--no-adaptive-checkpoint"])
        self.assertFalse(args.adaptive_checkpoint)
        args = parser.parse_args(
            ["convert", "test.epub", "--piper-workers", "4", "--piper-chunk-chars", "2200"]
        )
        self.assertEqual(args.piper_max_procs, 4)
        self.assertEqual(args.piper_chunk_chars, 2200)
        args = parser.parse_args(["convert", "test.epub", "--overnight"])
        self.assertTrue(args.overnight)
        args = parser.parse_args(["convert", "test.epub", "--verify"])
        self.assertTrue(args.verify_only)
        args = parser.parse_args(["convert", "test.epub", "--verify-only"])
        self.assertTrue(args.verify_only)

    def test_parser_engine_choices(self):
        """Test engine choices validation"""
        parser = create_argument_parser()

        # Valid engines
        for engine in ["edge", "piper"]:
            args = parser.parse_args(["convert", "test.epub", "--engine", engine])
            self.assertEqual(args.engine, engine)


class TestOvernightPreset(unittest.TestCase):
    def test_apply_overnight_preset(self):
        args = Namespace(
            overnight=True,
            engine="edge",
            max_performance=False,
            profile=None,
            speed_scenario="auto",
            stage_pipeline=None,
            stage_pipeline_depth=None,
            chapter_prefetch=None,
            auto_ab=None,
            adaptive_checkpoint=None,
            verify_transcription=None,
            deep_validate=None,
            validate_text=True,
            validate_audio=True,
            auto_validate_output=True,
            auto_fix_output=True,
            piper_chunk_chars=None,
        )

        _apply_overnight_preset(args)

        self.assertEqual(args.engine, "piper")
        self.assertTrue(args.max_performance)
        self.assertEqual(args.profile, "speed")
        self.assertEqual(args.speed_scenario, "offline-heavy")
        self.assertTrue(args.stage_pipeline)
        self.assertEqual(args.stage_pipeline_depth, 3)
        self.assertTrue(args.chapter_prefetch)
        self.assertFalse(args.auto_ab)
        self.assertTrue(args.adaptive_checkpoint)
        self.assertFalse(args.validate_text)
        self.assertFalse(args.validate_audio)
        self.assertFalse(args.auto_validate_output)
        self.assertFalse(args.auto_fix_output)
        self.assertEqual(args.piper_chunk_chars, 2200)


class TestClearCacheFlag(unittest.TestCase):
    """Test cases for --clear-cache flag"""

    def setUp(self):
        """Set up test fixtures"""
        self.temp_dir = tempfile.mkdtemp()
        self.test_file = os.path.join(self.temp_dir, "test.epub")

        # Create dummy file
        with open(self.test_file, "w") as f:
            f.write("dummy content")

        self.app = ConverterApplication()

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil

        if os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_output_directory_format(self):
        """Test that output directory uses book_engine format instead of book/engine"""
        from src.config import ConversionConfig
        from src.converter import AudioConverter

        converter = AudioConverter()
        config = ConversionConfig(
            engine="edge",
            output_dir=self.temp_dir,
            book_title="Test Book",
        )

        output_dir = converter._setup_output_directory(config)

        # Should be output/Test Book (no engine suffix)
        # Note: FileManager keeps spaces in sanitized titles
        self.assertTrue(str(output_dir).endswith("Test Book"))

    def test_output_directory_format_with_underscores(self):
        """Test that output directory handles books with underscores in title"""
        from src.config import ConversionConfig
        from src.converter import AudioConverter

        converter = AudioConverter()
        config = ConversionConfig(
            engine="piper",
            output_dir=self.temp_dir,
            book_title="My_Test_Book",
        )

        output_dir = converter._setup_output_directory(config)

        # Should use book title only (no engine suffix)
        self.assertTrue(str(output_dir).endswith("My_Test_Book"))
