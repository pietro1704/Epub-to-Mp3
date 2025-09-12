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
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src', 'tts'))

from config_simple import ConversionConfig


class TestTTSFactory(unittest.TestCase):
    """Test cases for TTSFactory"""

    def setUp(self):
        """Set up test fixtures"""
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src', 'tts'))
        from factory_simple import TTSFactory
        self.factory = TTSFactory()

    def test_create_edge_engine(self):
        """Test creating Edge TTS engine"""
        config = ConversionConfig(engine="edge", voice="pt-BR-FranciscaNeural")
        
        with patch('edge_simple.EdgeTTSEngine') as mock_engine:
            engine = self.factory.create_engine(config)
            
            mock_engine.assert_called_once_with("pt-BR-FranciscaNeural")

    def test_create_coqui_engine(self):
        """Test creating Coqui TTS engine"""
        config = ConversionConfig(engine="coqui", voice="test_model")
        
        with patch('coqui_simple.CoquiTTSEngine') as mock_engine:
            engine = self.factory.create_engine(config)
            
            mock_engine.assert_called_once_with("test_model")

    def test_create_piper_engine(self):
        """Test creating Piper TTS engine"""
        model_path = Path("test_model.onnx")
        config = ConversionConfig(engine="piper", model_path=model_path)
        
        with patch('piper_simple.PiperTTSEngine') as mock_engine:
            engine = self.factory.create_engine(config)
            
            mock_engine.assert_called_once_with(model_path)

    def test_create_piper_engine_auto_find(self):
        """Test creating Piper TTS engine with auto model detection"""
        config = ConversionConfig(engine="piper")
        
        with patch('piper_simple.PiperTTSEngine') as mock_engine, \
             patch.object(self.factory, '_find_piper_model') as mock_find:
            
            mock_find.return_value = Path("found_model.onnx")
            engine = self.factory.create_engine(config)
            
            mock_find.assert_called_once()
            mock_engine.assert_called_once_with(Path("found_model.onnx"))

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
            
            with patch('factory_simple.Path') as mock_path:
                mock_path.return_value = models_dir
                mock_path.side_effect = lambda x: Path(x) if x == "models" else Path(x)
                
                result = self.factory._find_piper_model()
                
                self.assertEqual(result.name, "test_model.onnx")

    def test_find_piper_model_not_found(self):
        """Test finding Piper model when none exists"""
        with tempfile.TemporaryDirectory() as temp_dir:
            models_dir = Path(temp_dir) / "nonexistent"
            
            with patch('factory_simple.Path') as mock_path:
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
        with patch('edge_simple.edge_tts') as mock_edge_tts:
            from edge_simple import EdgeTTSEngine
            engine = EdgeTTSEngine("pt-BR-FranciscaNeural")
            
            self.assertEqual(engine.voice, "pt-BR-FranciscaNeural")
            self.assertEqual(engine._edge_tts, mock_edge_tts)

    def test_init_missing_dependency(self):
        """Test EdgeTTSEngine initialization with missing dependency"""
        with patch('edge_simple.edge_tts', side_effect=ImportError("No module")):
            from edge_simple import EdgeTTSEngine
            
            with self.assertRaises(ImportError) as context:
                EdgeTTSEngine("test-voice")
            
            self.assertIn("Edge-TTS not installed", str(context.exception))

    async def test_synthesize_async_success(self):
        """Test successful text synthesis"""
        with patch('edge_simple.edge_tts') as mock_edge_tts:
            from edge_simple import EdgeTTSEngine
            
            # Mock communicate object
            mock_communicate = AsyncMock()
            mock_edge_tts.Communicate.return_value = mock_communicate
            
            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"
            
            # Create output file (simulating successful synthesis)
            output_path.write_text("A" * 2000)
            
            result = await engine.synthesize_async("Hello world", output_path)
            
            self.assertEqual(result, output_path)
            mock_edge_tts.Communicate.assert_called_once_with("Hello world", "test-voice")
            mock_communicate.save.assert_called_once_with(str(output_path))

    async def test_synthesize_async_empty_text(self):
        """Test synthesis with empty text"""
        with patch('edge_simple.edge_tts') as mock_edge_tts:
            from edge_simple import EdgeTTSEngine
            
            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"
            
            result = await engine.synthesize_async("", output_path)
            
            self.assertIsNone(result)
            mock_edge_tts.Communicate.assert_not_called()

    async def test_synthesize_async_timeout(self):
        """Test synthesis with timeout"""
        with patch('edge_simple.edge_tts') as mock_edge_tts, \
             patch('edge_simple.asyncio.wait_for') as mock_wait_for:
            
            from edge_simple import EdgeTTSEngine
            
            # Mock timeout
            mock_wait_for.side_effect = asyncio.TimeoutError()
            
            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"
            
            result = await engine.synthesize_async("Hello world", output_path)
            
            self.assertIsNone(result)

    async def test_synthesize_async_exception(self):
        """Test synthesis with exception"""
        with patch('edge_simple.edge_tts') as mock_edge_tts:
            from edge_simple import EdgeTTSEngine
            
            # Mock communicate to raise exception
            mock_communicate = AsyncMock()
            mock_communicate.save.side_effect = Exception("Test error")
            mock_edge_tts.Communicate.return_value = mock_communicate
            
            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"
            
            result = await engine.synthesize_async("Hello world", output_path)
            
            self.assertIsNone(result)

    def test_calculate_timeout(self):
        """Test timeout calculation"""
        with patch('edge_simple.edge_tts'):
            from edge_simple import EdgeTTSEngine
            
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
        with patch('coqui_simple.TTS') as mock_tts:
            from coqui_simple import CoquiTTSEngine
            
            engine = CoquiTTSEngine("test_model")
            
            self.assertEqual(engine.model_name, "test_model")
            self.assertIsNone(engine.tts)  # Lazy initialization
            self.assertEqual(engine._tts_class, mock_tts)

    def test_init_missing_dependency(self):
        """Test CoquiTTSEngine initialization with missing dependency"""
        with patch('coqui_simple.TTS', side_effect=ImportError("No module")):
            from coqui_simple import CoquiTTSEngine
            
            with self.assertRaises(ImportError) as context:
                CoquiTTSEngine("test_model")
            
            self.assertIn("Coqui TTS not installed", str(context.exception))

    def test_initialize_model(self):
        """Test lazy model initialization"""
        with patch('coqui_simple.TTS') as mock_tts_class:
            from coqui_simple import CoquiTTSEngine
            
            mock_tts_instance = Mock()
            mock_tts_class.return_value = mock_tts_instance
            
            engine = CoquiTTSEngine("test_model")
            engine._initialize_model()
            
            self.assertEqual(engine.tts, mock_tts_instance)
            mock_tts_class.assert_called_once_with(model_name="test_model")

    async def test_synthesize_async_success(self):
        """Test successful text synthesis"""
        with patch('coqui_simple.TTS') as mock_tts_class:
            from coqui_simple import CoquiTTSEngine
            
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
        with patch('coqui_simple.TTS'):
            from coqui_simple import CoquiTTSEngine
            
            engine = CoquiTTSEngine("test_model")
            output_path = Path(self.temp_dir) / "output.wav"
            
            result = await engine.synthesize_async("", output_path)
            
            self.assertIsNone(result)

    async def test_synthesize_async_exception(self):
        """Test synthesis with exception"""
        with patch('coqui_simple.TTS') as mock_tts_class:
            from coqui_simple import CoquiTTSEngine
            
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
        from piper_simple import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        
        self.assertEqual(engine.model_path, self.model_path)

    def test_init_missing_model(self):
        """Test PiperTTSEngine initialization with missing model"""
        from piper_simple import PiperTTSEngine
        
        nonexistent_model = Path(self.temp_dir) / "nonexistent.onnx"
        
        with self.assertRaises(FileNotFoundError):
            PiperTTSEngine(nonexistent_model)

    async def test_synthesize_async_success(self):
        """Test successful text synthesis"""
        from piper_simple import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "output.wav"
        
        with patch('piper_simple.asyncio.create_subprocess_exec') as mock_subprocess:
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
        from piper_simple import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "output.wav"
        
        result = await engine.synthesize_async("", output_path)
        
        self.assertIsNone(result)

    async def test_synthesize_async_piper_failure(self):
        """Test synthesis with Piper failure"""
        from piper_simple import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "output.wav"
        
        with patch('piper_simple.asyncio.create_subprocess_exec') as mock_subprocess:
            # Mock failed piper process
            mock_process = AsyncMock()
            mock_process.communicate.return_value = (b"", b"Error occurred")
            mock_process.returncode = 1  # Failure
            mock_subprocess.return_value = mock_process
            
            result = await engine.synthesize_async("Hello world", output_path)
            
            self.assertIsNone(result)

    async def test_synthesize_async_piper_not_found(self):
        """Test synthesis when Piper is not installed"""
        from piper_simple import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "output.wav"
        
        with patch('piper_simple.asyncio.create_subprocess_exec') as mock_subprocess:
            mock_subprocess.side_effect = FileNotFoundError("Piper not found")
            
            result = await engine.synthesize_async("Hello world", output_path)
            
            self.assertIsNone(result)

    async def test_synthesize_async_exception(self):
        """Test synthesis with exception"""
        from piper_simple import PiperTTSEngine
        
        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "output.wav"
        
        with patch('piper_simple.asyncio.create_subprocess_exec') as mock_subprocess:
            mock_subprocess.side_effect = Exception("Test error")
            
            result = await engine.synthesize_async("Hello world", output_path)
            
            self.assertIsNone(result)


if __name__ == '__main__':
    unittest.main()