"""iPhone export via iCloud Drive container.

Pins the contract for `iphone_export.export_book_to_iphone`:
* Copies every MP3 from the source dir into ``<container>/<book>/``.
* Returns ``(False, reason)`` for missing dirs / empty source / no
  container, never raises into the caller.
* Honours the ``IPHONE_EXPORT_DIR`` override and the
  ``EXPORT_TO_IPHONE`` env flag parser.
"""

from __future__ import annotations

import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from python_app.src.iphone_export import (
    default_export_root,
    export_book_to_iphone,
    is_export_target_available,
    is_macos,
    parse_env_flag,
)


class TestExportFlagParsing(unittest.TestCase):
    def test_truthy_values_enable_export(self):
        for value in ("1", "true", "TRUE", "yes", "on", "On"):
            self.assertTrue(parse_env_flag(value), f"{value!r} should be truthy")

    def test_falsy_values_keep_export_off(self):
        for value in ("0", "false", "no", "off", "", None, "  "):
            self.assertFalse(parse_env_flag(value), f"{value!r} should be falsy")


class TestDefaultExportRoot(unittest.TestCase):
    def test_uses_env_override_when_set(self):
        with patch.dict(os.environ, {"IPHONE_EXPORT_DIR": "/tmp/custom-iphone-target"}):
            self.assertEqual(default_export_root(), Path("/tmp/custom-iphone-target"))

    def test_falls_back_to_icloud_container_path(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("IPHONE_EXPORT_DIR", None)
            target = default_export_root()
            self.assertIn("Mobile Documents", str(target))
            self.assertIn("biomsoft", str(target))
            self.assertTrue(str(target).endswith("Documents"))


class TestExportBookToIphone(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.output_dir = self.tmp / "output"
        self.output_dir.mkdir()
        # Fake iCloud container — its parent must exist so the writability
        # check passes; the destination dir itself is created by export.
        self.container = self.tmp / "iCloud~fake" / "Documents"
        self.container.parent.mkdir(parents=True)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _make_mp3(self, name: str = "1 - Cap.mp3") -> Path:
        path = self.output_dir / name
        path.write_bytes(b"\xff\xfb" + b"x" * 1000)
        return path

    def test_copies_every_mp3_into_book_subfolder(self):
        for n in (1, 2, 3):
            self._make_mp3(f"{n} - Cap {n}.mp3")
        ok, error = export_book_to_iphone(self.output_dir, "My Book", target_root=self.container)
        self.assertTrue(ok, error)
        self.assertIsNone(error)
        dest = self.container / "My Book"
        copied = sorted(p.name for p in dest.glob("*.mp3"))
        self.assertEqual(copied, ["1 - Cap 1.mp3", "2 - Cap 2.mp3", "3 - Cap 3.mp3"])

    def test_overwrites_existing_files(self):
        # Pre-populate destination with stale content so we can assert
        # the second export refreshes it instead of skipping.
        dest = self.container / "Book"
        dest.mkdir(parents=True)
        stale = dest / "1 - Cap.mp3"
        stale.write_bytes(b"old")

        new = self._make_mp3()
        ok, _ = export_book_to_iphone(self.output_dir, "Book", target_root=self.container)
        self.assertTrue(ok)
        self.assertEqual((dest / new.name).read_bytes(), new.read_bytes())

    def test_returns_error_when_output_dir_is_empty(self):
        ok, error = export_book_to_iphone(self.output_dir, "Empty", target_root=self.container)
        self.assertFalse(ok)
        assert error is not None
        self.assertIn("no MP3", error)

    def test_returns_error_when_output_dir_is_missing(self):
        ghost = self.tmp / "ghost"
        ok, error = export_book_to_iphone(ghost, "X", target_root=self.container)
        self.assertFalse(ok)
        assert error is not None
        self.assertIn("not found", error)

    def test_returns_error_when_container_parent_is_missing(self):
        # Container's parent doesn't exist → likely no MP3AudioBookPlayer
        # installed; surface a specific error instead of silently failing.
        self._make_mp3()
        missing = self.tmp / "no-such-bundle" / "Documents"
        ok, error = export_book_to_iphone(self.output_dir, "Book", target_root=missing)
        self.assertFalse(ok)
        assert error is not None
        self.assertIn("iCloud container not found", error)

    def test_book_title_with_slash_is_sanitised(self):
        # `/` would escape the container; we replace it with `_`.
        self._make_mp3()
        ok, _ = export_book_to_iphone(self.output_dir, "Bad/Title", target_root=self.container)
        self.assertTrue(ok)
        self.assertTrue((self.container / "Bad_Title").exists())
        self.assertFalse((self.container / "Bad").exists())

    def test_falls_back_to_output_dir_name_when_title_blank(self):
        self._make_mp3()
        ok, _ = export_book_to_iphone(self.output_dir, "", target_root=self.container)
        self.assertTrue(ok)
        # output_dir is `<tmp>/output`, so the destination uses `output`.
        self.assertTrue((self.container / "output").exists())


class TestExportTargetAvailability(unittest.TestCase):
    def test_returns_true_when_parent_exists_and_writable(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "Documents"
            self.assertTrue(is_export_target_available(target))

    def test_returns_false_when_parent_missing(self):
        self.assertFalse(is_export_target_available(Path("/no/such/path/Documents")))


class TestPlatformGuard(unittest.TestCase):
    def test_macos_detection(self):
        # The function just inspects sys.platform — no side effects.
        # We don't assert a specific value because CI may run on linux,
        # but the call must not raise.
        result = is_macos()
        self.assertIsInstance(result, bool)


if __name__ == "__main__":
    unittest.main()
