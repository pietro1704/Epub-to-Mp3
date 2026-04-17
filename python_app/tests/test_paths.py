# -*- coding: utf-8 -*-
"""Tests for path resolution, frozen-bundle detection, and legacy-temp migration.

Regression: the desktop app is a PyInstaller one-file bundle. The bundle
extracts into a per-launch ``_MEIxxxx`` temp directory that macOS evicts
between runs. `get_project_root()` previously fell back to that temp dir,
anchoring jobs/cache/output there and losing them on every restart.
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src import paths as paths_module
from src.paths import (
    _find_legacy_frozen_roots,
    _looks_like_legacy_root,
    is_frozen_bundle,
    migrate_from_legacy_temp,
    user_data_dir,
)


class TestFrozenBundleDetection(unittest.TestCase):
    def test_unfrozen_python_returns_false(self):
        # Running from source: neither attribute is set.
        with (
            patch.object(sys, "frozen", False, create=True),
            patch.object(sys, "_MEIPASS", None, create=True),
        ):
            self.assertFalse(is_frozen_bundle())

    def test_frozen_without_meipass_returns_false(self):
        with (
            patch.object(sys, "frozen", True, create=True),
            patch.object(sys, "_MEIPASS", None, create=True),
        ):
            self.assertFalse(is_frozen_bundle())

    def test_frozen_with_meipass_returns_true(self):
        with (
            patch.object(sys, "frozen", True, create=True),
            patch.object(sys, "_MEIPASS", "/tmp/_MEIabc", create=True),
        ):
            self.assertTrue(is_frozen_bundle())


class TestUserDataDir(unittest.TestCase):
    def test_macos_path(self):
        with patch.object(sys, "platform", "darwin"):
            got = user_data_dir("Epub-to-Mp3")
        self.assertEqual(got, Path.home() / "Library" / "Application Support" / "Epub-to-Mp3")

    def test_linux_uses_xdg_when_set(self):
        with (
            patch.object(sys, "platform", "linux"),
            patch.object(os, "name", "posix"),
            patch.dict(os.environ, {"XDG_DATA_HOME": "/custom/xdg"}, clear=False),
        ):
            got = user_data_dir("Epub-to-Mp3")
        self.assertEqual(got, Path("/custom/xdg") / "Epub-to-Mp3")

    def test_linux_default_when_xdg_unset(self):
        env = {k: v for k, v in os.environ.items() if k != "XDG_DATA_HOME"}
        with (
            patch.object(sys, "platform", "linux"),
            patch.object(os, "name", "posix"),
            patch.dict(os.environ, env, clear=True),
        ):
            got = user_data_dir("Epub-to-Mp3")
        self.assertEqual(got, Path.home() / ".local" / "share" / "Epub-to-Mp3")

    @unittest.skipUnless(os.name == "nt", "WindowsPath cannot be instantiated on POSIX")
    def test_windows_uses_appdata(self):
        with patch.dict(os.environ, {"APPDATA": "C:\\Users\\u\\AppData\\Roaming"}, clear=False):
            got = user_data_dir("Epub-to-Mp3")
        self.assertEqual(got, Path("C:\\Users\\u\\AppData\\Roaming") / "Epub-to-Mp3")


class TestLegacyMigration(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.temp_root = Path(self.tmp.name)

    def _make_legacy_source(self, name: str, subdirs: dict[str, list[str]]) -> Path:
        src = self.temp_root / name
        src.mkdir(parents=True, exist_ok=True)
        for sub, files in subdirs.items():
            sub_path = src / sub
            sub_path.mkdir(parents=True, exist_ok=True)
            for f in files:
                (sub_path / f).write_text("payload")
        return src

    def test_looks_like_legacy_root_detects_non_empty_sentinel(self):
        src = self._make_legacy_source("_MEIabc", {"output": ["file.mp3"]})
        self.assertTrue(_looks_like_legacy_root(src))

    def test_looks_like_legacy_root_rejects_empty_sentinels(self):
        src = self._make_legacy_source("_MEIabc", {"output": [], ".cache": []})
        self.assertFalse(_looks_like_legacy_root(src))

    def test_looks_like_legacy_root_rejects_missing_sentinels(self):
        src = self._make_legacy_source("_MEIabc", {"python_app": ["x.py"]})
        self.assertFalse(_looks_like_legacy_root(src))

    def test_find_legacy_roots_sorts_newest_first(self):
        old = self._make_legacy_source("_MEIold", {"output": ["a.mp3"]})
        new = self._make_legacy_source("_MEInew", {"output": ["b.mp3"]})
        # Force old to actually be older.
        import time

        past = time.time() - 10_000
        os.utime(old, (past, past))
        roots = _find_legacy_frozen_roots(self.temp_root)
        self.assertEqual(roots[0], new)
        self.assertIn(old, roots)

    def test_migrate_copies_newest_source(self):
        older = self._make_legacy_source(
            "_MEIolder", {"output": ["old.mp3"], ".cache": ["c1"], ".jobs": ["j1.json"]}
        )
        newer = self._make_legacy_source(
            "_MEInewer", {"output": ["new.mp3"], ".cache": ["c2"], ".jobs": ["j2.json"]}
        )
        import time

        past = time.time() - 10_000
        os.utime(older, (past, past))

        target = self.temp_root / "stable"
        migrated = migrate_from_legacy_temp(target, temp_dir=self.temp_root)

        self.assertEqual(migrated, newer)
        self.assertTrue((target / "output" / "new.mp3").exists())
        self.assertTrue((target / ".cache" / "c2").exists())
        self.assertTrue((target / ".jobs" / "j2.json").exists())
        # Older root must NOT be merged in.
        self.assertFalse((target / "output" / "old.mp3").exists())

    def test_migrate_is_noop_when_target_has_content(self):
        self._make_legacy_source("_MEInewer", {"output": ["new.mp3"]})
        target = self.temp_root / "stable"
        (target / "output").mkdir(parents=True)
        (target / "output" / "preexisting.mp3").write_text("keep")

        migrated = migrate_from_legacy_temp(target, temp_dir=self.temp_root)

        self.assertIsNone(migrated)
        self.assertTrue((target / "output" / "preexisting.mp3").exists())
        self.assertFalse((target / "output" / "new.mp3").exists())

    def test_migrate_is_noop_when_no_legacy_sources(self):
        target = self.temp_root / "stable"
        migrated = migrate_from_legacy_temp(target, temp_dir=self.temp_root)
        self.assertIsNone(migrated)

    def test_migrate_does_not_overwrite_existing_subdir(self):
        self._make_legacy_source("_MEInewer", {"output": ["src.mp3"]})
        target = self.temp_root / "stable"
        (target / "output").mkdir(parents=True)
        (target / ".cache").mkdir(parents=True)
        (target / ".cache" / "seed").write_text("x")  # marks target as non-empty

        migrated = migrate_from_legacy_temp(target, temp_dir=self.temp_root)

        # Target was already non-empty → skip entirely.
        self.assertIsNone(migrated)
        self.assertFalse((target / "output" / "src.mp3").exists())


class TestPersistentRootResolution(unittest.TestCase):
    """Exercise the module-level `PERSISTENT_ROOT` resolution by reloading the
    module under controlled env/sys state.
    """

    def _reload(self):
        import importlib

        return importlib.reload(paths_module)

    def test_frozen_bundle_resolves_to_user_data_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_home = Path(tmp) / "home"
            fake_home.mkdir()
            env = {k: v for k, v in os.environ.items() if k not in {"PERSISTENT_ROOT", "SPACE_ID"}}
            env["HOME"] = str(fake_home)
            with (
                patch.dict(os.environ, env, clear=True),
                patch.object(sys, "frozen", True, create=True),
                patch.object(sys, "_MEIPASS", "/tmp/_MEIxxx", create=True),
                patch.object(sys, "platform", "darwin"),
            ):
                reloaded = self._reload()
                try:
                    self.assertEqual(
                        reloaded.PERSISTENT_ROOT,
                        fake_home / "Library" / "Application Support" / "Epub-to-Mp3",
                    )
                    # Cache/output land inside the stable dir, not PROJECT_ROOT.
                    self.assertTrue(reloaded.CACHE_DIR.is_relative_to(reloaded.PERSISTENT_ROOT))
                    self.assertTrue(reloaded.OUTPUT_DIR.is_relative_to(reloaded.PERSISTENT_ROOT))
                finally:
                    # Restore real env for other tests.
                    self._reload()

    def test_unfrozen_keeps_project_root(self):
        env = {k: v for k, v in os.environ.items() if k not in {"PERSISTENT_ROOT", "SPACE_ID"}}
        with (
            patch.dict(os.environ, env, clear=True),
            patch.object(sys, "frozen", False, create=True),
        ):
            reloaded = self._reload()
            try:
                self.assertEqual(reloaded.PERSISTENT_ROOT, reloaded.PROJECT_ROOT)
            finally:
                self._reload()

    def test_persistent_root_override_beats_frozen_detection(self):
        with tempfile.TemporaryDirectory() as tmp:
            override = Path(tmp) / "override"
            env = {k: v for k, v in os.environ.items() if k != "SPACE_ID"}
            env["PERSISTENT_ROOT"] = str(override)
            with (
                patch.dict(os.environ, env, clear=True),
                patch.object(sys, "frozen", True, create=True),
                patch.object(sys, "_MEIPASS", "/tmp/_MEIxxx", create=True),
            ):
                reloaded = self._reload()
                try:
                    self.assertEqual(reloaded.PERSISTENT_ROOT, override.resolve())
                finally:
                    self._reload()


if __name__ == "__main__":
    unittest.main()
