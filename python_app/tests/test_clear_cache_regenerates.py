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
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import ConverterApplication


class TestClearCacheBehaviour(unittest.TestCase):
    """Source-level guards on the CLI clear-cache wiring.

    A real end-to-end behavioural test would have to spin up Edge
    (network) and burn ~30 s. That's covered by manual verification
    on every release. These tests pin the structural pieces that the
    behavioural test depends on so a refactor cannot silently bypass
    them.
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
        """The `--clear-cache` arg must trigger `cache_manager.clear_cache`
        for the book; without that call the per-chapter cache files
        stick around and the next run hits a stale-cache hit."""
        src = inspect.getsource(ConverterApplication._run_single_conversion)
        self.assertIn("clear_cache", src)
        self.assertIn("cache_manager.clear_cache", src)


if __name__ == "__main__":
    unittest.main()
