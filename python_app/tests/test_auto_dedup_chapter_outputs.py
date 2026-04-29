"""Pre-validation pass collapses duplicate MP3s sharing a chapter label.

Older runs left two files on disk for the same chapter when filename
truncation drifted between conversions; the v0.3.16 auto-fix runs a
dedup pass *before* validate_book so the validator sees a clean
inventory. Without this, validate_book reports phantom dups and the
retry loop re-synthesises chapters that are already covered.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src._validation_mixin import _ValidationMixin


class _Host(_ValidationMixin):
    def __init__(self):
        self.verbose = False


class TestAutoDedupChapterOutputs(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.host = _Host()

    def tearDown(self) -> None:
        import shutil

        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_no_op_when_each_chapter_has_one_mp3(self):
        for label in ("1", "2", "3"):
            (self.tmp / f"{label} - Cap {label}.mp3").write_bytes(b"\xff\xfb" + b"x" * 1000)
        removed = self.host._dedup_chapter_outputs(self.tmp)
        self.assertEqual(removed, 0)
        self.assertEqual(len(list(self.tmp.glob("*.mp3"))), 3)

    def test_keeps_longer_audio_drops_shorter(self):
        # Two files for chapter "7.1": short (60s) and long (1500s).
        # Mock ffprobe to return predictable durations.
        short_file = self.tmp / "7.1 - Parte dois old truncate.mp3"
        long_file = self.tmp / "7.1 - Parte dois - newer longer name [abc1234567].mp3"
        short_file.write_bytes(b"\xff\xfb" + b"s" * 1000)
        long_file.write_bytes(b"\xff\xfb" + b"L" * 5000)

        durations = {short_file: 60.0, long_file: 1500.0}

        def fake_run(args, **kwargs):
            from unittest.mock import MagicMock

            target = Path(args[-1])
            result = MagicMock()
            result.stdout = f"{durations.get(target, 0.0):.3f}\n"
            result.returncode = 0
            return result

        with patch(
            "subprocess.run",
            side_effect=fake_run,
        ):
            removed = self.host._dedup_chapter_outputs(self.tmp)

        self.assertEqual(removed, 1)
        self.assertTrue(long_file.exists())
        self.assertFalse(short_file.exists())

    def test_does_not_match_files_without_label_prefix(self):
        # A file without the `<label> - ` prefix must be left alone.
        loose = self.tmp / "introduction.mp3"
        loose.write_bytes(b"\xff\xfb" + b"x" * 1000)
        removed = self.host._dedup_chapter_outputs(self.tmp)
        self.assertEqual(removed, 0)
        self.assertTrue(loose.exists())

    def test_handles_missing_output_dir(self):
        ghost = self.tmp / "does-not-exist"
        self.assertEqual(self.host._dedup_chapter_outputs(ghost), 0)


if __name__ == "__main__":
    unittest.main()
