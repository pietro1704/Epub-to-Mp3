"""Cache lookup matches MP3s on chapter index prefix, not full title.

Two consecutive Carl conversions used slightly different EPUB metadata
titles (one upper-case, one lower-case) and produced parallel sets of
MP3 files in the same output directory. The cache-hit logic is now
allowed to match by the chapter's index label (e.g. "7.13 - "), which
is stable regardless of which run produced the file.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src._cache_mixin import _CacheMixin
from src._output_file_mixin import _OutputFileMixin
from src.config import ConversionConfig
from src.utils import FileManager


class _Chapter:
    """Minimal duck-typed Chapter — the mixin only reads `name` and `index`."""

    def __init__(self, name: str, index):
        self.name = name
        self.index = index


class _Host(_CacheMixin, _OutputFileMixin):
    """Bare host: pulls in just the two mixins under test."""

    def __init__(self) -> None:
        self.file_manager = FileManager()


class TestIndexPrefixDiscovery(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.host = _Host()
        # `_split_cached_chapters` calls `_setup_output_directory(config)`;
        # we monkeypatch it on the instance to avoid hitting real paths.
        self.host._setup_output_directory = lambda cfg: self.tmp

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _config(self) -> ConversionConfig:
        # `cache_dir=None` short-circuits the audio-bucket lookup so the
        # test exercises the new index-prefix branch only.
        return ConversionConfig(
            engine="edge",
            cache_dir=None,
            output_dir=self.tmp,
        )

    def test_finds_existing_mp3_with_different_truncation(self):
        """The disk has the chapter under a slightly different (older)
        filename — the cache lookup must find it via the index prefix
        and skip re-conversion."""
        existing = self.tmp / "7.13 - Parte dois - Capítulo 40 - older truncation.mp3"
        existing.write_bytes(b"\xff\xfb" + b"\x00" * 5000)

        chapter = _Chapter(
            name="7.13 - Parte dois - Capítulo 40 - newer longer name with extra words",
            index="7.13",
        )
        cached, pending = self.host._split_cached_chapters([chapter], self.tmp, self._config())
        # Found via prefix scan, not via exact name.
        self.assertEqual(len(cached), 1)
        self.assertEqual(len(pending), 0)
        self.assertEqual(cached[0], existing)

    def test_does_not_match_other_chapters_with_similar_prefix(self):
        """`7.1 - …` must NOT match a request for chapter `7.13 - …`."""
        intruder = self.tmp / "7.1 - Parte dois - Capítulo 28 - other chapter.mp3"
        intruder.write_bytes(b"\xff\xfb" + b"\x00" * 5000)

        chapter = _Chapter(
            name="7.13 - Parte dois - Capítulo 40 - the real one",
            index="7.13",
        )
        cached, pending = self.host._split_cached_chapters([chapter], self.tmp, self._config())
        # No match — the intruder has prefix "7.1 - " not "7.13 - ".
        self.assertEqual(len(cached), 0)
        self.assertEqual(len(pending), 1)

    def test_skips_zero_byte_files_via_prefix_match(self):
        """A truncated/empty MP3 with the right prefix is ignored — the
        chapter must be re-converted, not silently treated as cached."""
        empty = self.tmp / "7.13 - Parte dois - empty.mp3"
        empty.write_bytes(b"")

        chapter = _Chapter(
            name="7.13 - Parte dois - real",
            index="7.13",
        )
        cached, pending = self.host._split_cached_chapters([chapter], self.tmp, self._config())
        self.assertEqual(len(cached), 0)
        self.assertEqual(len(pending), 1)


if __name__ == "__main__":
    unittest.main()
