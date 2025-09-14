# -*- coding: utf-8 -*-
"""
Unit tests for simplified configuration module
"""

import unittest
import tempfile
import os
from pathlib import Path

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.config import ConversionConfig, AppConfig, VoiceConfigProvider


class TestConversionConfig(unittest.TestCase):
    """Test cases for ConversionConfig dataclass"""

    def test_config_creation_minimal(self):
        """Test config creation with minimal parameters"""
        config = ConversionConfig(engine="edge")
        
        self.assertEqual(config.engine, "edge")
        self.assertIsNone(config.voice)
        self.assertIsNone(config.model_path)
        self.assertEqual(config.output_dir, "output")
        self.assertEqual(config.book_title, "")
        self.assertTrue(config.preserve_all_chapters)

    def test_config_creation_full(self):
        """Test config creation with all parameters"""
        model_path = Path("test/model.onnx")
        
        config = ConversionConfig(
            engine="piper",
            voice="test-voice",
            model_path=model_path,
            output_dir="custom_output",
            book_title="Test Book",
            preserve_all_chapters=False,
            bitrate="64k",
            sample_rate=44100,
            channels=2,
            parallel=5,
            force_reprocess=True
        )
        
        self.assertEqual(config.engine, "piper")
        self.assertEqual(config.voice, "test-voice")
        self.assertEqual(config.model_path, model_path)
        self.assertEqual(config.output_dir, "custom_output")
        self.assertEqual(config.book_title, "Test Book")
        self.assertFalse(config.preserve_all_chapters)
        self.assertEqual(config.bitrate, "64k")
        self.assertEqual(config.sample_rate, 44100)
        self.assertEqual(config.channels, 2)
        self.assertEqual(config.parallel, 5)
        self.assertTrue(config.force_reprocess)

    def test_config_defaults(self):
        """Test default values"""
        config = ConversionConfig(engine="test")
        
        # Audio defaults
        self.assertEqual(config.bitrate, "32k")
        self.assertEqual(config.sample_rate, 22050)
        self.assertEqual(config.channels, 1)
        
        # Processing defaults
        self.assertEqual(config.parallel, 1)
        self.assertFalse(config.force_reprocess)


class TestAppConfig(unittest.TestCase):
    """Test cases for AppConfig class"""

    def setUp(self):
        """Set up test fixtures"""
        self.config = AppConfig()

    def test_init(self):
        """Test AppConfig initialization"""
        self.assertIsInstance(self.config.voice_configs, VoiceConfigProvider)

    def test_create_conversion_config_minimal(self):
        """Test creating conversion config with minimal parameters"""
        config = self.config.create_conversion_config("edge")

        self.assertIsInstance(config, ConversionConfig)
        self.assertEqual(config.engine, "edge")
        self.assertEqual(config.voice, "pt-BR-AntonioNeural")
        self.assertIsNone(config.model_path)
        expected_parallel = max(os.cpu_count() or 1, 1)
        self.assertEqual(config.parallel, expected_parallel)

    def test_create_conversion_config_with_voice(self):
        """Test creating conversion config with voice"""
        config = self.config.create_conversion_config(
            engine="edge",
            voice="pt-BR-FranciscaNeural"
        )
        
        self.assertEqual(config.engine, "edge")
        self.assertEqual(config.voice, "pt-BR-FranciscaNeural")

    def test_create_conversion_config_with_model(self):
        """Test creating conversion config with model"""
        config = self.config.create_conversion_config(
            engine="piper",
            model="test_model.onnx"
        )
        
        self.assertEqual(config.engine, "piper")
        self.assertEqual(config.model_path, Path("test_model.onnx"))

    def test_create_conversion_config_with_kwargs(self):
        """Test creating conversion config with additional kwargs"""
        config = self.config.create_conversion_config(
            engine="coqui",
            book_title="Test Book",
            output_dir="custom",
            preserve_all_chapters=False
        )
        
        self.assertEqual(config.engine, "coqui")
        self.assertEqual(config.book_title, "Test Book")
        self.assertEqual(config.output_dir, "custom")
        self.assertFalse(config.preserve_all_chapters)


