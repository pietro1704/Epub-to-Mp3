# -*- coding: utf-8 -*-
"""
Unit tests for simplified TTS modules
"""

import unittest
import tempfile
import asyncio
import os
from pathlib import Path
from unittest.mock import Mock, AsyncMock, patch, MagicMock

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.config import ConversionConfig


class TestTTSFactory(unittest.TestCase):
    """Test cases for TTSFactory"""

    def setUp(self):
        """Set up test fixtures"""
        from src.tts.factory import TTSFactory

        self.factory = TTSFactory()

    def test_create_edge_engine(self):
        """Test creating Edge TTS engine"""
        config = ConversionConfig(engine="edge", voice="pt-BR-FranciscaNeural")
        
        with patch('src.tts.edge_engine.EdgeTTSEngine') as mock_engine:
            engine = self.factory.create_engine(config)
            
            mock_engine.assert_called_once_with(
                "pt-BR-FranciscaNeural",
                primary_language="auto",
                language_voices={},
            )

    def test_create_coqui_engine(self):
        """Test creating Coqui TTS engine"""
        config = ConversionConfig(engine="coqui", voice="test_model")
        
        with patch('src.tts.coqui_engine.CoquiTTSEngine') as mock_engine:
            engine = self.factory.create_engine(config)
            
            mock_engine.assert_called_once_with(
                "test_model",
                primary_language="auto",
                language_voices={},
            )

    def test_create_piper_engine(self):
        """Test creating Piper TTS engine"""
        model_path = Path("test_model.onnx")
        config = ConversionConfig(engine="piper", model_path=model_path)
        
        with patch('src.tts.piper_engine.PiperTTSEngine') as mock_engine:
            engine = self.factory.create_engine(config)
            
            mock_engine.assert_called_once_with(
                model_path,
                primary_language="auto",
                language_voices={},
            )

    def test_create_piper_engine_auto_find(self):
        """Test creating Piper TTS engine with auto model detection"""
        config = ConversionConfig(engine="piper")
        
        with patch('src.tts.piper_engine.PiperTTSEngine') as mock_engine, \
             patch.object(self.factory, '_find_piper_model') as mock_find:
            
            mock_find.return_value = Path("found_model.onnx")
            engine = self.factory.create_engine(config)
            
            mock_find.assert_called_once()
            mock_engine.assert_called_once_with(
                Path("found_model.onnx"),
                primary_language="auto",
                language_voices={},
            )

    def test_create_unsupported_engine(self):
        """Test creating unsupported engine"""
        config = ConversionConfig(engine="unsupported")
        
        with self.assertRaises(ValueError) as context:
            self.factory.create_engine(config)
        
        self.assertIn("Unsupported engine", str(context.exception))

    def test_find_piper_model_success(self):
        """Test finding Piper model successfully"""
        with tempfile.TemporaryDirectory() as temp_dir:
            models_dir = Path(temp_dir) / "models"
            models_dir.mkdir()

            model_file = models_dir / "test_model.onnx"
            model_file.write_text("dummy model")

            with patch('src.tts.factory.Path') as mock_path:
                mock_path.return_value = models_dir
                mock_path.side_effect = lambda x: Path(x) if x == "models" else Path(x)

                result = self.factory._find_piper_model()

                self.assertEqual(result.name, "test_model.onnx")

    def test_find_piper_model_not_found(self):
        """Test finding Piper model when none exists"""
        with tempfile.TemporaryDirectory() as temp_dir:
            models_dir = Path(temp_dir) / "nonexistent"
            
        with patch('src.tts.factory.Path') as mock_path:
                mock_path.return_value = models_dir
                
                with self.assertRaises(FileNotFoundError):
                    self.factory._find_piper_model()


