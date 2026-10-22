# -*- coding: utf-8 -*-
"""
Unit tests for main application
"""

import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from python_app.tests._main_application_run_cases import ApplicationRunCases
from python_app.tests._main_application_structure_cases import ApplicationStructureCases
from python_app.tests._main_cache_bypass_cases import TestCacheBypassFlag as TestCacheBypassFlag
from python_app.tests._main_clear_cache_storage_cases import (
    TestClearCacheRemovesBookData as TestClearCacheRemovesBookData,
)
from python_app.tests._main_clear_cache_targets_cases import (
    TestChapterSpecificClearCache as TestChapterSpecificClearCache,
)
from python_app.tests._main_clear_cache_targets_cases import (
    TestClearCacheSubcommandWithBook as TestClearCacheSubcommandWithBook,
)
from python_app.tests._main_cli_arguments_cases import TestArgumentParser as TestArgumentParser
from python_app.tests._main_cli_arguments_cases import TestClearCacheFlag as TestClearCacheFlag
from python_app.tests._main_cli_arguments_cases import TestOvernightPreset as TestOvernightPreset
from python_app.tests._main_structure_text_cases import (
    TestPrepareChapterTextHeadingDedup as TestPrepareChapterTextHeadingDedup,
)
from python_app.tests._main_structure_text_cases import (
    TestSectionNumberDisplay as TestSectionNumberDisplay,
)
from python_app.tests._main_test_support import Chapter as Chapter
from python_app.tests._main_test_support import ChapterStructureItem as ChapterStructureItem
from python_app.tests._main_test_support import ConverterApplication as ConverterApplication
from python_app.tests._main_test_support import Mock as Mock
from python_app.tests._main_test_support import Namespace as Namespace
from python_app.tests._main_test_support import SimpleNamespace as SimpleNamespace
from python_app.tests._main_test_support import _asyncio_run_stub as _asyncio_run_stub
from python_app.tests._main_test_support import main as main
from python_app.tests._main_test_support import os as os
from python_app.tests._main_test_support import patch as patch
from python_app.tests._main_test_support import subprocess as subprocess
from python_app.tests._main_test_support import tempfile as tempfile
from python_app.tests._main_test_support import unittest as unittest


