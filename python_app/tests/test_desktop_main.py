# -*- coding: utf-8 -*-
"""Tests for the desktop sidecar entry point.

Regression: static_ffmpeg used to cache its ~60 MB archive inside the
PyInstaller package directory (under the `_MEIxxxx` extraction dir), so every
relaunch re-downloaded the archive. `resolve_ffmpeg_cache_dir` anchors the
cache at `PERSISTENT_ROOT / .ffmpeg` so the download happens once.
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from python_app import desktop_main  # noqa: E402


class TestResolveFfmpegCacheDir(unittest.TestCase):
    def test_returns_platform_leaf_under_persistent_root(self):
        # Regression: static-ffmpeg extracts one level up from `download_dir`
        # and expects the binary at `<download_dir>/ffmpeg`. That only works
        # when the leaf directory matches the zip's internal platform name.
        with tempfile.TemporaryDirectory() as tmp:
            persistent = Path(tmp) / "persistent"
            persistent.mkdir()
            with patch.dict(
                "sys.modules",
                {"python_app.src.paths": MagicMock(PERSISTENT_ROOT=persistent)},
            ):
                got = desktop_main.resolve_ffmpeg_cache_dir()
            self.assertEqual(got, persistent / ".ffmpeg" / sys.platform)
            self.assertTrue((persistent / ".ffmpeg" / sys.platform).is_dir())

    def test_returns_none_on_import_failure(self):
        with patch.dict("sys.modules", {"python_app.src.paths": None}):
            got = desktop_main.resolve_ffmpeg_cache_dir()
        self.assertIsNone(got)


class TestDesktopEnvDefaults(unittest.TestCase):
    def test_env_defaults_only_apply_when_invoked(self):
        # Importing the module must NOT mutate os.environ — otherwise it leaks
        # DISABLE_PIPER_FALLBACK into unrelated tests (regression 2026-04-16).
        env_before = dict(os.environ)
        desktop_main._apply_desktop_env_defaults()
        self.assertEqual(os.environ.get("DISABLE_PIPER_FALLBACK"), "1")
        self.assertEqual(os.environ.get("EPUB_TO_MP3_ENGINE"), "edge")
        # Restore for other tests in this process.
        for k in ("DISABLE_PIPER_FALLBACK", "EPUB_TO_MP3_ENGINE"):
            if k not in env_before:
                os.environ.pop(k, None)
            else:
                os.environ[k] = env_before[k]


class TestSetupFfmpeg(unittest.TestCase):
    def test_passes_cache_dir_when_available(self):
        fake_ffmpeg = MagicMock()
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / ".ffmpeg"
            cache.mkdir()
            with (
                patch.dict("sys.modules", {"static_ffmpeg": fake_ffmpeg}),
                patch.object(desktop_main, "resolve_ffmpeg_cache_dir", return_value=cache),
            ):
                desktop_main.setup_ffmpeg()
            fake_ffmpeg.add_paths.assert_called_once_with(download_dir=str(cache))

    def test_falls_back_to_default_when_cache_dir_none(self):
        fake_ffmpeg = MagicMock()
        with (
            patch.dict("sys.modules", {"static_ffmpeg": fake_ffmpeg}),
            patch.object(desktop_main, "resolve_ffmpeg_cache_dir", return_value=None),
        ):
            desktop_main.setup_ffmpeg()
        fake_ffmpeg.add_paths.assert_called_once_with()

    def test_is_noop_when_static_ffmpeg_not_installed(self):
        # Force the import to fail by assigning a sentinel that raises on import.
        sentinel = sys.modules.pop("static_ffmpeg", None)
        try:
            with patch.dict("sys.modules", {"static_ffmpeg": None}):
                # patch.dict with None means the import will raise ImportError.
                desktop_main.setup_ffmpeg()  # must not raise
        finally:
            if sentinel is not None:
                sys.modules["static_ffmpeg"] = sentinel


if __name__ == "__main__":
    unittest.main()
