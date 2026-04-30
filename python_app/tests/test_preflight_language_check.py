"""Pre-flight check before TTS starts.

Runs a second-pass language detection over a different chapter window
than the one `_prepare_language_profile` used for the first pass. If
the two passes disagree and the user did not force --language, abort
the conversion before generating any audio (the v0.3.21 Carl fix).

The test focuses on the agreement / disagreement / override logic of
`_preflight_language_and_config_check` rather than the surrounding CLI
plumbing — that path is exercised by integration tests.
"""

from __future__ import annotations

import io
import os
import sys
import unittest
from contextlib import redirect_stdout
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.language.detector import LanguageProfile


def _make_app():
    """Build an EbookConverterApp without touching disk."""
    with patch("main.AudioConverter") as _audio, patch("main.MenuInterface") as _menu:
        _audio.return_value = MagicMock()
        _menu.return_value = MagicMock()
        from main import ConverterApplication

        return ConverterApplication()


def _fake_item(text: str):
    chapter = SimpleNamespace(text=text, raw_html=None)
    return SimpleNamespace(chapter=chapter, text_override=None)


def _fake_config(primary_language: str = "pt-BR", voice: str = ""):
    cfg = SimpleNamespace()
    cfg.primary_language = primary_language
    cfg.voice = voice
    return cfg


def _fake_args(engine: str = "edge", fallback_engine: str = "auto", language: str = ""):
    return SimpleNamespace(engine=engine, fallback_engine=fallback_engine, language=language)


class TestPreflightLanguageMatch(unittest.TestCase):
    def test_proceeds_when_two_passes_agree(self):
        app = _make_app()
        items = [_fake_item("Era uma vez no reino de Portugal." * 30) for _ in range(20)]
        cfg = _fake_config(primary_language="pt-BR")
        args = _fake_args(engine="edge")

        # Stub the detector so the second pass yields pt — agreement.
        app.language_detector = MagicMock()
        app.language_detector.detect_profile.return_value = LanguageProfile(
            primary="pt", languages=["pt"], predictions=[], analysed_chars=5000
        )

        buf = io.StringIO()
        with redirect_stdout(buf):
            ok = app._preflight_language_and_config_check(MagicMock(), items, cfg, args)

        self.assertTrue(ok)
        self.assertIn("Match", buf.getvalue())

    def test_aborts_on_language_mismatch_without_user_override(self):
        app = _make_app()
        items = [_fake_item("This is English text repeated " * 30) for _ in range(20)]
        cfg = _fake_config(primary_language="pt-BR")
        args = _fake_args(engine="edge")

        app.language_detector = MagicMock()
        app.language_detector.detect_profile.return_value = LanguageProfile(
            primary="en", languages=["en"], predictions=[], analysed_chars=5000
        )

        buf = io.StringIO()
        with redirect_stdout(buf):
            ok = app._preflight_language_and_config_check(MagicMock(), items, cfg, args)

        self.assertFalse(ok)
        out = buf.getvalue()
        self.assertIn("Discrepância", out)
        self.assertIn("MISMATCH", out)

    def test_user_language_override_wins_with_warning(self):
        """--language explicit → respect user choice, only warn."""
        app = _make_app()
        items = [_fake_item("English text body. " * 100) for _ in range(20)]
        cfg = _fake_config(primary_language="pt-BR")
        # Simulate the user forcing pt-BR via --language pt-BR.
        args = _fake_args(engine="edge", language="pt-BR")

        app.language_detector = MagicMock()
        app.language_detector.detect_profile.return_value = LanguageProfile(
            primary="en", languages=["en"], predictions=[], analysed_chars=5000
        )

        buf = io.StringIO()
        with redirect_stdout(buf):
            ok = app._preflight_language_and_config_check(MagicMock(), items, cfg, args)

        self.assertTrue(ok)
        self.assertIn("Override do usuário", buf.getvalue())

    def test_inconclusive_second_pass_proceeds(self):
        """When the mid-book sample isn't long enough, skip the comparison
        rather than blocking conversions of legitimately short books."""
        app = _make_app()
        items = [_fake_item("hi") for _ in range(20)]  # too short → no sample
        cfg = _fake_config(primary_language="pt-BR")
        args = _fake_args(engine="edge")

        app.language_detector = MagicMock()
        app.language_detector.detect_profile.side_effect = AssertionError(
            "must not be called when sample is empty"
        )

        buf = io.StringIO()
        with redirect_stdout(buf):
            ok = app._preflight_language_and_config_check(MagicMock(), items, cfg, args)

        self.assertTrue(ok)
        self.assertIn("inconclusivo", buf.getvalue())

    def test_prints_engine_and_fallback_choices(self):
        """The user's CLI choices must appear in the pre-flight output so
        a wrong --engine / --fallback-engine combo is visible *before*
        synthesis."""
        app = _make_app()
        items = [_fake_item("Era uma vez. " * 100) for _ in range(20)]
        cfg = _fake_config(primary_language="pt-BR", voice="pt-BR-AntonioNeural")
        args = _fake_args(engine="edge", fallback_engine="none")

        app.language_detector = MagicMock()
        app.language_detector.detect_profile.return_value = LanguageProfile(
            primary="pt", languages=["pt"], predictions=[], analysed_chars=5000
        )

        buf = io.StringIO()
        with redirect_stdout(buf):
            app._preflight_language_and_config_check(MagicMock(), items, cfg, args)

        out = buf.getvalue()
        self.assertIn("Engine pedido pelo usuário: edge", out)
        self.assertIn("Fallback engine: none", out)
        self.assertIn("pt-BR-AntonioNeural", out)


if __name__ == "__main__":
    unittest.main()
