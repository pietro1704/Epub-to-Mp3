"""Clear Cache Targets regression scenarios, collected by test_main."""

import python_app.tests._main_test_support as _shared_test_exports
from python_app.tests._main_test_support import Path as Path
from python_app.tests._main_test_support import patch as patch
from python_app.tests._main_test_support import tempfile as tempfile
from python_app.tests._main_test_support import unittest as unittest

ConverterApplication = _shared_test_exports.ConverterApplication
create_argument_parser = _shared_test_exports.create_argument_parser


class TestClearCacheSubcommandWithBook(unittest.TestCase):
    """Test 'clear-cache <book>' subcommand removes only that book's cache and output."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.cache_dir = Path(self.temp_dir) / ".cache"
        self.output_dir = Path(self.temp_dir) / "output"
        self.cache_dir.mkdir(parents=True)
        self.output_dir.mkdir(parents=True)

        # A fake EPUB file for the target book
        self.epub_path = Path(self.temp_dir) / "My_Book.epub"
        self.epub_path.write_bytes(b"dummy")

    def tearDown(self):
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _make_book_cache(self, title: str) -> Path:
        from src.utils import FileManager

        safe = FileManager.sanitize_filename(title)
        d = self.cache_dir / safe
        d.mkdir(parents=True, exist_ok=True)
        (d / "metadata.json").write_text('{"title": "' + title + '"}')
        return d

    def _make_book_output(self, title: str, engine_suffix: str = "") -> Path:
        from src.utils import FileManager

        safe = FileManager.sanitize_filename(title)
        name = f"{safe}_{engine_suffix}" if engine_suffix else safe
        d = self.output_dir / name
        d.mkdir(parents=True, exist_ok=True)
        (d / "chapter_01.mp3").write_bytes(b"fake")
        return d

    def _run_clear_cache_for_book(self, epub_path: Path) -> int:
        """Invoke _handle_clear_cache_for_book with patched OUTPUT_DIR and cache root."""
        import main as main_mod
        from main import ConverterApplication

        app = ConverterApplication()
        original_output = main_mod.OUTPUT_DIR
        original_cache = app.cache_root
        try:
            main_mod.OUTPUT_DIR = self.output_dir
            app.cache_root = self.cache_dir
            # Patch resolve_cache_root used inside _handle_clear_cache_for_book
            with patch("main.resolve_cache_root", return_value=self.cache_dir):
                return app._handle_clear_cache_for_book(str(epub_path))
        finally:
            main_mod.OUTPUT_DIR = original_output
            app.cache_root = original_cache

    def test_clears_cache_directory_for_book(self):
        """clear-cache <book> removes the book's .cache directory."""
        book_cache = self._make_book_cache("My_Book")
        self.assertTrue(book_cache.exists())

        result = self._run_clear_cache_for_book(self.epub_path)

        self.assertEqual(result, 0)
        self.assertFalse(book_cache.exists())

    def test_clears_output_directory_for_book(self):
        """clear-cache <book> removes the book's output directory."""
        book_output = self._make_book_output("My_Book")
        self.assertTrue(book_output.exists())

        result = self._run_clear_cache_for_book(self.epub_path)

        self.assertEqual(result, 0)
        self.assertFalse(book_output.exists())

    def test_clears_output_directories_with_engine_suffix(self):
        """clear-cache <book> removes output dirs with engine suffixes (e.g. Book_edge)."""
        out_edge = self._make_book_output("My_Book", "edge")
        out_piper = self._make_book_output("My_Book", "piper")
        self.assertTrue(out_edge.exists())
        self.assertTrue(out_piper.exists())

        result = self._run_clear_cache_for_book(self.epub_path)

        self.assertEqual(result, 0)
        self.assertFalse(out_edge.exists())
        self.assertFalse(out_piper.exists())

    def test_does_not_remove_other_book(self):
        """clear-cache <book> leaves other books' cache and output intact."""
        self._make_book_cache("My_Book")
        other_cache = self._make_book_cache("Other_Book")
        other_output = self._make_book_output("Other_Book")

        self._run_clear_cache_for_book(self.epub_path)

        self.assertTrue(other_cache.exists(), "Other book cache should be preserved")
        self.assertTrue(other_output.exists(), "Other book output should be preserved")

    def test_returns_error_when_file_not_found(self):
        """clear-cache with a missing file returns exit code 1."""
        from main import ConverterApplication

        app = ConverterApplication()
        with patch("main.resolve_cache_root", return_value=self.cache_dir):
            result = app._handle_clear_cache_for_book("/nonexistent/path/book.epub")
        self.assertEqual(result, 1)

    def test_clear_cache_subcommand_accepts_book_argument(self):
        """Argparse accepts 'clear-cache <book>' without error."""
        from main import create_argument_parser

        parser = create_argument_parser()
        args = parser.parse_args(["clear-cache", "mybook.epub"])
        self.assertEqual(args.command, "clear_cache")
        self.assertEqual(args.book, "mybook.epub")

    def test_clear_cache_subcommand_book_is_optional(self):
        """Argparse accepts 'clear-cache' without a book argument."""
        from main import create_argument_parser

        parser = create_argument_parser()
        args = parser.parse_args(["clear-cache"])
        self.assertEqual(args.command, "clear_cache")
        self.assertIsNone(args.book)


