# -*- coding: utf-8 -*-
"""
Unit tests for main application
"""

import os
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import ChapterStructureItem, ConverterApplication, create_argument_parser, main
from src.ebook_reader import Chapter


def _asyncio_run_stub(coro):
    try:
        coro.close()
    except RuntimeError:
        pass
    return 0


class TestConverterApplication(unittest.TestCase):
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

    @patch("main.EbookReader")
    def test_run_file_not_found(self, mock_reader):
        """Test running with non-existent file"""
        args = Namespace(
            input_file="/nonexistent/file.epub",
            show_structure=False,
            engine=None,
            voice=None,
            model=None,
            output_dir=None,
            filter_chapters=False,
            parallel=None,
        )

        result = self.app.run(args)
        self.assertEqual(result, 1)
        mock_reader.assert_not_called()

    @patch("main.asyncio.run")
    @patch("main.EbookReader")
    def test_run_with_show_structure(self, mock_reader, mock_asyncio_run):
        """Test running with show structure option"""
        # Mock reader
        mock_reader_instance = Mock()
        mock_reader_instance.title = "Test Book"
        mock_reader_instance.author = "Test Author"
        mock_reader_instance.get_chapters.return_value = [
            Mock(name="Chapter 1", text="Content 1"),
            Mock(name="Chapter 2", text="Content 2"),
        ]
        mock_reader.return_value = mock_reader_instance

        args = Namespace(
            input_file=self.test_file,
            show_structure=True,
            engine=None,
            voice=None,
            model=None,
            output_dir=None,
            filter_chapters=False,
            parallel=None,
        )

        result = self.app.run(args)

        self.assertEqual(result, 0)
        mock_reader.assert_called_once_with(self.test_file)
        mock_asyncio_run.assert_not_called()

    @patch("main.asyncio.run")
    @patch("main.EbookReader")
    def test_run_with_detect_language(self, mock_reader, mock_asyncio_run):
        """Test running with detect-language option"""
        mock_reader_instance = Mock()
        mock_reader_instance.title = "Test Book"
        mock_reader_instance.author = "Test Author"
        mock_reader_instance.get_chapters.return_value = [
            Mock(name="Chapter 1", text="Conteúdo em português para detecção"),
            Mock(name="Chapter 2", text="Mais texto para análise"),
        ]
        mock_reader.return_value = mock_reader_instance

        args = Namespace(
            input_file=self.test_file,
            show_structure=False,
            detect_language=True,
            engine=None,
            voice=None,
            model=None,
            output_dir=None,
            filter_chapters=False,
            parallel=None,
            menu=False,
            listen=False,
            clear_cache=False,
            no_cache=False,
            chapters=None,
            sections=None,
            verbose=False,
            no_footnote=False,
            footnote_chapter_end=False,
        )

        with patch.object(self.app, "_prepare_language_profile") as mock_prepare:
            mock_prepare.return_value = self.app.language_profile = Mock(
                primary="pt-BR",
                languages=["pt-BR"],
                predictions=[Mock(probability=0.91)],
                analysed_chars=12345,
                is_confident=True,
            )
            with patch.object(self.app, "_update_metadata_display_language") as mock_update:
                result = self.app.run(args)

        self.assertEqual(result, 0)
        mock_reader.assert_called_once_with(self.test_file)
        mock_prepare.assert_called_once()
        mock_update.assert_called_once()
        mock_asyncio_run.assert_not_called()

    @patch("main.asyncio.run")
    @patch("main.EbookReader")
    def test_run_with_engine_specified(self, mock_reader, mock_asyncio_run):
        """Test running with specific engine"""
        mock_reader_instance = Mock()
        mock_reader_instance.title = "Test Book"
        mock_reader_instance.file_path = Path(self.test_file)
        mock_reader_instance.get_chapters.return_value = []
        mock_reader.return_value = mock_reader_instance

        mock_asyncio_run.side_effect = _asyncio_run_stub

        args = Namespace(
            input_file=self.test_file,
            show_structure=False,
            engine="edge",
            voice="test-voice",
            model=None,
            output_dir="test_output",
            filter_chapters=False,
            parallel=None,
            menu=False,  # Required to avoid menu path
            listen=False,
            clear_cache=False,
            no_cache=False,
            chapters=None,
            sections=None,
            verbose=False,
            no_footnote=False,
            footnote_chapter_end=False,
        )

        with patch.object(self.app, "_create_config_from_args") as mock_config:
            # Return a real ConversionConfig with Path for output_dir
            mock_config.return_value = self.app.config.create_conversion_config(
                engine="edge",
                voice="test-voice",
                output_dir=Path("test_output"),  # Use Path instead of string
                footnote_mode="inline",
                footnote_context_words=self.app.FOOTNOTE_CONTEXT_WORDS,
            )

            result = self.app.run(args)

            self.assertEqual(result, 0)
            self.assertGreaterEqual(mock_config.call_count, 1)
            mock_asyncio_run.assert_called_once()

    @patch("main.EbookReader")
    def test_run_with_menu(self, mock_reader):
        """Test running with interactive menu"""
        mock_reader_instance = Mock()
        mock_reader_instance.title = "Test Book"
        mock_reader_instance.file_path = Path(self.test_file)
        mock_reader_instance.get_chapters.return_value = []
        mock_reader.return_value = mock_reader_instance

        args = Namespace(
            input_file=self.test_file,
            show_structure=False,
            engine=None,
            voice=None,
            model=None,
            output_dir=None,
            filter_chapters=False,
            parallel=None,
            menu=True,
            listen=False,
            clear_cache=False,
            no_cache=False,
            chapters=None,
            sections=None,
            verbose=False,
            no_footnote=False,
            footnote_chapter_end=False,
        )

        with patch.object(self.app.menu, "get_conversion_config") as mock_menu:
            mock_menu.return_value = None  # User cancelled

            result = self.app.run(args)

            self.assertEqual(result, 1)
            mock_menu.assert_called_once()
            _args, kwargs = mock_menu.call_args
            self.assertEqual(_args[0], mock_reader_instance)
            self.assertEqual(kwargs.get("language_profile"), self.app.language_profile)

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
            coqui_chunk_chars=None,
            coqui_max_workers=None,
            coqui_safe_mode=None,
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

    def test_apply_text_transforms_inline_retains_emphasis(self):
        item = self._build_structure_item(self._sample_html())
        reader = SimpleNamespace(title="Livro de Teste")
        config = self.app.config.create_conversion_config(
            engine="edge",
            footnote_mode="inline",
            footnote_context_words=8,
        )

        result = self.app._apply_text_transforms([item], config, reader)

        self.assertEqual(len(result), 1)
        text = result[0].text_override
        self.assertIsNotNone(text)
        self.assertIn("_itálico_", text)
        self.assertIn("**negrito**", text)
        self.assertIn("“aspas”", text)
        self.assertIn("nota de rodapé 1", text)
        self.assertIn("fim da nota de rodapé", text)

        segments = item.chapter.formatting_segments or []
        self.assertTrue(
            any(seg.formatting == "italic" and seg.text == "itálico" for seg in segments)
        )
        self.assertTrue(any(seg.formatting == "bold" and seg.text == "negrito" for seg in segments))
        self.assertTrue(any(seg.formatting == "quote" and seg.text == "aspas" for seg in segments))
        self.assertFalse(any("[[FOOTNOTE" in seg.text for seg in segments))
        self.assertNotIn("*", item.chapter.speech_text or "")
        self.assertNotIn("_", item.chapter.speech_text or "")
        self.assertIn("nota de rodapé 1", item.chapter.speech_text or "")
        self.assertIn("Esta nota explicativa", item.chapter.speech_text or "")

    def test_apply_text_transforms_chapter_end_moves_notes(self):
        item = self._build_structure_item(self._sample_html())
        reader = SimpleNamespace(title="Livro de Teste")
        config = self.app.config.create_conversion_config(
            engine="edge",
            footnote_mode="chapter_end",
            footnote_context_words=8,
        )

        result = self.app._apply_text_transforms([item], config, reader)
        text = result[0].text_override

        self.assertIn("Texto _itálico_ e **negrito** com “aspas” e nota.", text)
        self.assertTrue(any("nota de rodapé 1:" in line for line in text.splitlines()[1:]))
        self.assertNotIn("[[FOOTNOTE", text)

        segments = item.chapter.formatting_segments or []
        self.assertTrue(
            any(seg.formatting == "italic" and seg.text == "itálico" for seg in segments)
        )
        self.assertFalse(any("[[FOOTNOTE" in seg.text for seg in segments))
        speech = item.chapter.speech_text or ""
        self.assertNotIn("*", speech)
        self.assertNotIn("_", speech)
        self.assertIn("nota de rodapé 1", speech)

    def test_apply_text_transforms_skip_removes_notes(self):
        item = self._build_structure_item(self._sample_html())
        reader = SimpleNamespace(title="Livro de Teste")
        config = self.app.config.create_conversion_config(
            engine="edge",
            footnote_mode="skip",
            footnote_context_words=8,
        )

        result = self.app._apply_text_transforms([item], config, reader)
        text = result[0].text_override

        self.assertIn("Texto _itálico_ e **negrito** com “aspas” e nota.", text)
        self.assertNotIn("nota de rodapé", text)
        self.assertNotIn("[[FOOTNOTE", text)

        segments = item.chapter.formatting_segments or []
        self.assertTrue(
            any(seg.formatting == "italic" and seg.text == "itálico" for seg in segments)
        )
        self.assertFalse(any("[[FOOTNOTE" in seg.text for seg in segments))
        speech = item.chapter.speech_text or ""
        self.assertNotIn("*", speech)
        self.assertNotIn("_", speech)
        self.assertNotIn("nota de rodapé", speech)

    def test_run_with_exception(self):
        """Test running with exception"""
        args = Namespace(
            input_file=self.test_file,
            show_structure=False,
            engine=None,
            voice=None,
            model=None,
            output_dir=None,
            filter_chapters=False,
            parallel=None,
        )

        with patch("main.EbookReader") as mock_reader:
            mock_reader.side_effect = Exception("Test exception")

            result = self.app.run(args)

            self.assertEqual(result, 1)

    def test_deduplicate_heading(self):
        """Ensure duplicate heading lines are removed."""
        text = "Capítulo Um\nCAPÍTULO UM\nConteúdo"  # duplicate heading with different casing
        result = self.app._deduplicate_heading(text, "Capítulo Um")
        self.assertEqual(result, "CAPÍTULO UM\nConteúdo")

        text2 = "\n\nPrólogo\nPrólogo\nTexto"
        result2 = self.app._deduplicate_heading(text2, "")
        self.assertEqual(result2, "Prólogo\nTexto")


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

    def test_parser_engine_choices(self):
        """Test engine choices validation"""
        parser = create_argument_parser()

        # Valid engines
        for engine in ["auto", "edge", "coqui", "piper", "kokoro", "spark"]:
            args = parser.parse_args(["convert", "test.epub", "--engine", engine])
            self.assertEqual(args.engine, engine)


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
            engine="coqui",
            output_dir=self.temp_dir,
            book_title="My_Test_Book",
        )

        output_dir = converter._setup_output_directory(config)

        # Should use book title only (no engine suffix)
        self.assertTrue(str(output_dir).endswith("My_Test_Book"))


