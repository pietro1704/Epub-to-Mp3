# -*- coding: utf-8 -*-
"""
Unit tests for simplified TTS modules
"""

import asyncio
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.config import ConversionConfig
from src.text_formatting import FormattingSegment, TextFormattingProcessor


class TestTTSFactory(unittest.TestCase):
    """Test cases for TTSFactory"""

    def setUp(self):
        """Set up test fixtures"""
        from src.tts.factory import TTSFactory

        self.factory = TTSFactory()

    def test_create_edge_engine(self):
        """Test creating Edge TTS engine"""
        config = ConversionConfig(engine="edge", voice="pt-BR-FranciscaNeural")

        with patch("src.tts.edge_engine.EdgeTTSEngine") as mock_engine:
            engine = self.factory.create_engine(config)

            mock_engine.assert_called_once()
            args, kwargs = mock_engine.call_args
            self.assertEqual(args[0], "pt-BR-FranciscaNeural")
            self.assertEqual(kwargs.get("primary_language"), "auto")
            self.assertEqual(kwargs.get("language_voices"), {})
            self.assertEqual(kwargs.get("verbose"), False)
            self.assertEqual(kwargs.get("max_segment_seconds"), config.edge_max_segment_seconds)
            self.assertEqual(kwargs.get("chunk_char_limit"), config.edge_chunk_chars)

    def test_create_coqui_engine(self):
        """Test creating Coqui TTS engine"""
        config = ConversionConfig(engine="coqui", voice="test_model")

        with patch("src.tts.coqui_engine.CoquiTTSEngine") as mock_engine:
            engine = self.factory.create_engine(config)

            mock_engine.assert_called_once()
            args, kwargs = mock_engine.call_args
            self.assertEqual(args[0], "test_model")
            self.assertEqual(kwargs.get("primary_language"), "auto")
            self.assertEqual(kwargs.get("language_voices"), {})
            self.assertEqual(kwargs.get("verbose"), False)
            # Coqui may receive gpu flag; ensure bool if present
            if "gpu" in kwargs:
                self.assertIn(kwargs["gpu"], (True, False))

    def test_create_piper_engine(self):
        """Test creating Piper TTS engine"""
        model_path = Path("test_model.onnx")
        config = ConversionConfig(engine="piper", model_path=model_path)

        with patch("src.tts.piper_engine.PiperTTSEngine") as mock_engine:
            engine = self.factory.create_engine(config)

            mock_engine.assert_called_once()
            args, kwargs = mock_engine.call_args
            self.assertEqual(args[0], model_path)
            self.assertEqual(kwargs.get("primary_language"), "auto")
            self.assertEqual(kwargs.get("language_voices"), {})

    def test_create_piper_engine_auto_find(self):
        """Test creating Piper TTS engine with auto model detection"""
        config = ConversionConfig(engine="piper")

        with (
            patch("src.tts.piper_engine.PiperTTSEngine") as mock_engine,
            patch.object(self.factory, "_find_piper_model") as mock_find,
        ):
            mock_find.return_value = Path("found_model.onnx")
            engine = self.factory.create_engine(config)

            mock_find.assert_called_once()
            mock_engine.assert_called_once()
            args, kwargs = mock_engine.call_args
            self.assertEqual(args[0], Path("found_model.onnx"))
            self.assertEqual(kwargs.get("primary_language"), "auto")
            self.assertEqual(kwargs.get("language_voices"), {})

    def test_create_unsupported_engine(self):
        """Test creating unsupported engine"""
        config = ConversionConfig(engine="unsupported")

        with self.assertRaises(ValueError) as context:
            self.factory.create_engine(config)

        self.assertIn("Unsupported engine", str(context.exception))

    def test_create_kokoro_engine(self):
        """Test creating Kokoro TTS engine when environment is supported."""
        config = ConversionConfig(engine="kokoro", primary_language="en-US", voice="kokoro_voice")
        fake_module = types.ModuleType("src.tts.kokoro_engine")
        mock_engine = Mock()
        fake_module.KokoroTTSEngine = Mock(return_value=mock_engine)
        fake_module.kokoro_supports_language = Mock(return_value=True)

        with (
            patch("src.tts.factory.is_kokoro_supported_environment", return_value=True),
            patch.dict(sys.modules, {"src.tts.kokoro_engine": fake_module}),
        ):
            engine = self.factory.create_engine(config)

        fake_module.KokoroTTSEngine.assert_called_once()
        self.assertIs(engine, mock_engine)

    def test_create_spark_engine(self):
        """Test creating Spark TTS engine when dependencies are available."""
        config = ConversionConfig(engine="spark", voice="spark-voice")
        fake_module = types.ModuleType("src.tts.spark_engine")
        mock_engine = Mock()
        fake_module.SparkTTSEngine = Mock(return_value=mock_engine)

        with (
            patch("src.tts.factory.is_spark_supported_environment", return_value=True),
            patch.dict(sys.modules, {"src.tts.spark_engine": fake_module}),
        ):
            engine = self.factory.create_engine(config)

        fake_module.SparkTTSEngine.assert_called_once()
        self.assertIs(engine, mock_engine)

    def test_available_engines_includes_piper_without_models(self):
        """Piper should be advertised when the binary exists even if no models are cached."""
        with (
            patch("shutil.which", return_value="/usr/bin/piper"),
            patch("src.tts.factory.is_piper_supported_environment", return_value=True),
            patch("src.tts.factory.is_coqui_supported_environment", return_value=False),
            patch("src.tts.factory.is_kokoro_supported_environment", return_value=False),
            patch("src.tts.factory.is_spark_supported_environment", return_value=False),
        ):
            engines = self.factory.available_engines()
        self.assertIn("piper", engines)

    def test_find_piper_model_success(self):
        """Test finding Piper model successfully"""
        with tempfile.TemporaryDirectory() as temp_dir:
            models_dir = Path(temp_dir) / "models"
            models_dir.mkdir()

            model_file = models_dir / "test_model.onnx"
            model_file.write_text("dummy model")

            with patch("src.tts.factory.Path") as mock_path:
                mock_path.return_value = models_dir
                mock_path.side_effect = lambda x: Path(x) if x == "models" else Path(x)

                result = self.factory._find_piper_model()

                self.assertEqual(result.name, "test_model.onnx")

    def test_find_piper_model_not_found(self):
        """Test finding Piper model when none exists"""
        with tempfile.TemporaryDirectory() as temp_dir:
            models_dir = Path(temp_dir) / "nonexistent"

        with patch("src.tts.factory.Path") as mock_path:
            mock_path.return_value = models_dir

            with self.assertRaises(FileNotFoundError):
                self.factory._find_piper_model()

    def test_kokoro_rejected_for_portuguese(self):
        """Kokoro should not be used for pt-BR since there is no native voice."""
        config = ConversionConfig(engine="kokoro", primary_language="pt-BR")
        with self.assertRaises(ValueError) as exc:
            self.factory.create_engine(config)
        message = str(exc.exception)
        self.assertIn("Kokoro", message)
        self.assertIn("pt-BR", message)


