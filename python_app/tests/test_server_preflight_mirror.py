"""Server-side mirror of the CLI pre-flight + reuse guards (v0.3.22).

The Carl regressions all hit the CLI path. The dual-path policy in
CLAUDE.md says any feature added to ``converter.py`` / ``main.py``
must be mirrored on ``server.py`` — otherwise web-form jobs get a
worse safety net than CLI runs.

These tests pin the helper functions in `_server_conversion_helpers.py`
that the server uses for pre-flight language checks and existing-output
reuse. The wiring inside ``process_conversion`` is exercised by the
existing job integration tests.
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

from src._server_conversion_helpers import (
    detect_reusable_existing_output,
    preflight_language_check,
)


def _chapter(text: str):
    return SimpleNamespace(text=text, speech_text=None)


class TestPreflightLanguageCheckServer(unittest.TestCase):
    def _config(self, primary: str = "pt-BR"):
        return SimpleNamespace(primary_language=primary, extra={})

    def test_returns_none_when_two_passes_agree(self):
        chapters = [_chapter("Era uma vez no reino de Portugal." * 30) for _ in range(20)]
        from src.language.detector import LanguageProfile

        with (
            patch("src._server_conversion_helpers.get_language_detector")
            if False
            else patch("src.language.detector.get_language_detector") as mock_get
        ):
            detector = MagicMock()
            detector.detect_profile.return_value = LanguageProfile(
                primary="pt", languages=["pt"], predictions=[], analysed_chars=5000
            )
            mock_get.return_value = detector
            err = preflight_language_check(chapters, self._config(), user_language_override=False)
        self.assertIsNone(err)

    def test_aborts_on_mismatch_without_user_override(self):
        chapters = [_chapter("This is English text repeated " * 30) for _ in range(20)]
        from src.language.detector import LanguageProfile

        with patch("src.language.detector.get_language_detector") as mock_get:
            detector = MagicMock()
            detector.detect_profile.return_value = LanguageProfile(
                primary="en", languages=["en"], predictions=[], analysed_chars=5000
            )
            mock_get.return_value = detector
            err = preflight_language_check(chapters, self._config(), user_language_override=False)
        self.assertIsNotNone(err)
        self.assertIn("mismatch", err.lower())

    def test_user_override_short_circuits_mismatch(self):
        chapters = [_chapter("English text. " * 100) for _ in range(20)]
        from src.language.detector import LanguageProfile

        with patch("src.language.detector.get_language_detector") as mock_get:
            detector = MagicMock()
            detector.detect_profile.return_value = LanguageProfile(
                primary="en", languages=["en"], predictions=[], analysed_chars=5000
            )
            mock_get.return_value = detector
            err = preflight_language_check(chapters, self._config(), user_language_override=True)
        self.assertIsNone(err)

    def test_inconclusive_short_book_proceeds(self):
        chapters = [_chapter("oi") for _ in range(20)]
        with patch("src.language.detector.get_language_detector") as mock_get:
            mock_get.side_effect = AssertionError("must not be called")
            err = preflight_language_check(chapters, self._config(), user_language_override=False)
        self.assertIsNone(err)


class TestDetectReusableExistingOutputServer(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="server-reuse-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _populate(self, count: int):
        for i in range(1, count + 1):
            (self.tmp / f"{i} - chapter.mp3").write_bytes(b"AUDIO" * 100)

    def test_reuses_when_full_book_present(self):
        self._populate(10)
        result = detect_reusable_existing_output(self.tmp, 10)
        self.assertEqual(result, self.tmp)

    def test_returns_none_below_threshold(self):
        self._populate(5)
        result = detect_reusable_existing_output(self.tmp, 10)
        self.assertIsNone(result)

    def test_force_skips_reuse(self):
        self._populate(10)
        result = detect_reusable_existing_output(self.tmp, 10, force=True)
        self.assertIsNone(result)

    def test_zero_byte_files_are_ignored(self):
        for i in range(1, 11):
            (self.tmp / f"{i} - chapter.mp3").write_bytes(b"")
        result = detect_reusable_existing_output(self.tmp, 10)
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
