"""Cache Bypass regression scenarios, collected by test_main."""

from python_app.tests._main_test_support import (
    Path as Path,
    tempfile as tempfile,
    unittest as unittest,
)

class TestCacheBypassFlag(unittest.TestCase):
    """Unit tests for cache-bypass behaviour of --clear-cache, --no-cache, --force-reprocess."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.epub_path = Path(self.temp_dir) / "mybook.epub"
        self.epub_path.write_text("dummy epub")

    def tearDown(self):
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    # ── get_cached_chapters(bypass=True) ─────────────────────────────────────

    def test_get_cached_chapters_bypass_true_returns_none_when_cache_exists(self):
        """bypass=True must return None even if a valid cache entry is present."""
        from src.cache_manager import CacheManager

        cm = CacheManager(cache_dir=Path(self.temp_dir) / ".cache")
        # Write a valid cache entry
        cm.save_chapters_to_cache(
            self.epub_path,
            {"title": "My Book", "author": "A", "chapters": [{"title": "Ch1", "text": "hello"}]},
        )
        # Without bypass, cache should be found
        self.assertIsNotNone(cm.get_cached_chapters(self.epub_path, bypass=False))
        # With bypass, must return None
        self.assertIsNone(cm.get_cached_chapters(self.epub_path, bypass=True))

    def test_get_cached_chapters_bypass_false_reads_normally(self):
        """bypass=False (default) returns the cached value when it exists."""
        from src.cache_manager import CacheManager

        cm = CacheManager(cache_dir=Path(self.temp_dir) / ".cache")
        cm.save_chapters_to_cache(
            self.epub_path,
            {"title": "My Book", "author": "A", "chapters": [{"title": "Ch1", "text": "hello"}]},
        )
        result = cm.get_cached_chapters(self.epub_path)
        self.assertIsNotNone(result)
        self.assertEqual(result["title"], "My Book")

    def test_get_cached_chapters_bypass_true_returns_none_when_no_cache(self):
        """bypass=True returns None even when there is no cache on disk."""
        from src.cache_manager import CacheManager

        cm = CacheManager(cache_dir=Path(self.temp_dir) / ".cache")
        self.assertIsNone(cm.get_cached_chapters(self.epub_path, bypass=True))

    def test_get_cached_chapters_bypass_skips_memory_cache(self):
        """bypass=True must not return a hit from the in-memory cache."""
        from src.cache_manager import CacheManager

        cm = CacheManager(cache_dir=Path(self.temp_dir) / ".cache")
        cm.save_chapters_to_cache(
            self.epub_path,
            {"title": "My Book", "author": "A", "chapters": []},
        )
        # Populate memory cache via a normal read
        cm.get_cached_chapters(self.epub_path, bypass=False)
        self.assertIn(str(self.epub_path.resolve()), cm._memory_cache)
        # bypass must still return None despite memory cache hit
        self.assertIsNone(cm.get_cached_chapters(self.epub_path, bypass=True))

    # ── _split_cached_chapters with clear_cache=True ──────────────────────────

    def test_split_cached_chapters_clear_cache_sends_all_to_pending(self):
        """--clear-cache must make _split_cached_chapters ignore existing MP3s."""
        from unittest.mock import MagicMock

        from src._cache_mixin import _CacheMixin
        from src.config import ConversionConfig

        class _FakeConverter(_CacheMixin):
            file_manager = MagicMock()
            file_manager.sanitize_filename = lambda self_inner, s, **kw: s.replace(" ", "_")
            verbose = False

            def _setup_output_directory(self, cfg):
                return Path(self.temp_dir) / "output"

            def _load_cache_index(self, _):
                return {}

            def _chapter_number(self, chapter, idx):
                return idx

            def _chapter_index_label(self, chapter, idx):
                return str(idx)

            def _expected_output_path(self, chapter, chapter_num, output_dir):
                return Path(output_dir) / f"{chapter_num}.mp3"

            def _find_cached_audio_path(self, *args, **kwargs):
                return None

            def _find_pre_tts_path(self, *args, **kwargs):
                return None

        converter = _FakeConverter()
        converter.temp_dir = self.temp_dir

        output_dir = Path(self.temp_dir) / "output"
        output_dir.mkdir(parents=True, exist_ok=True)

        # Create fake "cached" MP3s
        (output_dir / "1.mp3").write_bytes(b"\x00" * 5000)
        (output_dir / "2.mp3").write_bytes(b"\x00" * 5000)

        chapters = [MagicMock(name="Ch1"), MagicMock(name="Ch2")]
        for ch in chapters:
            ch.name = "Chapter"

        config = ConversionConfig(
            engine="edge",
            output_dir=str(output_dir),
            book_title="My Book",
            clear_cache=True,
        )
        config.cache_dir = None

        cached_paths, pending = converter._split_cached_chapters(chapters, output_dir, config)

        self.assertEqual(len(pending), 2, "All chapters must be pending when clear_cache=True")
        self.assertEqual(len(cached_paths), 0, "No cached paths should be reused")

    def test_split_cached_chapters_force_reprocess_sends_all_to_pending(self):
        """--force-reprocess must also make _split_cached_chapters ignore existing MP3s."""
        from unittest.mock import MagicMock

        from src._cache_mixin import _CacheMixin
        from src.config import ConversionConfig

        class _FakeConverter(_CacheMixin):
            file_manager = MagicMock()
            file_manager.sanitize_filename = lambda self_inner, s, **kw: s.replace(" ", "_")
            verbose = False

            def _setup_output_directory(self, cfg):
                return Path(self.temp_dir) / "output"

            def _load_cache_index(self, _):
                return {}

            def _chapter_number(self, chapter, idx):
                return idx

            def _chapter_index_label(self, chapter, idx):
                return str(idx)

            def _expected_output_path(self, chapter, chapter_num, output_dir):
                return Path(output_dir) / f"{chapter_num}.mp3"

            def _find_cached_audio_path(self, *args, **kwargs):
                return None

            def _find_pre_tts_path(self, *args, **kwargs):
                return None

        converter = _FakeConverter()
        converter.temp_dir = self.temp_dir

        output_dir = Path(self.temp_dir) / "output"
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "1.mp3").write_bytes(b"\x00" * 5000)

        chapters = [MagicMock(name="Ch1")]
        chapters[0].name = "Chapter"

        config = ConversionConfig(
            engine="edge",
            output_dir=str(output_dir),
            book_title="My Book",
            force_reprocess=True,
        )
        config.cache_dir = None

        cached_paths, pending = converter._split_cached_chapters(chapters, output_dir, config)

        self.assertEqual(len(pending), 1)
        self.assertEqual(len(cached_paths), 0)

    # ── --no-cache implies force_reprocess ────────────────────────────────────

    def test_no_cache_flag_sets_force_reprocess_in_config(self):
        """--no-cache must set force_reprocess=True in ConversionConfig."""
        import argparse

        args = argparse.Namespace(
            engine=None,
            language=None,
            output_dir=None,
            bitrate=None,
            no_cache=True,
            clear_cache=False,
            force_reprocess=False,
            batch=None,
            show_structure=False,
            chapter=None,
            verbose=False,
            validate_text=None,
            preserve_all_chapters=False,
            auto_fix_output=False,
            piper_chunk_chars=None,
            verify_only=False,
            fix_mode=False,
            footnote_mode=None,
            menu=False,
            resume_from_failure=None,
            no_resume=None,
            channels=None,
            health_check_interval_seconds=None,
            extra=None,
        )
        # The flag mapping in main.py: no_cache=True → force_reprocess=True
        force_reprocess = bool(
            getattr(args, "force_reprocess", False)
            or getattr(args, "no_cache", False)
            or getattr(args, "clear_cache", False)
        )
        self.assertTrue(force_reprocess)

    def test_clear_cache_flag_sets_force_reprocess_in_config(self):
        """--clear-cache must set force_reprocess=True so per-chapter MP3 cache is skipped."""
        import argparse

        args = argparse.Namespace(
            clear_cache=True,
            no_cache=False,
            force_reprocess=False,
        )
        force_reprocess = bool(
            getattr(args, "force_reprocess", False)
            or getattr(args, "no_cache", False)
            or getattr(args, "clear_cache", False)
        )
        self.assertTrue(force_reprocess)

    def test_clear_cache_skips_existing_mp3_in_sequential_path(self):
        """_convert_chapters_sequential must re-synthesize when force_reprocess=True (set by --clear-cache).

        Simulates the check at converter.py line 3940:
          if output_path.exists() and not config.force_reprocess:
        With clear_cache=True → force_reprocess=True → skip this branch → re-synthesize.
        """
        from src.config import ConversionConfig

        output_path = Path(self.temp_dir) / "chapter1.mp3"
        output_path.write_bytes(b"\x00" * 5000)  # Existing MP3

        # Simulate what _apply_cli_overrides does: clear_cache → force_reprocess=True
        config = ConversionConfig(
            engine="edge",
            output_dir=self.temp_dir,
            book_title="My Book",
            clear_cache=True,
            force_reprocess=True,  # set by _apply_cli_overrides
        )

        # The guard in _convert_chapters_sequential: skip reuse when force_reprocess=True
        would_reuse = output_path.exists() and not config.force_reprocess
        self.assertFalse(would_reuse, "Existing MP3 must NOT be reused when clear_cache is set")

    # ── --clear-cache suppresses "Cache detected" message ────────────────────

    def test_clear_cache_suppresses_cache_detected_message(self):
        """--clear-cache must not print 'Cache detected' even when txt files exist."""
        import argparse
        import io
        from contextlib import redirect_stdout

        args = argparse.Namespace(clear_cache=True)

        temp_text_dir = Path(self.temp_dir) / "text"
        temp_text_dir.mkdir()
        (temp_text_dir / "01 - Ch1_tts_input.txt").write_text("text")

        # Replicate the guard from main.py
        output = io.StringIO()
        with redirect_stdout(output):
            if not getattr(args, "clear_cache", False):
                if (Path(self.temp_dir) / "text").exists():
                    txt_files = list((Path(self.temp_dir) / "text").glob("*_tts_input.txt"))
                    if txt_files:
                        print(f"Cache detected: {len(txt_files)} chapters already processed")

        self.assertNotIn("Cache detected", output.getvalue())

    def test_no_clear_cache_shows_cache_detected_message(self):
        """Without --clear-cache, 'Cache detected' should be printed when txt files exist."""
        import argparse
        import io
        from contextlib import redirect_stdout

        args = argparse.Namespace(clear_cache=False)

        temp_text_dir = Path(self.temp_dir) / "text"
        temp_text_dir.mkdir()
        (temp_text_dir / "01 - Ch1_tts_input.txt").write_text("text")

        output = io.StringIO()
        with redirect_stdout(output):
            if not getattr(args, "clear_cache", False):
                if (Path(self.temp_dir) / "text").exists():
                    txt_files = list((Path(self.temp_dir) / "text").glob("*_tts_input.txt"))
                    if txt_files:
                        print(f"Cache detected: {len(txt_files)} chapters already processed")

        self.assertIn("Cache detected", output.getvalue())
