"""Compatibility contracts for curated voices and local model discovery."""

from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase
from unittest.mock import patch

from python_app.src.config import AppConfig, ConversionConfig, VoiceConfigProvider
from python_app.src.voice_config_provider import VoiceConfigProvider as VoiceCatalog


class VoiceConfigBoundaryTests(TestCase):
    def test_public_provider_retains_single_identity(self):
        self.assertIs(VoiceConfigProvider, VoiceCatalog)
        self.assertIsInstance(AppConfig().voice_configs, VoiceCatalog)
        self.assertIsInstance(AppConfig().create_conversion_config("edge"), ConversionConfig)

    def test_suggestions_are_independent_snapshots(self):
        provider = VoiceConfigProvider()
        first = provider.get_voice_suggestions()
        first["edge"][0]["id"] = "changed"
        self.assertEqual(
            provider.get_voice_suggestions()["edge"][0]["id"],
            "pt-BR-ThalitaMultilingualNeural",
        )
        self.assertIsNone(provider.edge_voice_is_multilingual("unknown"))
        self.assertIsNone(provider.get_voice("unknown"))

    def test_installed_model_discovery_ignores_missing_directories(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            model = root / "pt_BR-faber-medium.onnx"
            model.touch()
            with patch.dict("os.environ", {"PIPER_MODEL_DIR": str(root)}):
                discovered = VoiceConfigProvider().get_piper_models(root / "missing")
            self.assertEqual(discovered[model.stem]["path"], model)
            self.assertTrue(discovered[model.stem]["recommended"])

    def test_missing_language_model_preserves_fallback_voice(self):
        provider = VoiceConfigProvider()
        with patch.object(provider, "get_piper_models", return_value={}):
            self.assertFalse(provider.has_piper_model("pt-BR"))
            self.assertIsNone(provider.get_voice("piper", "pt-BR"))
            self.assertEqual(
                provider.build_language_voice_map("piper", ["pt-BR"], "selected"),
                {"pt": "selected"},
            )
