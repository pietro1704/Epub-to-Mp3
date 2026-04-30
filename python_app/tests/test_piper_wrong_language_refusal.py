"""Piper must refuse to synthesise with a wrong-language model.

The Carl regression (v0.3.20): a pt-BR EPUB was synthesised with the
fallback `en_US-lessac-medium.onnx` because the on-demand download of
`pt_BR-faber-medium.onnx` had failed earlier and `_find_piper_model`
silently returned the first installed model from any language. The
audio was unintelligible — Portuguese text spoken with English
phonemes.

The fix: when the caller asks for a specific language and no model is
available for that language locally and the download fails, the factory
must raise instead of returning a wrong-language model. The retry
machinery upstream (CLI: `--fallback-engine`, server:
`_build_engine_chain`) catches the FileNotFoundError and falls through
to Edge/Kokoro, where the language is honoured.
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import inspect

from src.tts.factory import TTSFactory


class TestPiperRefusesWrongLanguageModel(unittest.TestCase):
    """Pin the v0.3.21 fix at the source-code level.

    A behavioural test would have to neutralise every candidate dir
    that `_find_piper_model` looks at (env var, project_root/models,
    project_root/models/piper, cwd/models, python_app/models, mocked
    Path return values) — not robust. Instead, assert that the
    "Last resort: return any model found, even if wrong language"
    block is gone and the new refusal raise is in place. This pins the
    fix without coupling to the directory plumbing.
    """

    def setUp(self) -> None:
        self.factory = TTSFactory()

    def test_no_silent_wrong_language_fallback(self):
        source = inspect.getsource(TTSFactory._find_piper_model)
        # The historical bad fallback comment must be gone.
        self.assertNotIn(
            "Last resort: return any model found, even if wrong language",
            source,
            "Piper factory must not fall back to a wrong-language model",
        )
        # The refusal raise must be present.
        self.assertIn("Refusing to synthesise with a wrong-language model", source)
        # And it must be guarded by `if preferred:` so the no-language
        # case still tolerates the legacy first-found behaviour.
        self.assertIn("if preferred:", source)

    def test_returns_correct_language_model_when_present(self):
        """Sanity: when the right-language model exists locally, return it."""
        fake_dir = Path("/tmp/fake-piper-models-pt-ok")
        fake_dir.mkdir(parents=True, exist_ok=True)
        pt_model = fake_dir / "pt_BR-faber-medium.onnx"
        pt_model.write_bytes(b"fake")
        en_model = fake_dir / "en_US-lessac-medium.onnx"
        en_model.write_bytes(b"fake")

        try:
            result = self.factory._find_piper_model(preferred_code="pt-BR", models_dir=fake_dir)
            self.assertEqual(result.name, "pt_BR-faber-medium.onnx")
        finally:
            pt_model.unlink(missing_ok=True)
            en_model.unlink(missing_ok=True)
            fake_dir.rmdir()

    def test_no_preference_falls_back_to_any_model(self):
        """When the caller doesn't specify a language, the historical
        behaviour (return any installed model) is fine — there's no
        conflict to enforce. Sandbox project_root and cwd so the
        production `models/` dir on dev machines (which has multiple
        languages) doesn't influence the test result.
        """
        fake_dir = Path("/tmp/fake-piper-models-no-pref")
        fake_dir.mkdir(parents=True, exist_ok=True)
        en_model = fake_dir / "en_US-lessac-medium.onnx"
        en_model.write_bytes(b"fake")
        sandbox_root = fake_dir.parent / "sandbox-no-pref"
        sandbox_root.mkdir(exist_ok=True)
        try:
            with (
                patch.object(self.factory, "_download_default_piper_model", return_value=None),
                patch.object(self.factory, "_resolve_project_root", return_value=sandbox_root),
                patch.dict(os.environ, {"PIPER_MODEL_DIR": ""}, clear=False),
                patch("pathlib.Path.cwd", return_value=sandbox_root),
            ):
                result = self.factory._find_piper_model(preferred_code=None, models_dir=fake_dir)
            self.assertEqual(result.name, "en_US-lessac-medium.onnx")
        finally:
            en_model.unlink(missing_ok=True)
            fake_dir.rmdir()
            sandbox_root.rmdir()


if __name__ == "__main__":
    unittest.main()