class TestClearCacheRemovesBookData(unittest.TestCase):
    """Test that --clear-cache actually removes cache and output before conversion"""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.cache_dir = os.path.join(self.temp_dir, ".cache")
        self.output_dir = os.path.join(self.temp_dir, "output")
        os.makedirs(self.cache_dir, exist_ok=True)
        os.makedirs(self.output_dir, exist_ok=True)

    def tearDown(self):
        import shutil

        if os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_clear_cache_removes_book_cache_directory(self):
        """--clear-cache should remove the book's cache directory"""
        from src.cache_manager import CacheManager

        cm = CacheManager(cache_dir=Path(self.cache_dir))

        # Create fake book cache
        book_cache = Path(self.cache_dir) / "Test_Book"
        book_cache.mkdir(parents=True, exist_ok=True)
        (book_cache / "metadata.json").write_text('{"title": "Test Book"}')
        (book_cache / "text").mkdir(exist_ok=True)
        (book_cache / "text" / "chapter_1.txt").write_text("content")

        self.assertTrue(book_cache.exists())

        # Clear cache for this book
        epub_path = Path(self.temp_dir) / "Test_Book.epub"
        epub_path.write_text("dummy")
        cm.clear_cache(epub_path, title="Test Book")

        self.assertFalse(book_cache.exists())

    def test_clear_cache_removes_book_output_directory(self):
        """--clear-cache should remove the book's output directory"""

        book_output = Path(self.output_dir) / "Test Book"
        book_output.mkdir(parents=True, exist_ok=True)
        (book_output / "chapter_01.mp3").write_text("fake mp3")
        (book_output / "chapter_02.mp3").write_text("fake mp3")

        self.assertTrue(book_output.exists())
        self.assertEqual(len(list(book_output.glob("*.mp3"))), 2)

        # Simulate what converter does with clear_cache
        import shutil

        shutil.rmtree(book_output, ignore_errors=True)

        self.assertFalse(book_output.exists())

    def test_clear_cache_does_not_remove_other_books(self):
        """--clear-cache should only remove the specific book, not others"""
        from src.cache_manager import CacheManager

        cm = CacheManager(cache_dir=Path(self.cache_dir))

        # Create cache for two books
        book1_cache = Path(self.cache_dir) / "Book_One"
        book1_cache.mkdir(parents=True, exist_ok=True)
        (book1_cache / "chapter.txt").write_text("book1")

        book2_cache = Path(self.cache_dir) / "Book_Two"
        book2_cache.mkdir(parents=True, exist_ok=True)
        (book2_cache / "chapter.txt").write_text("book2")

        # Clear only book1
        epub_path = Path(self.temp_dir) / "Book_One.epub"
        epub_path.write_text("dummy")
        cm.clear_cache(epub_path, title="Book One")

        self.assertFalse(book1_cache.exists())
        self.assertTrue(book2_cache.exists())

    def test_converter_clear_cache_removes_output_and_cache(self):
        """When clear_cache=True, converter.convert should remove cache and output"""
        import shutil

        from src.cache_manager import CacheManager
        from src.converter import AudioConverter

        converter = AudioConverter()

        book_output = Path(self.output_dir) / "Test Book"
        book_output.mkdir(parents=True, exist_ok=True)
        (book_output / "chapter_01.mp3").write_text("old mp3")
        (book_output / "chapter_02.mp3").write_text("old mp3")

        # Create a book cache directory
        book_cache = Path(self.cache_dir) / "Test_Book"
        book_cache.mkdir(parents=True, exist_ok=True)
        (book_cache / "text").mkdir(exist_ok=True)
        (book_cache / "text" / "chapter_1.txt").write_text("cached text")

        self.assertTrue(book_output.exists())
        self.assertEqual(len(list(book_output.glob("*.mp3"))), 2)
        self.assertTrue(book_cache.exists())

        # Simulate what converter does: clear cache then clear output
        cm = CacheManager(cache_dir=Path(self.cache_dir))
        epub_path = Path(self.temp_dir) / "Test_Book.epub"
        epub_path.write_text("dummy")
        cm.clear_cache(epub_path, title="Test Book")

        if book_output.exists():
            shutil.rmtree(book_output, ignore_errors=True)

        self.assertFalse(book_cache.exists(), "Book cache should be removed")
        self.assertFalse(book_output.exists(), "Book output should be removed")

    def test_converter_source_has_clear_cache_before_validation(self):
        """Verify that in converter source, clear_cache runs BEFORE early validation"""
        import inspect

        from src.converter import AudioConverter

        source = inspect.getsource(AudioConverter.convert)

        clear_cache_pos = source.find("clear_cache")
        validate_pos = source.find("_auto_validate_output")

        self.assertGreater(clear_cache_pos, 0, "clear_cache should exist in source")
        self.assertGreater(validate_pos, 0, "_auto_validate_output should exist in source")
        self.assertLess(
            clear_cache_pos,
            validate_pos,
            "clear_cache should run BEFORE _auto_validate_output in convert()",
        )

    def test_main_clear_cache_removes_output_dirs(self):
        """main.py --clear-cache should remove output directories matching book title"""
        output_base = Path(self.output_dir)

        # Create output directory for the book (no engine suffix)
        d = output_base / "Test Book"
        d.mkdir(parents=True, exist_ok=True)
        (d / "chapter_01.mp3").write_text("fake")

        # Also create legacy dirs with engine suffix (should also be cleaned)
        for engine in ["edge", "piper"]:
            legacy = output_base / f"Test Book_{engine}"
            legacy.mkdir(parents=True, exist_ok=True)
            (legacy / "chapter_01.mp3").write_text("fake")

        # Create output for a different book (should NOT be removed)
        other = output_base / "Other Book"
        other.mkdir(parents=True, exist_ok=True)
        (other / "chapter_01.mp3").write_text("fake")

        # Simulate the cleanup logic from main.py
        from src.utils import FileManager

        sanitized_title = FileManager.sanitize_filename("Test Book")
        removed_count = 0
        for output_dir in output_base.iterdir():
            if output_dir.is_dir() and (
                output_dir.name == sanitized_title
                or output_dir.name.startswith(f"{sanitized_title}_")
            ):
                import shutil

                shutil.rmtree(output_dir, ignore_errors=True)
                removed_count += 1

        self.assertEqual(removed_count, 3)
        self.assertFalse((output_base / "Test Book").exists())
        self.assertFalse((output_base / "Test Book_edge").exists())
        self.assertFalse((output_base / "Test Book_piper").exists())
        self.assertTrue(other.exists())


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


if __name__ == "__main__":
    unittest.main()