class TestEdgeTTSEngine(unittest.TestCase):
    """Test cases for EdgeTTSEngine"""

    def setUp(self):
        """Set up test fixtures"""
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src', 'tts'))
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_init_success(self):
        """Test successful EdgeTTSEngine initialization"""
        with patch('src.tts.edge_engine.edge_tts') as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine
            engine = EdgeTTSEngine("pt-BR-FranciscaNeural")
            
            self.assertEqual(engine.voice, "pt-BR-FranciscaNeural")
            self.assertEqual(engine._edge_tts, mock_edge_tts)

    def test_init_missing_dependency(self):
        """Test EdgeTTSEngine initialization with missing dependency"""
        with patch('src.tts.edge_engine.edge_tts', side_effect=ImportError("No module")):
            from src.tts.edge_engine import EdgeTTSEngine
            
            with self.assertRaises(ImportError) as context:
                EdgeTTSEngine("test-voice")
            
            self.assertIn("Edge-TTS not installed", str(context.exception))

    async def test_synthesize_async_success(self):
        """Test successful text synthesis"""
        with patch('src.tts.edge_engine.edge_tts') as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine

            class DummyCommunicate:
                def __init__(self, chunks):
                    self._chunks = chunks

                async def stream(self):
                    for chunk in self._chunks:
                        yield chunk

            mock_edge_tts.Communicate.side_effect = lambda text, voice: DummyCommunicate(
                [
                    {"type": "audio", "data": b"DATA"},
                    {"type": "WordBoundary", "data": {}},
                ]
            )

            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"

            result = await engine.synthesize_async("Hello world", output_path)

            self.assertEqual(result, output_path)
            self.assertEqual(output_path.read_bytes(), b"DATA")
            mock_edge_tts.Communicate.assert_called_once_with("Hello world", "test-voice")

    async def test_synthesize_async_multilingual(self):
        """Ensure multilingual markup selects appropriate voices."""
        with patch('src.tts.edge_engine.edge_tts') as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine

            class DummyCommunicate:
                def __init__(self, chunks):
                    self._chunks = chunks

                async def stream(self):
                    for chunk in self._chunks:
                        yield chunk

            calls = []

            def make_comm(text, voice):
                calls.append((text, voice))
                return DummyCommunicate([
                    {"type": "audio", "data": b"X"},
                ])

            mock_edge_tts.Communicate.side_effect = make_comm

            engine = EdgeTTSEngine(
                "pt-BR-ThalitaMultilingualNeural",
                primary_language="pt",
                language_voices={
                    "pt": "pt-BR-ThalitaMultilingualNeural",
                    "en": "en-US-JennyNeural",
                },
            )

            output_path = Path(self.temp_dir) / "output.wav"
            text = "Olá [[lang:en]]Hello[[/lang]] mundo"

            result = await engine.synthesize_async(text, output_path)

            self.assertEqual(result, output_path)
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[0][1], "pt-BR-ThalitaMultilingualNeural")
            self.assertEqual(calls[1][1], "en-US-JennyNeural")

    async def test_synthesize_async_empty_text(self):
        """Test synthesis with empty text"""
        with patch('src.tts.edge_engine.edge_tts') as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine
            
            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"
            
            result = await engine.synthesize_async("", output_path)
            
            self.assertIsNone(result)
            mock_edge_tts.Communicate.assert_not_called()

    async def test_synthesize_async_timeout(self):
        """Test synthesis with timeout"""
        with patch('src.tts.edge_engine.edge_tts') as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine

            class TimeoutCommunicate:
                async def stream(self):
                    raise asyncio.TimeoutError()

            mock_edge_tts.Communicate.return_value = TimeoutCommunicate()

            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"

            result = await engine.synthesize_async("Hello world", output_path)

            self.assertIsNone(result)
            self.assertEqual(engine.last_error, "timeout")

    async def test_synthesize_async_exception(self):
        """Test synthesis with exception"""
        with patch('src.tts.edge_engine.edge_tts') as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine

            class ErrorCommunicate:
                async def stream(self):
                    raise RuntimeError("Test error")

            mock_edge_tts.Communicate.return_value = ErrorCommunicate()

            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"

            result = await engine.synthesize_async("Hello world", output_path)

            self.assertIsNone(result)
            self.assertIn("RuntimeError", engine.last_error)

    def test_calculate_timeout(self):
        """Test timeout calculation"""
        with patch('src.tts.edge_engine.edge_tts'):
            from src.tts.edge_engine import EdgeTTSEngine
            
            engine = EdgeTTSEngine("test-voice")
            
            # Short text
            timeout = engine._calculate_timeout("Hi")
            self.assertEqual(timeout, 30)
            
            # Medium text
            medium_text = "A" * 2000
            timeout = engine._calculate_timeout(medium_text)
            self.assertEqual(timeout, 60)
            
            # Long text
            long_text = "A" * 10000
            timeout = engine._calculate_timeout(long_text)
            self.assertGreaterEqual(timeout, 90)


