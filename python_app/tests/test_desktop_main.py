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
        try:
            desktop_main._apply_desktop_env_defaults()
            self.assertEqual(os.environ.get("DISABLE_PIPER_FALLBACK"), "1")
            self.assertEqual(os.environ.get("EPUB_TO_MP3_ENGINE"), "edge")
        finally:
            # Hard restore — every key the function might setdefault must
            # be reverted, not just the two listed above. A blanket
            # snapshot/restore catches new toggles (e.g. DISABLE_AUTO_RECOVERY)
            # without forcing this test to enumerate them.
            os.environ.clear()
            os.environ.update(env_before)


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


class TestDesktopEnvDefaultsToggleSet(unittest.TestCase):
    """`_apply_desktop_env_defaults()` populates env vars the desktop
    sidecar relies on. Regressions here have stranded every submitted
    job in `queued` (AutoRecovery raising KeyboardInterrupt in idle
    request workers) — these tests guard the toggles."""

    def _run_in_clean_env(self, keys):
        # Snapshot the FULL env. _apply_desktop_env_defaults() may
        # setdefault any number of keys; only a snapshot+restore is
        # guaranteed to leave the test environment untouched.
        env_before = dict(os.environ)
        for k in keys:
            os.environ.pop(k, None)
        try:
            desktop_main._apply_desktop_env_defaults()
            captured = {k: os.environ.get(k) for k in keys}
        finally:
            os.environ.clear()
            os.environ.update(env_before)
        return captured

    def test_disables_piper_fallback(self):
        env = self._run_in_clean_env(["DISABLE_PIPER_FALLBACK"])
        self.assertEqual(env["DISABLE_PIPER_FALLBACK"], "1")

    def test_forces_edge_engine(self):
        env = self._run_in_clean_env(["EPUB_TO_MP3_ENGINE"])
        self.assertEqual(env["EPUB_TO_MP3_ENGINE"], "edge")

    def test_disables_auto_recovery_by_default(self):
        # Regression: AutoRecovery interpreted the sidecar's idle
        # ThreadPoolExecutor workers as "stuck" and KeyboardInterrupt'd
        # them, killing FastAPI's request-handling pool. The desktop
        # default must opt out.
        env = self._run_in_clean_env(["DISABLE_AUTO_RECOVERY"])
        self.assertEqual(env["DISABLE_AUTO_RECOVERY"], "1")

    def test_setdefault_does_not_override_user_value(self):
        # Power users can re-enable AutoRecovery (or any toggle) by
        # exporting the env var before launching the sidecar.
        env_before = dict(os.environ)
        os.environ["DISABLE_AUTO_RECOVERY"] = "0"
        try:
            desktop_main._apply_desktop_env_defaults()
            self.assertEqual(os.environ["DISABLE_AUTO_RECOVERY"], "0")
        finally:
            os.environ.clear()
            os.environ.update(env_before)


if __name__ == "__main__":
    unittest.main()
