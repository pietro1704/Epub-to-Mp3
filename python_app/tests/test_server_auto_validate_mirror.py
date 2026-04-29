"""Server-side auto-dedup mirrors the CLI's `_dedup_chapter_outputs`.

The CLI runs validation + dedup at the end of every conversion (v0.3.14
auto_validate_output default + v0.3.16 auto-dedup pre-pass). Web jobs
skipped both until v0.3.17, so the same Carl-style accumulation of
duplicate MP3s could happen on the server path without anyone noticing.

These tests exercise the new `_server_dedup_chapter_outputs` helper in
`server.py` directly; they don't drive a full HTTP conversion (the
`process_conversion` async pipeline is too heavy for unit tests). The
contract pinned here matches the CLI counterpart so the two paths
can't drift.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from python_app import server


class TestServerDedupChapterOutputs(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self) -> None:
        import shutil

        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_no_op_on_clean_directory(self):
        for label in ("1", "2", "3"):
            (self.tmp / f"{label} - Cap {label}.mp3").write_bytes(b"\xff\xfb" + b"x" * 1000)
        self.assertEqual(server._server_dedup_chapter_outputs(self.tmp), 0)
        self.assertEqual(len(list(self.tmp.glob("*.mp3"))), 3)

    def test_keeps_longest_drops_shorter(self):
        short = self.tmp / "7.1 - old short.mp3"
        long_ = self.tmp / "7.1 - newer longer with hash [abcd1234ef].mp3"
        short.write_bytes(b"\xff\xfb" + b"s" * 1000)
        long_.write_bytes(b"\xff\xfb" + b"L" * 5000)

        durations = {short: 60.0, long_: 1500.0}

        def fake_run(args, **kwargs):
            from unittest.mock import MagicMock

            target = Path(args[-1])
            r = MagicMock()
            r.stdout = f"{durations.get(target, 0.0):.3f}\n"
            r.returncode = 0
            return r

        with patch("subprocess.run", side_effect=fake_run):
            removed = server._server_dedup_chapter_outputs(self.tmp)

        self.assertEqual(removed, 1)
        self.assertTrue(long_.exists())
        self.assertFalse(short.exists())

    def test_falls_back_to_file_size_when_ffprobe_fails(self):
        small = self.tmp / "5.1 - tiny.mp3"
        big = self.tmp / "5.1 - big.mp3"
        small.write_bytes(b"\xff\xfb" + b"s" * 1000)
        big.write_bytes(b"\xff\xfb" + b"B" * 50000)

        def fake_run(*_args, **_kw):
            raise FileNotFoundError("ffprobe missing")

        with patch("subprocess.run", side_effect=fake_run):
            removed = server._server_dedup_chapter_outputs(self.tmp)

        self.assertEqual(removed, 1)
        self.assertTrue(big.exists())
        self.assertFalse(small.exists())

    def test_handles_missing_output_dir(self):
        ghost = self.tmp / "ghost"
        self.assertEqual(server._server_dedup_chapter_outputs(ghost), 0)

    def test_ignores_files_without_label_prefix(self):
        (self.tmp / "intro.mp3").write_bytes(b"\xff\xfb" + b"x" * 1000)
        self.assertEqual(server._server_dedup_chapter_outputs(self.tmp), 0)


if __name__ == "__main__":
    unittest.main()