class TestCoquiTTSEngine(unittest.TestCase):
    """Test cases for CoquiTTSEngine"""

    def setUp(self):
        """Set up test fixtures"""
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src', 'tts'))
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_init_success(self):
        """Test successful CoquiTTSEngine initialization"""
        with patch('src.tts.coqui_engine.TTS') as mock_tts:
            from src.tts.coqui_engine import CoquiTTSEngine
            
            engine = CoquiTTSEngine("test_model")
            
            self.assertEqual(engine.model_name, "test_model")
            self.assertIsNone(engine.tts)  # Lazy initialization
            self.assertEqual(engine._tts_class, mock_tts)

    def test_init_missing_dependency(self):
        """Test CoquiTTSEngine initialization with missing dependency"""
        with patch('src.tts.coqui_engine.TTS', side_effect=ImportError("No module")):
            from src.tts.coqui_engine import CoquiTTSEngine
            
            with self.assertRaises(ImportError) as context:
                CoquiTTSEngine("test_model")
            
            self.assertIn("Coqui TTS not installed", str(context.exception))

    def test_initialize_model(self):
        """Test lazy model initialization"""
        with patch('src.tts.coqui_engine.TTS') as mock_tts_class:
            from src.tts.coqui_engine import CoquiTTSEngine
            
            mock_tts_instance = Mock()
            mock_tts_class.return_value = mock_tts_instance
            
            engine = CoquiTTSEngine("test_model")
            engine._initialize_model()
            
            self.assertEqual(engine.tts, mock_tts_instance)
            mock_tts_class.assert_called_once_with(model_name="test_model")

    async def test_synthesize_async_success(self):
        """Test successful text synthesis"""
        with patch('src.tts.coqui_engine.TTS') as mock_tts_class:
            from src.tts.coqui_engine import CoquiTTSEngine
            
            mock_tts_instance = Mock()
            mock_tts_instance.tts_to_file = Mock()
            mock_tts_class.return_value = mock_tts_instance
            
            engine = CoquiTTSEngine("test_model")
            output_path = Path(self.temp_dir) / "output.wav"
            
            # Create output file (simulating successful synthesis)
            output_path.write_text("A" * 2000)
            
            with patch('asyncio.get_event_loop') as mock_loop:
                mock_executor = AsyncMock()
                mock_loop.return_value.run_in_executor = mock_executor
                
                result = await engine.synthesize_async("Hello world", output_path)
                
                self.assertEqual(result, output_path)
                mock_executor.assert_called_once()

    async def test_synthesize_async_empty_text(self):
        """Test synthesis with empty text"""
        with patch('src.tts.coqui_engine.TTS'):
            from src.tts.coqui_engine import CoquiTTSEngine
            
            engine = CoquiTTSEngine("test_model")
            output_path = Path(self.temp_dir) / "output.wav"
            
            result = await engine.synthesize_async("", output_path)
            
            self.assertIsNone(result)

    async def test_synthesize_async_exception(self):
        """Test synthesis with exception"""
        with patch('src.tts.coqui_engine.TTS') as mock_tts_class:
            from src.tts.coqui_engine import CoquiTTSEngine
            
            mock_tts_instance = Mock()
            mock_tts_instance.tts_to_file.side_effect = Exception("Test error")
            mock_tts_class.return_value = mock_tts_instance
            
            engine = CoquiTTSEngine("test_model")
            output_path = Path(self.temp_dir) / "output.wav"
            
            with patch('asyncio.get_event_loop') as mock_loop:
                mock_executor = AsyncMock()
                mock_executor.side_effect = Exception("Test error")
                mock_loop.return_value.run_in_executor = mock_executor
                
                result = await engine.synthesize_async("Hello world", output_path)
                
                self.assertIsNone(result)