class TestChapterSpecificClearCache(unittest.TestCase):
    """Test that --chapter X --clear-cache only removes that chapter's cache and output."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.cache_dir = Path(self.temp_dir) / ".cache"
        self.output_dir = Path(self.temp_dir) / "output"
        self.cache_dir.mkdir(parents=True)
        self.output_dir.mkdir(parents=True)

        # "Great Book" → FileManager.sanitize_filename keeps spaces → "Great Book"
        self.book_title = "Great Book"
        self.safe_title = "Great Book"  # FileManager.sanitize_filename preserves spaces
        self.cache_book_dir = self.cache_dir / self.safe_title
        self.cache_book_dir.mkdir(parents=True)
        self.text_dir = self.cache_book_dir / "text"
        self.text_dir.mkdir()

        # Text cache files: converter writes "{label} - {safe_name}-pre-tts.txt"
        (self.text_dir / "5.1 - Chapter Five One-pre-tts.txt").write_text("ch5.1 pre-tts")
        (self.text_dir / "5.1 - Chapter Five One-parsed.txt").write_text("ch5.1 parsed")
        (self.text_dir / "5.2 - Chapter Five Two-pre-tts.txt").write_text("ch5.2 pre-tts")
        (self.text_dir / "5.2 - Chapter Five Two-parsed.txt").write_text("ch5.2 parsed")

        # Cached MP3s in the cache dir (temp during conversion)
        (self.cache_book_dir / "5.1 - Chapter Five One.mp3").write_bytes(b"mp3data")
        (self.cache_book_dir / "5.2 - Chapter Five Two.mp3").write_bytes(b"mp3data")

        # Final output MP3s: build_output_filename keeps spaces → "5.1 - Chapter Five One.mp3"
        self.output_book_dir = self.output_dir / self.safe_title
        self.output_book_dir.mkdir(parents=True)
        (self.output_book_dir / "5.1 - Chapter Five One.mp3").write_bytes(b"final")
        (self.output_book_dir / "5.2 - Chapter Five Two.mp3").write_bytes(b"final")

        # EdgeTTS stream chunk dirs (resume cache)
        self.stream_51 = self.cache_book_dir / "streams" / "cli" / "chapter_5_1"
        self.stream_52 = self.cache_book_dir / "streams" / "cli" / "chapter_5_2"
        self.stream_51.mkdir(parents=True)
        self.stream_52.mkdir(parents=True)
        (self.stream_51 / "chunk_0000.mp3").write_bytes(b"chunk")
        (self.stream_52 / "chunk_0000.mp3").write_bytes(b"chunk")

    def tearDown(self):
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _run_chapter_specific_clear(self, chapter_labels):
        """Simulate main.py chapter-specific --clear-cache logic."""
        from src.utils import FileManager

        sanitized_title = FileManager.sanitize_filename(self.book_title)
        cache_book_dir = self.cache_dir / sanitized_title

        for chapter_label in chapter_labels:
            text_dir = cache_book_dir / "text"
            if text_dir.exists():
                for pattern in (
                    f"{chapter_label} - *-pre-tts.txt",
                    f"{chapter_label} - *-parsed.txt",
                ):
                    for f in text_dir.glob(pattern):
                        f.unlink(missing_ok=True)
            if cache_book_dir.exists():
                for pattern in (
                    f"{chapter_label} - *.mp3",
                    f"{chapter_label} - *.wav",
                ):
                    for f in cache_book_dir.glob(pattern):
                        f.unlink(missing_ok=True)
            # Remove EdgeTTS stream chunks for this chapter
            import shutil as _shutil

            label_safe = chapter_label.replace(".", "_")
            stream_dir = cache_book_dir / "streams" / "cli" / f"chapter_{label_safe}"
            if stream_dir.exists():
                _shutil.rmtree(stream_dir, ignore_errors=True)
            if self.output_dir.exists():
                for out_dir in self.output_dir.iterdir():
                    if out_dir.is_dir() and (
                        out_dir.name == sanitized_title
                        or out_dir.name.startswith(f"{sanitized_title}_")
                    ):
                        for f in out_dir.glob(f"{chapter_label} - *.mp3"):
                            f.unlink(missing_ok=True)

    def test_clears_text_cache_for_selected_chapter(self):
        """chapter-specific clear removes pre-tts and parsed files for that chapter."""
        self._run_chapter_specific_clear(["5.1"])

        self.assertFalse((self.text_dir / "5.1 - Chapter Five One-pre-tts.txt").exists())
        self.assertFalse((self.text_dir / "5.1 - Chapter Five One-parsed.txt").exists())

    def test_preserves_text_cache_of_other_chapters(self):
        """chapter-specific clear must not touch other chapters' text cache."""
        self._run_chapter_specific_clear(["5.1"])

        self.assertTrue((self.text_dir / "5.2 - Chapter Five Two-pre-tts.txt").exists())
        self.assertTrue((self.text_dir / "5.2 - Chapter Five Two-parsed.txt").exists())

    def test_clears_cached_mp3_in_cache_dir(self):
        """chapter-specific clear removes the chapter's cached MP3 from the cache dir."""
        self._run_chapter_specific_clear(["5.1"])

        self.assertFalse((self.cache_book_dir / "5.1 - Chapter Five One.mp3").exists())

    def test_preserves_cached_mp3_of_other_chapters(self):
        """chapter-specific clear must not remove other chapters' cached MP3."""
        self._run_chapter_specific_clear(["5.1"])

        self.assertTrue((self.cache_book_dir / "5.2 - Chapter Five Two.mp3").exists())

    def test_clears_output_mp3_for_selected_chapter(self):
        """chapter-specific clear removes the chapter's final output MP3."""
        self._run_chapter_specific_clear(["5.1"])

        self.assertFalse((self.output_book_dir / "5.1 - Chapter Five One.mp3").exists())

    def test_preserves_output_mp3_of_other_chapters(self):
        """chapter-specific clear must not remove other chapters' output MP3."""
        self._run_chapter_specific_clear(["5.1"])

        self.assertTrue((self.output_book_dir / "5.2 - Chapter Five Two.mp3").exists())

    def test_clears_multiple_selected_chapters(self):
        """chapter-specific clear handles multiple chapter labels at once."""
        self._run_chapter_specific_clear(["5.1", "5.2"])

        self.assertFalse((self.text_dir / "5.1 - Chapter Five One-pre-tts.txt").exists())
        self.assertFalse((self.text_dir / "5.2 - Chapter Five Two-pre-tts.txt").exists())
        self.assertFalse((self.output_book_dir / "5.1 - Chapter Five One.mp3").exists())
        self.assertFalse((self.output_book_dir / "5.2 - Chapter Five Two.mp3").exists())

    def test_no_error_when_no_cached_files_exist(self):
        """chapter-specific clear is a no-op (no error) when files are already absent."""
        import shutil

        shutil.rmtree(self.cache_book_dir, ignore_errors=True)
        shutil.rmtree(self.output_book_dir, ignore_errors=True)

        # Should not raise
        self._run_chapter_specific_clear(["5.1"])

    def test_clears_stream_chunks_for_selected_chapter(self):
        """chapter-specific clear removes the EdgeTTS stream chunk dir to prevent resume."""
        self._run_chapter_specific_clear(["5.1"])

        self.assertFalse(self.stream_51.exists())

    def test_preserves_stream_chunks_of_other_chapters(self):
        """chapter-specific clear must not remove other chapters' stream chunks."""
        self._run_chapter_specific_clear(["5.1"])

        self.assertTrue(self.stream_52.exists())

    def test_clears_output_in_engine_suffix_dirs(self):
        """chapter-specific clear also removes MP3s from engine-suffix output dirs."""
        # Simulate an engine-suffix output dir (e.g. "Great Book_edge")
        edge_dir = self.output_dir / f"{self.safe_title}_edge"
        edge_dir.mkdir(parents=True)
        (edge_dir / "5.1 - Chapter Five One.mp3").write_bytes(b"edge mp3")
        (edge_dir / "5.2 - Chapter Five Two.mp3").write_bytes(b"edge mp3")

        self._run_chapter_specific_clear(["5.1"])

        self.assertFalse((edge_dir / "5.1 - Chapter Five One.mp3").exists())
        self.assertTrue((edge_dir / "5.2 - Chapter Five Two.mp3").exists())