class TestVoiceConfigProvider(unittest.TestCase):
    """Test cases for VoiceConfigProvider class"""

    def setUp(self):
        """Set up test fixtures"""
        self.provider = VoiceConfigProvider()

    def test_edge_voices(self):
        """Test Edge-TTS voices"""
        voices = self.provider.edge_voices
        
        self.assertIsInstance(voices, dict)
        self.assertGreater(len(voices), 0)
        
        # Check structure
        for key, value in voices.items():
            self.assertIsInstance(key, str)
            self.assertIsInstance(value, tuple)
            self.assertEqual(len(value), 2)
            voice_id, description = value
            self.assertIsInstance(voice_id, str)
            self.assertIsInstance(description, str)
            
        # Check for expected voices
        self.assertIn("1", voices)
        francisca_voice, francisca_desc = voices["1"]
        self.assertEqual(francisca_voice, "pt-BR-FranciscaNeural")
        self.assertIn("Francisca", francisca_desc)

    def test_coqui_models(self):
        """Test Coqui TTS models"""
        models = self.provider.coqui_models
        
        self.assertIsInstance(models, dict)
        self.assertGreater(len(models), 0)
        
        # Check structure
        for key, value in models.items():
            self.assertIsInstance(key, str)
            self.assertIsInstance(value, tuple)
            self.assertEqual(len(value), 4)
            model_id, name, desc, multilingual = value
            self.assertIsInstance(model_id, str)
            self.assertIsInstance(name, str)
            self.assertIsInstance(desc, str)
            self.assertIsInstance(multilingual, bool)
        
        # Check for expected model
        self.assertIn("1", models)
        xtts_model, xtts_name, xtts_desc, xtts_multi = models["1"]
        self.assertIn("xtts_v2", xtts_model)

    def test_get_piper_models_no_directory(self):
        """Test getting Piper models when models directory doesn't exist"""
        with tempfile.TemporaryDirectory() as temp_dir:
            original_cwd = os.getcwd()
            try:
                os.chdir(temp_dir)
                models = self.provider.get_piper_models()
                self.assertEqual(models, {})
            finally:
                os.chdir(original_cwd)

    def test_get_piper_models_with_files(self):
        """Test getting Piper models with actual model files"""
        with tempfile.TemporaryDirectory() as temp_dir:
            models_dir = Path(temp_dir) / "models"
            models_dir.mkdir()
            
            # Create mock model files
            model1 = models_dir / "faber-medium.onnx"
            model2 = models_dir / "other-model.onnx"
            
            model1.write_text("dummy model 1")
            model2.write_text("dummy model 2")
            
            original_cwd = os.getcwd()
            try:
                os.chdir(temp_dir)
                models = self.provider.get_piper_models()
                
                self.assertEqual(len(models), 2)
                
                # Check faber model
                self.assertIn("faber-medium", models)
                faber_info = models["faber-medium"]
                self.assertEqual(faber_info["name"], "faber-medium")
                self.assertTrue(faber_info["recommended"])
                
                # Check other model  
                self.assertIn("other-model", models)
                other_info = models["other-model"]
                self.assertEqual(other_info["name"], "other-model")
                self.assertFalse(other_info["recommended"])
                
            finally:
                os.chdir(original_cwd)

    def test_get_piper_models_empty_directory(self):
        """Test getting Piper models with empty models directory"""
        with tempfile.TemporaryDirectory() as temp_dir:
            models_dir = Path(temp_dir) / "models"
            models_dir.mkdir()
            
            original_cwd = os.getcwd()
            try:
                os.chdir(temp_dir)
                models = self.provider.get_piper_models()
                self.assertEqual(models, {})
            finally:
                os.chdir(original_cwd)


class TestConstants(unittest.TestCase):
    """Test cases for module constants"""

    def test_default_config(self):
        """Test default config constant"""
        from src.config import DEFAULT_CONFIG
        
        self.assertIsInstance(DEFAULT_CONFIG, ConversionConfig)
        self.assertEqual(DEFAULT_CONFIG.engine, "edge")

    def test_supported_formats(self):
        """Test supported formats constant"""
        from src.config import SUPPORTED_FORMATS
        
        self.assertIsInstance(SUPPORTED_FORMATS, list)
        self.assertIn(".epub", SUPPORTED_FORMATS)
        self.assertIn(".pdf", SUPPORTED_FORMATS)

    def test_audio_formats(self):
        """Test audio formats constant"""
        from src.config import AUDIO_FORMATS
        
        self.assertIsInstance(AUDIO_FORMATS, list)
        self.assertIn("mp3", AUDIO_FORMATS)


if __name__ == '__main__':
    unittest.main()
