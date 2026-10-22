"""Application run scenarios sharing the original unittest fixture."""

from python_app.tests._main_test_support import (
    Mock as Mock,
    Namespace as Namespace,
    Path as Path,
    _asyncio_run_stub as _asyncio_run_stub,
    patch as patch,
)

class ApplicationRunCases:
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

    @patch("builtins.print")
    def test_run_batch_lists_failed_books(self, mock_print):
        args = Namespace(
            batch_stop_on_error=False,
            verify_only=False,
            fix_mode=False,
        )

        with patch.object(
            self.app,
            "_run_single_conversion",
            side_effect=[0, 2],
        ):
            result = self.app._run_batch(
                args,
                [Path("ok.epub"), Path("failed.epub")],
                hardware_profile=Mock(),
            )

        self.assertEqual(result, 2)
        printed = "\n".join(
            " ".join(str(arg) for arg in call.args) for call in mock_print.call_args_list
        )
        self.assertIn("Failed books:", printed)
        self.assertIn("failed.epub", printed)

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

    def test_run_verify_only_success(self):
        import shutil

        from src.config import ConversionConfig

        config = ConversionConfig(
            engine="edge",
            output_dir=Path(self.temp_dir),
            cache_dir=Path(self.temp_dir),
            book_title="test",
        )
        output_dir = Path(self.temp_dir) / "test"
        output_dir.mkdir(parents=True, exist_ok=True)

        try:
            with patch("validate_conversion.validate_book", return_value=({}, [])):
                result = self.app._run_verify_only(Path(self.test_file), config)
        finally:
            shutil.rmtree(output_dir, ignore_errors=True)

        self.assertEqual(result, 0)