class TestPiperTTSEngine(unittest.TestCase):
    """Test cases for PiperTTSEngine"""

    def setUp(self):
        """Set up test fixtures"""
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src', 'tts'))
        self.temp_dir = tempfile.mkdtemp()
        
        # Create a mock model file
        self.model_path = Path(self.temp_dir) / "model.onnx"
        self.model_path.write_text("dummy model")

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_init_success(self):
        """Test successful PiperTTSEngine initialization"""
        from src.tts.piper_engine import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        
        self.assertEqual(engine.model_path, self.model_path)

    def test_init_missing_model(self):
        """Test PiperTTSEngine initialization with missing model"""
        from src.tts.piper_engine import PiperTTSEngine
        
        nonexistent_model = Path(self.temp_dir) / "nonexistent.onnx"
        
        with self.assertRaises(FileNotFoundError):
            PiperTTSEngine(nonexistent_model)

    async def test_synthesize_async_success(self):
        """Test successful text synthesis"""
        from src.tts.piper_engine import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "output.wav"
        
        with patch('src.tts.piper_engine.asyncio.create_subprocess_exec') as mock_subprocess:
            # Mock successful piper process
            mock_process = AsyncMock()
            mock_process.communicate.return_value = (b"success", b"")
            mock_process.returncode = 0
            mock_subprocess.return_value = mock_process
            
            # Create output file (simulating successful synthesis)
            output_path.write_text("A" * 2000)
            
            result = await engine.synthesize_async("Hello world", output_path)
            
            self.assertEqual(result, output_path)
            mock_subprocess.assert_called_once()
            mock_process.communicate.assert_called_once_with(input=b"Hello world")

    async def test_synthesize_async_empty_text(self):
        """Test synthesis with empty text"""
        from src.tts.piper_engine import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "output.wav"
        
        result = await engine.synthesize_async("", output_path)
        
        self.assertIsNone(result)

    async def test_synthesize_async_piper_failure(self):
        """Test synthesis with Piper failure"""
        from src.tts.piper_engine import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "output.wav"
        
        with patch('src.tts.piper_engine.asyncio.create_subprocess_exec') as mock_subprocess:
            # Mock failed piper process
            mock_process = AsyncMock()
            mock_process.communicate.return_value = (b"", b"Error occurred")
            mock_process.returncode = 1  # Failure
            mock_subprocess.return_value = mock_process
            
            result = await engine.synthesize_async("Hello world", output_path)
            
            self.assertIsNone(result)

    async def test_synthesize_async_piper_not_found(self):
        """Test synthesis when Piper is not installed"""
        from src.tts.piper_engine import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "output.wav"
        
        with patch('src.tts.piper_engine.asyncio.create_subprocess_exec') as mock_subprocess:
            mock_subprocess.side_effect = FileNotFoundError("Piper not found")
            
            result = await engine.synthesize_async("Hello world", output_path)
            
            self.assertIsNone(result)

    async def test_synthesize_async_exception(self):
        """Test synthesis with exception"""
        from src.tts.piper_engine import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "output.wav"
        
        with patch('src.tts.piper_engine.asyncio.create_subprocess_exec') as mock_subprocess:
            mock_subprocess.side_effect = Exception("Test error")
            
            result = await engine.synthesize_async("Hello world", output_path)
            
            self.assertIsNone(result)


if __name__ == '__main__':
    unittest.main()
