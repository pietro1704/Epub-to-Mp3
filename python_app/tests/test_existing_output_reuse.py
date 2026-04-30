"""Skip TTS when the audiobook is already on disk.

Re-running ``convert <book>`` shouldn't re-synthesise an audiobook the
user already has. The CLI now scans the resolved per-book output dir
and short-circuits when ≥90% of expected MP3s are present. The user
can opt back into a clean run via ``--clear-cache`` or ``--force``.

These tests pin the resolver helpers in isolation; the integration is
exercised by the CLI smoke tests.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


def _make_app():
    with patch("main.AudioConverter") as _audio, patch("main.MenuInterface") as _menu:
        _audio.return_value = MagicMock()
        _menu.return_value = MagicMock()
        from main import ConverterApplication

        return ConverterApplication()


def _fake_reader(title: str = "Carl"):
    return SimpleNamespace(title=title, language="pt-BR")


def _fake_items(n: int):
    return [
        SimpleNamespace(index=str(i), chapter=SimpleNamespace(text="x")) for i in range(1, n + 1)
    ]


def _fake_args(**kwargs):
    defaults = dict(clear_cache=False, force=False, chapter=None)
    defaults.update(kwargs)
    defaults.setdefault("from_chapter_to_chapter", None)
    defaults.setdefault("from_chapter_to_end", None)
    return SimpleNamespace(**defaults)


class TestDetectReusableExistingOutput(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp_root = Path(tempfile.mkdtemp(prefix="reuse-test-"))
        self.app = _make_app()

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp_root, ignore_errors=True)

    def _populate_output(self, book_dir_name: str, count: int) -> Path:
        out = self.tmp_root / book_dir_name
        out.mkdir(parents=True, exist_ok=True)
        for i in range(1, count + 1):
            p = out / f"{i} - chapter.mp3"
            p.write_bytes(b"AUDIO" * 100)
        return out

    def test_reuses_when_full_book_already_on_disk(self):
        out = self._populate_output("Carl", 10)
        items = _fake_items(10)
        config = SimpleNamespace(book_title="Carl", output_dir=str(self.tmp_root))
        args = _fake_args()

        result = self.app._detect_reusable_existing_output(
            _fake_reader("Carl"), items, config, args
        )
        self.assertEqual(result, out)

    def test_returns_none_when_directory_missing(self):
        items = _fake_items(10)
        config = SimpleNamespace(book_title="Missing", output_dir=str(self.tmp_root))
        args = _fake_args()
        result = self.app._detect_reusable_existing_output(
            _fake_reader("Missing"), items, config, args
        )
        self.assertIsNone(result)

    def test_returns_none_when_below_threshold(self):
        # Only 5 of 10 chapters → below 90% threshold → re-synthesise.
        self._populate_output("Carl", 5)
        items = _fake_items(10)
        config = SimpleNamespace(book_title="Carl", output_dir=str(self.tmp_root))
        args = _fake_args()
        result = self.app._detect_reusable_existing_output(
            _fake_reader("Carl"), items, config, args
        )
        self.assertIsNone(result)

    def test_clear_cache_skips_reuse(self):
        self._populate_output("Carl", 10)
        items = _fake_items(10)
        config = SimpleNamespace(book_title="Carl", output_dir=str(self.tmp_root))
        args = _fake_args(clear_cache=True)
        result = self.app._detect_reusable_existing_output(
            _fake_reader("Carl"), items, config, args
        )
        self.assertIsNone(result)

    def test_subset_selectors_skip_reuse(self):
        """Per-chapter or range runs need fresh data — full-book reuse
        check would be misleading."""
        self._populate_output("Carl", 10)
        items = _fake_items(10)
        config = SimpleNamespace(book_title="Carl", output_dir=str(self.tmp_root))
        for kw in (
            {"chapter": "1"},
            {"from_chapter_to_chapter": "1..3"},
            {"from_chapter_to_end": "5"},
        ):
            with self.subTest(kw=kw):
                args = _fake_args(**kw)
                result = self.app._detect_reusable_existing_output(
                    _fake_reader("Carl"), items, config, args
                )
                self.assertIsNone(result)

    def test_zero_byte_mp3s_are_ignored(self):
        out = self.tmp_root / "Carl"
        out.mkdir(parents=True, exist_ok=True)
        for i in range(1, 11):
            (out / f"{i} - chapter.mp3").write_bytes(b"")
        items = _fake_items(10)
        config = SimpleNamespace(book_title="Carl", output_dir=str(self.tmp_root))
        args = _fake_args()
        result = self.app._detect_reusable_existing_output(
            _fake_reader("Carl"), items, config, args
        )
        self.assertIsNone(result)


class TestMaybeCleanObsoleteCache(unittest.TestCase):
    def setUp(self) -> None:
        self.app = _make_app()
        # Redirect cache_root so the test never touches real cache.
        self.tmp_cache = Path(tempfile.mkdtemp(prefix="cache-clean-test-"))
        self.app.cache_root = self.tmp_cache

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp_cache, ignore_errors=True)

    def _populate_cache(self, book_title: str, files: list[str]) -> Path:
        from src.utils import FileManager

        d = self.tmp_cache / FileManager.sanitize_filename(book_title)
        d.mkdir(parents=True, exist_ok=True)
        for name in files:
            (d / name).write_bytes(b"x" * 1000)
        return d

    def test_removes_stale_chapter_mp3s(self):
        # Old edition had chapter "99" that the new structure doesn't
        # include — cache cleanup must drop it.
        cache_dir = self._populate_cache(
            "Carl",
            ["1 - intro.mp3", "2 - body.mp3", "99 - extra.mp3"],
        )
        items = _fake_items(2)
        config = SimpleNamespace()
        self.app._maybe_clean_obsolete_cache(_fake_reader("Carl"), items, config)
        remaining = sorted(p.name for p in cache_dir.glob("*.mp3"))
        self.assertEqual(remaining, ["1 - intro.mp3", "2 - body.mp3"])

    def test_keeps_files_matching_current_structure(self):
        cache_dir = self._populate_cache(
            "Carl",
            ["1 - intro.mp3", "2 - body.mp3"],
        )
        items = _fake_items(2)
        config = SimpleNamespace()
        self.app._maybe_clean_obsolete_cache(_fake_reader("Carl"), items, config)
        remaining = sorted(p.name for p in cache_dir.glob("*.mp3"))
        self.assertEqual(remaining, ["1 - intro.mp3", "2 - body.mp3"])

    def test_silent_when_cache_dir_missing(self):
        items = _fake_items(2)
        config = SimpleNamespace()
        # Should not raise even though the dir was never created.
        self.app._maybe_clean_obsolete_cache(_fake_reader("Ghost"), items, config)


class TestConversionResultConstructor(unittest.TestCase):
    """Regression: the reuse short-circuit synthesises a
    ``ConversionResult`` directly. The dataclass requires *all* fields
    (success, total_chapters, converted_chapters, output_files, errors)
    — leaving any of them out raises TypeError at runtime, breaking the
    CLI for any book that already has output on disk."""

    def test_can_construct_with_empty_errors(self):
        from src.converter import ConversionResult

        result = ConversionResult(
            success=True,
            total_chapters=10,
            converted_chapters=10,
            output_files=[],
            errors=[],
        )
        self.assertTrue(result.success)
        self.assertEqual(result.errors, [])


if __name__ == "__main__":
    unittest.main()
