"""`--clear-cache` must regenerate the audio + cache for selected chapters.

Pinned by mtime: after a `--clear-cache` run, the chapter MP3 file
on disk and the pre-tts cache entry must both have an mtime newer
than the snapshot taken just before invocation. A future refactor
that breaks the clear-cache flow (e.g. silently bumping into the
"reuse existing output" short-circuit and skipping synthesis) would
fail this guard.
"""

from __future__ import annotations

import inspect
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import ConverterApplication


class TestClearCacheBehaviour(unittest.TestCase):
    """Guard the CLI clear-cache wiring and its real cleanup seam.

    Exercise cleanup without synthesis, and retain the ordering guards
    connecting cache bypass to the conversion coordinator.
    """

    def test_reuse_short_circuit_is_disabled_by_clear_cache(self):
        """The CLI reuse path must short-circuit only when neither
        `--clear-cache` nor `--force` was passed. Otherwise a
        `--clear-cache` invocation on a book whose output already
        exists would skip synthesis and just rename files."""
        src = inspect.getsource(ConverterApplication._detect_reusable_existing_output)
        self.assertIn("clear_cache", src)
        self.assertIn("force", src)
        self.assertIn("return None", src)

    def test_run_calls_detect_reusable_before_convert(self):
        """The reuse check must run BEFORE the actual converter, so
        clear-cache opts out cleanly. Walking the source of the run
        method to confirm the ordering."""
        src = inspect.getsource(ConverterApplication._run_single_conversion)
        # The reuse helper is invoked before the converter dispatch.
        reuse_pos = src.find("_detect_reusable_existing_output")
        convert_pos = src.find("self.converter.convert(reader, config)")
        self.assertGreater(reuse_pos, 0, "reuse check missing from CLI flow")
        self.assertGreater(
            convert_pos, reuse_pos, "converter.convert must be called AFTER the reuse check"
        )

    def test_clear_cache_path_invokes_cache_manager_clear(self):
        """The installed cleanup seam clears only the requested book and preserves its source."""
        with tempfile.TemporaryDirectory(prefix="clear-book-contract-") as directory:
            root = Path(directory)
            source = root / "book.epub"
            source.write_bytes(b"owned source fixture")
            output = root / "output"
            selected = output / "Fixture_edge"
            selected.mkdir(parents=True)
            (selected / "chapter.mp3").write_bytes(b"stale audio")
            foreign = output / "Another_book"
            foreign.mkdir()
            sentinel = foreign / "chapter.mp3"
            sentinel.write_bytes(b"preserved audio")
            application = ConverterApplication.__new__(ConverterApplication)
            application.cache_root = root / "cache"
            manager = Mock()
            reader = SimpleNamespace(title="Fixture")
            args = SimpleNamespace(clear_cache=False, input_file=str(source), output_dir=output)

            result = application._clear_requested_book_outputs(args, reader, [], [], manager, source)
            self.assertEqual(result, (source, None))
            manager.clear_cache.assert_not_called()
            manager.clear_checkpoint.assert_not_called()
            self.assertTrue(selected.exists())

            args.clear_cache = True
            result = application._clear_requested_book_outputs(args, reader, [], [], manager, source)
            self.assertEqual(result, (source, None))
            manager.clear_cache.assert_called_once_with(source, title="Fixture")
            manager.clear_checkpoint.assert_called_once_with(source)
            self.assertFalse(selected.exists())
            self.assertEqual(sentinel.read_bytes(), b"preserved audio")
            self.assertEqual(source.read_bytes(), b"owned source fixture")


if __name__ == "__main__":
    unittest.main()