class TestConverterApplication(
    ApplicationRunCases,
    ApplicationStructureCases,
    unittest.TestCase,
):
    """Test cases for ConverterApplication"""

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
        if os.path.exists(self.test_file):
            os.remove(self.test_file)
        os.rmdir(self.temp_dir)

    def test_init(self):
        """Test application initialization"""
        self.assertIsNotNone(self.app.config)
        self.assertIsNotNone(self.app.menu)
        self.assertIsNotNone(self.app.converter)

    def test_strip_book_title_prefix_removes_repeated_prefix(self):
        cleaned = self.app._strip_book_title_prefix(
            "It, It: It — Chapter starts here",
            "It",
        )
        self.assertEqual(cleaned, "Chapter starts here")

    def test_create_config_from_args(self):
        """Test creating config from command line arguments"""
        mock_reader = Mock()
        mock_reader.title = "Test Book"

        args = Namespace(
            engine="edge",
            voice="test-voice",
            model=None,
            output_dir="test_output",
            filter_chapters=True,
            listen=True,
            cache_dir="cache",
            clear_cache=True,
            no_footnote=False,
            footnote_chapter_end=True,
            formatting_cues=True,
            priority=["h1"],
            retry_failed_rounds=None,
            retry_failed_manual=False,
        )

        with patch.object(self.app.config, "create_conversion_config") as mock_create:
            mock_create.return_value = Mock()

            config = self.app._create_config_from_args(args, mock_reader)

            self.assertIsNotNone(config)
            mock_create.assert_called_once()
            called_kwargs = mock_create.call_args.kwargs
            self.assertEqual(called_kwargs["engine"], "edge")
            self.assertEqual(called_kwargs["voice"], "test-voice")
            self.assertIsNone(called_kwargs["model"])
            self.assertEqual(called_kwargs["output_dir"], "test_output")
        self.assertEqual(called_kwargs["book_title"], "Test Book")
        self.assertFalse(called_kwargs["preserve_all_chapters"])
        self.assertTrue(called_kwargs["listen"])
        self.assertEqual(called_kwargs["cache_dir"], "cache")
        self.assertTrue(called_kwargs["clear_cache"])
        self.assertEqual(called_kwargs["footnote_mode"], "chapter_end")
        self.assertEqual(called_kwargs["footnote_context_words"], self.app.FOOTNOTE_CONTEXT_WORDS)

    def test_create_config_from_args_sets_force_reprocess_when_no_cache(self):
        """--no-cache should force reprocessing regardless of cached audio"""
        mock_reader = Mock()
        mock_reader.title = "Another Book"

        args = Namespace(
            engine="edge",
            voice=None,
            model=None,
            output_dir=None,
            filter_chapters=False,
            listen=False,
            cache_dir=None,
            clear_cache=False,
            no_cache=True,
            no_footnote=False,
            footnote_chapter_end=False,
            formatting_cues=None,
            priority=[],
            retry_failed_rounds=None,
            retry_failed_manual=False,
        )

        with patch.object(self.app.config, "create_conversion_config") as mock_create:
            stub_config = Mock()
            mock_create.return_value = stub_config

            config = self.app._create_config_from_args(args, mock_reader)

            self.assertIsNotNone(config)
            called_kwargs = mock_create.call_args.kwargs
            self.assertTrue(
                called_kwargs.get("force_reprocess"),
                "force_reprocess should be enabled when --no-cache is used",
            )

    def test_apply_cli_overrides_auto_engine_enables_auto_tuning_defaults(self):
        config = self.app.config.create_conversion_config(engine="auto")
        args = Namespace(
            use_language_detection=None,
            prioritize_primary_language=None,
            force_reprocess=False,
            no_cache=False,
            edge_chunk_chars=None,
            edge_max_segment_seconds=None,
            edge_enable_parallel=None,
            edge_auto_tune=None,
            piper_max_procs=None,
            edge_stable_mode=None,
            bitrate=None,
            auto_validate_output=None,
            auto_fix_output=None,
            deep_validate=None,
            sample_rate=None,
            channels=None,
            max_performance=False,
            parallel_slots=None,
            no_parallel=False,
            chapter_stall_seconds=None,
            edge_network_tier=None,
            health_check_interval_seconds=None,
            health_check_slow_edge_cps=None,
            health_check_slow_cps=None,
            health_check_high_cpu=None,
            health_check_high_mem=None,
            health_check_ok_cpu=None,
            health_check_ok_mem=None,
            health_check_slow_streak=None,
        )

        with patch.dict(os.environ, {}, clear=True):
            self.app._apply_cli_overrides(args, config)
            self.assertEqual(os.environ.get("ENABLE_AUTO_TUNING"), "1")
            self.assertEqual(os.environ.get("ENABLE_ADAPTIVE_PERFORMANCE"), "1")
            self.assertEqual(os.environ.get("CHAPTER_STALL_SECONDS"), "45")
            self.assertEqual(os.environ.get("CHAPTER_PARALLEL_COUNT"), "4")
            self.assertEqual(os.environ.get("CHAPTER_PARALLEL_MAX"), "4")

        self.assertTrue(config.edge_auto_tune)
        self.assertEqual(config.edge_chunk_chars, 24000)
        self.assertEqual(config.edge_max_segment_seconds, 300)

    def test_apply_cli_overrides_sets_runtime_feature_flags(self):
        config = self.app.config.create_conversion_config(engine="auto")
        args = Namespace(
            use_language_detection=None,
            prioritize_primary_language=None,
            force_reprocess=False,
            no_cache=False,
            resume_from_failure=None,
            chapter_prefetch=False,
            auto_ab=True,
            adaptive_checkpoint=False,
            edge_chunk_chars=None,
            edge_max_segment_seconds=None,
            edge_enable_parallel=None,
            edge_auto_tune=None,
            piper_max_procs=None,
            edge_stable_mode=None,
            bitrate=None,
            auto_validate_output=None,
            auto_fix_output=None,
            deep_validate=None,
            sample_rate=None,
            channels=None,
            max_performance=False,
            parallel_slots=None,
            no_parallel=False,
            chapter_stall_seconds=None,
            edge_network_tier=None,
            health_check_interval_seconds=None,
            health_check_slow_edge_cps=None,
            health_check_slow_cps=None,
            health_check_high_cpu=None,
            health_check_high_mem=None,
            health_check_ok_cpu=None,
            health_check_ok_mem=None,
            health_check_slow_streak=None,
        )

        self.app._apply_cli_overrides(args, config)
        self.assertEqual(config.extra.get("chapter_prefetch"), "0")
        self.assertEqual(config.extra.get("auto_ab"), "1")
        self.assertEqual(config.extra.get("adaptive_checkpoint"), "0")

    def _build_structure_item(self, html: str) -> ChapterStructureItem:
        chapter = Chapter(
            index=1,
            name="Capítulo 1",
            source_path="chapter1.xhtml",
            text="",
            raw_html=html,
        )
        return ChapterStructureItem(
            chapter=chapter,
            index="1",
            main_title="Capítulo 1",
            sub_title=None,
            preview=None,
            display_name="Capítulo 1",
        )

    def _sample_html(self) -> str:
        return (
            "<html><body>"
            "<p>Texto <em>itálico</em> e <strong>negrito</strong> com <q>aspas</q> e nota"
            "<a href='#fn1'>1</a>.</p>"
            "<section id='notas'><p id='fn1'><a href='#ref-fn1'>1</a> Esta nota explicativa.</p></section>"
            "</body></html>"
        )


class TestMainFunction(unittest.TestCase):
    """Test cases for main function"""

    @patch("main.ConverterApplication")
    @patch("sys.argv", ["main.py", "convert", "test.epub"])
    def test_main_function(self, mock_app_class):
        """Test main function"""
        mock_app = Mock()
        mock_app.run.return_value = 0
        mock_app_class.return_value = mock_app

        result = main()
        self.assertEqual(result, 0)
        mock_app.run.assert_called_once()

    @patch("main.ConverterApplication")
    @patch("sys.argv", ["main.py", "convert", "test.epub"])
    def test_main_function_with_error(self, mock_app_class):
        """Test main function with error"""
        mock_app = Mock()
        mock_app.run.return_value = 1
        mock_app_class.return_value = mock_app

        result = main()
        self.assertEqual(result, 1)
        mock_app.run.assert_called_once()


class TestCliE2E(unittest.TestCase):
    def test_convert_show_structure_accepts_runtime_feature_flags(self):
        repo_root = Path(__file__).resolve().parents[2]
        fixture = (
            repo_root / "python_app" / "tests" / "fixtures" / "epubs" / "sample_multilang.epub"
        )
        cmd = [
            sys.executable,
            "-m",
            "python_app.main",
            "convert",
            str(fixture),
            "--show-structure",
            "--prefetch",
            "--ab-auto",
            "--adaptive-checkpoint",
        ]
        proc = subprocess.run(
            cmd,
            cwd=repo_root,
            capture_output=True,
            text=True,
            timeout=180,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr or proc.stdout)
        self.assertTrue(
            "Chapters:" in proc.stdout or "Capítulos:" in proc.stdout,
            msg=proc.stdout,
        )


if __name__ == "__main__":
    unittest.main()