class TestEdgeTTSEngine(unittest.IsolatedAsyncioTestCase):
    """Test cases for EdgeTTSEngine"""

    def setUp(self):
        """Set up test fixtures"""
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src", "tts"))
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_init_success(self):
        """Test successful EdgeTTSEngine initialization"""
        with patch("src.tts.edge_engine.edge_tts") as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine

            engine = EdgeTTSEngine("pt-BR-FranciscaNeural")

            self.assertEqual(engine.voice, "pt-BR-FranciscaNeural")
            self.assertEqual(engine._edge_tts, mock_edge_tts)

    def test_init_missing_dependency(self):
        """Test EdgeTTSEngine initialization with missing dependency"""
        with patch("src.tts.edge_engine.edge_tts", side_effect=ImportError("No module")):
            from src.tts.edge_engine import EdgeTTSEngine

            with self.assertRaises(ImportError) as context:
                EdgeTTSEngine("test-voice")

            self.assertIn("Edge-TTS not installed", str(context.exception))

    async def test_synthesize_async_success(self):
        """Test successful text synthesis"""
        with patch("src.tts.edge_engine.edge_tts") as mock_edge_tts:
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
        with patch("src.tts.edge_engine.edge_tts") as mock_edge_tts:
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
                return DummyCommunicate(
                    [
                        {"type": "audio", "data": b"X"},
                    ]
                )

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
            # Esperamos três segmentos: PT → EN → PT
            self.assertEqual(len(calls), 3)
            self.assertEqual(calls[0][1], "pt-BR-ThalitaMultilingualNeural")
            self.assertEqual(calls[1][1], "en-US-JennyNeural")
            self.assertEqual(calls[2][1], "pt-BR-ThalitaMultilingualNeural")
            for payload, _voice in calls:
                self.assertNotIn("<speak", payload.lower())
                self.assertNotIn("[[fmt:", payload)

    def test_edge_chunk_guard_on_rate_limit(self):
        """Ensure Edge shrinks chunk size when rate limits or long texts are detected."""
        with patch("src.tts.edge_engine.edge_tts"):
            import src.tts.edge_engine as edge_mod
            from src.tts.edge_engine import EdgeTTSEngine

            previous = edge_mod._edge_rate_limit_count
            edge_mod._edge_rate_limit_count = 1  # Simulate prior rate limit

            try:
                engine = EdgeTTSEngine("pt-BR-FranciscaNeural", chunk_char_limit=10000)
                long_text = "palavra " * 3000  # ~24k chars
                chunks = engine._chunk_text("pt-BR-FranciscaNeural", long_text)
                max_chunk = max(len(text) for _voice, text in chunks)
                self.assertLessEqual(max_chunk, 4000)
            finally:
                edge_mod._edge_rate_limit_count = previous

    async def test_synthesize_async_adds_audible_cues_for_formatting(self):
        """Edge engine should convert formatting markers into audible cues."""
        with patch("src.tts.edge_engine.edge_tts") as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine

            captured = []

            class DummyCommunicate:
                def __init__(self, text, voice):
                    captured.append((text, voice))

                async def stream(self):
                    yield {"type": "audio", "data": b"X"}

            mock_edge_tts.Communicate.side_effect = lambda text, voice: DummyCommunicate(
                text, voice
            )

            engine = EdgeTTSEngine("pt-BR-FranciscaNeural")
            output_path = Path(self.temp_dir) / "output_cues.wav"

            segments = [
                FormattingSegment(text="Palavra", formatting="italic"),
                FormattingSegment(text="seguida", formatting="normal"),
            ]

            result = await engine.synthesize_async(
                "Palavra seguida", output_path, formatting_segments=segments
            )

            self.assertEqual(result, output_path)
            self.assertTrue(captured, "Expected at least one call to Communicate")
            payload, voice = captured[0]
            self.assertIn("em itálico:", payload)
            self.assertNotIn("[[fmt:", payload)
            self.assertEqual(voice, "pt-BR-FranciscaNeural")

    async def test_long_text_chunking_preserves_full_content(self):
        """Long payloads should be chunked without losing content."""
        with patch("src.tts.edge_engine.edge_tts") as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine

            calls = []

            class DummyCommunicate:
                def __init__(self, text, voice):
                    calls.append((text, voice))

                async def stream(self):
                    yield {"type": "audio", "data": b"X"}

            mock_edge_tts.Communicate.side_effect = lambda text, voice: DummyCommunicate(
                text, voice
            )

            engine = EdgeTTSEngine("pt-BR-FranciscaNeural")
            output_path = Path(self.temp_dir) / "chunked.wav"

            base_block = "Esta é uma frase muito longa para testar o particionamento do Edge TTS. "
            text = base_block * 400  # > 7000 chars

            result = await engine.synthesize_async(text, output_path)

            self.assertEqual(result, output_path)
            self.assertGreater(
                len(calls), 1, "Texto longo deve ser dividido em múltiplos segmentos"
            )

            aggregated = " ".join(payload for payload, _ in calls)
            expected = TextFormattingProcessor.clean_tts_text(text)
            # Normalize whitespace for comparison (chunking may adjust spacing)
            import re

            normalize = lambda s: re.sub(r"\s+", " ", s).strip()
            self.assertEqual(normalize(aggregated), normalize(expected))

            for payload, _voice in calls:
                self.assertLessEqual(
                    len(payload), 7000 + 500, "Segmento excedeu o limite esperado (~7000 chars)"
                )

    async def test_synthesize_async_empty_text(self):
        """Test synthesis with empty text"""
        with patch("src.tts.edge_engine.edge_tts") as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine

            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"

            result = await engine.synthesize_async("", output_path)

            self.assertIsNone(result)
            mock_edge_tts.Communicate.assert_not_called()

    async def test_synthesize_async_timeout(self):
        """Test synthesis with timeout"""
        with patch("src.tts.edge_engine.edge_tts") as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine

            class TimeoutCommunicate:
                async def stream(self):
                    raise asyncio.TimeoutError()

            mock_edge_tts.Communicate.return_value = TimeoutCommunicate()

            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"

            result = await engine.synthesize_async("Hello world", output_path)

            self.assertIsNone(result)
            # Error handling updated: last_error is "no_audio" if no audio chunks received
            self.assertEqual(engine.last_error, "no_audio")

    async def test_synthesize_async_exception(self):
        """Test synthesis with exception"""
        with patch("src.tts.edge_engine.edge_tts") as mock_edge_tts:
            from src.tts.edge_engine import EdgeTTSEngine

            class ErrorCommunicate:
                async def stream(self):
                    raise RuntimeError("Test error")

            mock_edge_tts.Communicate.return_value = ErrorCommunicate()

            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"

            result = await engine.synthesize_async("Hello world", output_path)

            self.assertIsNone(result)
            # Error handling updated: last_error is "no_audio" if no audio chunks received
            self.assertEqual(engine.last_error, "no_audio")

    def test_calculate_timeout(self):
        """Test timeout calculation (otimizado para falhar rápido)"""
        with patch("src.tts.edge_engine.edge_tts"):
            from src.tts.edge_engine import EdgeTTSEngine

            engine = EdgeTTSEngine("test-voice")

            # Short text - timeout mínimo de 45s
            timeout = engine._calculate_timeout("Hi")
            self.assertEqual(timeout, 45)

            # Medium text
            medium_text = "A" * 2000
            timeout = engine._calculate_timeout(medium_text)
            self.assertGreaterEqual(timeout, 45)  # Mínimo 45s

            # Long text - máximo de 300s
            long_text = "A" * 10000
            timeout = engine._calculate_timeout(long_text)
            self.assertGreaterEqual(timeout, 45)
            self.assertLessEqual(timeout, 300)  # Máximo 300s


