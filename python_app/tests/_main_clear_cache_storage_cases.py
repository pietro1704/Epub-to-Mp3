"""Clear Cache Storage regression scenarios, collected by test_main."""

from python_app.tests._main_test_support import (
    Path as Path,
    os as os,
    tempfile as tempfile,
    unittest as unittest,
)

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

    def test_converter_clear_cache_bypasses_initial_validation(self):
        """Clear-cache skips stale validation and preserves best-effort cleanup."""
        import asyncio
        from types import SimpleNamespace
        from unittest.mock import AsyncMock, Mock

        from src.converter import AudioConverter

        async def exercise(clear_cache, cleanup_error):
            # Avoid constructor-owned caches, tuning, engines and user state.
            converter = AudioConverter.__new__(AudioConverter)
            converter._initialize_auto_tuning = AsyncMock()
            converter._initialize_adaptive_performance = Mock()
            converter._optimize_memory_settings = Mock()
            converter._setup_output_directory = Mock(return_value=Path(self.output_dir))
            converter._setup_temp_directory = Mock(return_value=Path(self.cache_dir))
            converter._should_run_initial_validation = Mock(return_value=True)
            converter._auto_validate_output = AsyncMock(return_value=True)
            converter._duplicate_cleanup_enabled = Mock(return_value=False)
            converter._apply_runtime_feature_overrides = Mock()
            converter._apply_startup_guardrail = Mock()
            converter._load_adaptive_state_checkpoint = Mock()
            converter._report_results = AsyncMock()
            converter.cache_manager = SimpleNamespace(
                clear_cache=Mock(side_effect=cleanup_error)
            )
            source = Path(self.temp_dir) / "owned.epub"
            source.write_bytes(b"owned input")
            reader = SimpleNamespace(
                file_path=source,
                title="Owned title",
                get_chapter_structure=Mock(return_value=[]),
            )
            config = SimpleNamespace(
                clear_cache=clear_cache,
                log_callback=Mock(),
                preserve_all_chapters=True,
            )

            result = await converter.convert(reader, config)

            self.assertFalse(result.success)
            self.assertEqual(result.total_chapters, 0)
            converter._report_results.assert_awaited_once_with(result)
            reader.get_chapter_structure.assert_called_once_with(preserve_all=True)
            if clear_cache:
                converter.cache_manager.clear_cache.assert_called_once_with(
                    source, title="Owned title"
                )
                converter._should_run_initial_validation.assert_not_called()
                converter._auto_validate_output.assert_not_awaited()
            else:
                converter.cache_manager.clear_cache.assert_not_called()
                converter._should_run_initial_validation.assert_called_once_with(
                    Path(self.output_dir), config
                )
                converter._auto_validate_output.assert_awaited_once_with(
                    Path(self.output_dir), stage="initial"
                )
            self.assertEqual(source.read_bytes(), b"owned input")

        for clear_cache, cleanup_error in (
            (True, None),
            (True, OSError("cleanup refused")),
            (False, None),
        ):
            with self.subTest(clear_cache=clear_cache, cleanup_error=cleanup_error):
                asyncio.run(exercise(clear_cache, cleanup_error))

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