class TestCoquiTTSEngine(unittest.IsolatedAsyncioTestCase):
    """Test cases for CoquiTTSEngine"""

    def setUp(self):
        """Set up test fixtures"""
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src", "tts"))
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_init_success(self):
        """Test successful CoquiTTSEngine initialization"""
        with patch("src.tts.coqui_engine.TTS") as mock_tts:
            from src.tts.coqui_engine import CoquiTTSEngine

            engine = CoquiTTSEngine("test_model")

            self.assertEqual(engine.model_name, "test_model")
            self.assertIsNone(engine.tts)  # Lazy initialization
            self.assertEqual(engine._tts_class, mock_tts)

    def test_init_missing_dependency(self):
        """Test CoquiTTSEngine initialization with missing dependency"""
        with patch("src.tts.coqui_engine.TTS", side_effect=ImportError("No module")):
            from src.tts.coqui_engine import CoquiTTSEngine

            with self.assertRaises(ImportError) as context:
                CoquiTTSEngine("test_model")

            self.assertIn("Coqui TTS not installed", str(context.exception))

    def test_initialize_model(self):
        """Test lazy model initialization"""
        with patch("src.tts.coqui_engine.TTS") as mock_tts_class:
            from src.tts.coqui_engine import CoquiTTSEngine

            mock_tts_instance = Mock()
            mock_tts_class.return_value = mock_tts_instance

            engine = CoquiTTSEngine("test_model")
            engine._initialize_model()

            self.assertEqual(engine.tts, mock_tts_instance)
            mock_tts_class.assert_called_once()
            args, kwargs = mock_tts_class.call_args
            self.assertEqual(kwargs.get("model_name"), "test_model")
            if "gpu" in kwargs:
                self.assertIn(kwargs["gpu"], (True, False))

    async def test_synthesize_async_success(self):
        """Test successful text synthesis"""
        with patch("src.tts.coqui_engine.TTS") as mock_tts_class:
            from src.tts.coqui_engine import CoquiTTSEngine

            mock_tts_instance = Mock()
            mock_tts_instance.tts_to_file = Mock()
            mock_tts_class.return_value = mock_tts_instance

            engine = CoquiTTSEngine("test_model")
            output_path = Path(self.temp_dir) / "output.wav"

            # Create output file (simulating successful synthesis)
            output_path.write_text("A" * 2000)

            with patch("asyncio.get_event_loop") as mock_loop:
                mock_executor = AsyncMock()
                mock_loop.return_value.run_in_executor = mock_executor

                result = await engine.synthesize_async("Hello world", output_path)

                self.assertEqual(result, output_path)
                mock_executor.assert_called_once()

    async def test_synthesize_async_empty_text(self):
        """Test synthesis with empty text"""
        with patch("src.tts.coqui_engine.TTS"):
            from src.tts.coqui_engine import CoquiTTSEngine

            engine = CoquiTTSEngine("test_model")
            output_path = Path(self.temp_dir) / "output.wav"

            result = await engine.synthesize_async("", output_path)

            self.assertIsNone(result)

    def test_coqui_phonemizer_limit_chunks_segments(self):
        """Ensure Coqui splits long PT text to avoid phonemizer truncation."""
        from src.tts import coqui_engine

        segments = [("pt", " ".join(["teste"] * 60))]  # ~360 chars
        expanded = coqui_engine._expand_segments_with_limits(
            segments, max_chars=500, verbose=False, phonemizer_limit_fn=lambda lang: 200
        )

        self.assertGreater(len(expanded), 1)
        self.assertTrue(all(len(text) <= 200 for _, text in expanded))

    async def test_synthesize_async_exception(self):
        """Test synthesis with exception"""
        with patch("src.tts.coqui_engine.TTS") as mock_tts_class:
            from src.tts.coqui_engine import CoquiTTSEngine

            mock_tts_instance = Mock()
            mock_tts_instance.tts_to_file.side_effect = Exception("Test error")
            mock_tts_class.return_value = mock_tts_instance

            engine = CoquiTTSEngine("test_model")
            output_path = Path(self.temp_dir) / "output.wav"

            with patch("asyncio.get_event_loop") as mock_loop:
                mock_executor = AsyncMock()
                mock_executor.side_effect = Exception("Test error")
                mock_loop.return_value.run_in_executor = mock_executor

                result = await engine.synthesize_async("Hello world", output_path)

                self.assertIsNone(result)


class TestPiperTTSEngine(unittest.IsolatedAsyncioTestCase):
    """Test cases for PiperTTSEngine"""

    def setUp(self):
        """Set up test fixtures"""
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src", "tts"))
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

        with patch("src.tts.piper_engine.asyncio.create_subprocess_exec") as mock_subprocess:
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

        with patch("src.tts.piper_engine.asyncio.create_subprocess_exec") as mock_subprocess:
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

        with patch("src.tts.piper_engine.asyncio.create_subprocess_exec") as mock_subprocess:
            mock_subprocess.side_effect = FileNotFoundError("Piper not found")

            result = await engine.synthesize_async("Hello world", output_path)

            self.assertIsNone(result)

    async def test_synthesize_async_exception(self):
        """Test synthesis with exception"""
        from src.tts.piper_engine import PiperTTSEngine

        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "output.wav"

        with patch("src.tts.piper_engine.asyncio.create_subprocess_exec") as mock_subprocess:
            mock_subprocess.side_effect = Exception("Test error")

            result = await engine.synthesize_async("Hello world", output_path)

            self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
