# -*- coding: utf-8 -*-
"""
Unit tests for simplified TTS modules
"""

import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from python_app.tests._tts_piper_cases import TestPiperTTSEngine as TestPiperTTSEngine
from python_app.tests._tts_test_support import ConversionConfig as ConversionConfig
from python_app.tests._tts_test_support import FormattingSegment as FormattingSegment
from python_app.tests._tts_test_support import TextFormattingProcessor as TextFormattingProcessor
from python_app.tests._tts_test_support import asyncio as asyncio
from python_app.tests._tts_test_support import os as os
from python_app.tests._tts_test_support import patch as patch
from python_app.tests._tts_test_support import tempfile as tempfile
from python_app.tests._tts_test_support import unittest as unittest


class TestTTSFactory(unittest.TestCase):
    """Test cases for TTSFactory"""

    def setUp(self):
        """Set up test fixtures"""
        from src.tts.factory import TTSFactory

        self.factory = TTSFactory()

    def test_create_edge_engine(self):
        """Test creating Edge TTS engine"""
        sink = object()
        config = ConversionConfig(
            engine="edge",
            voice="pt-BR-FranciscaNeural",
            segment_metric_sink=sink,
        )

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
            self.assertIs(kwargs.get("metric_callback"), sink)

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

    def test_available_engines_excludes_piper_without_models(self):
        """Piper requires an explicitly installed local model."""
        with (
            patch("shutil.which", return_value="/usr/bin/piper"),
            patch("src.tts.factory.is_piper_supported_environment", return_value=True),
            patch.object(self.factory, "_find_piper_model", side_effect=FileNotFoundError),
        ):
            engines = self.factory.available_engines()
        self.assertNotIn("piper", engines)

    def test_find_piper_model_success(self):
        """Test finding Piper model successfully"""
        with tempfile.TemporaryDirectory() as temp_dir:
            models_dir = Path(temp_dir) / "models"
            models_dir.mkdir()

            model_file = models_dir / "test_model.onnx"
            model_file.write_text("dummy model")

            # Use PIPER_MODEL_DIR so the factory finds the temp dir first
            with patch.dict("os.environ", {"PIPER_MODEL_DIR": str(models_dir)}):
                result = self.factory._find_piper_model()

                self.assertEqual(result.name, "test_model.onnx")

    def test_find_piper_model_not_found_without_download(self):
        """Missing local Piper models fail without attempting network access."""
        with tempfile.TemporaryDirectory() as temp_dir:
            models_dir = Path(temp_dir) / "nonexistent"

        with patch("src.tts.factory.Path") as mock_path:
            mock_path.return_value = models_dir
            with patch("urllib.request.urlretrieve") as mock_download:
                with self.assertRaises(FileNotFoundError):
                    self.factory._find_piper_model()
            mock_download.assert_not_called()


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
                    {"type": "audio", "data": b"D" * 2048},
                    {"type": "WordBoundary", "data": {}},
                ]
            )

            engine = EdgeTTSEngine("test-voice")
            output_path = Path(self.temp_dir) / "output.wav"

            result = await engine.synthesize_async("Hello world", output_path)

            self.assertEqual(result, output_path)
            self.assertEqual(output_path.read_bytes(), b"D" * 2048)
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
                        {"type": "audio", "data": b"X" * 2048},
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
            # Expect three segments: PT → EN → PT
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
                    yield {"type": "audio", "data": b"X" * 2048}

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
                    yield {"type": "audio", "data": b"X" * 2048}

            mock_edge_tts.Communicate.side_effect = lambda text, voice: DummyCommunicate(
                text, voice
            )

            engine = EdgeTTSEngine("pt-BR-FranciscaNeural")
            output_path = Path(self.temp_dir) / "chunked.wav"

            base_block = "Esta é uma frase muito longa para testar o particionamento do Edge TTS. "
            text = base_block * 400  # > 7000 chars

            result = await engine.synthesize_async(text, output_path)

            self.assertEqual(result, output_path)
            self.assertGreater(len(calls), 1, "Long text must be split into multiple segments")

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
        """Test timeout calculation (optimized to fail fast)"""
        with patch("src.tts.edge_engine.edge_tts"):
            from src.tts.edge_engine import EdgeTTSEngine

            engine = EdgeTTSEngine("test-voice")

            # Short text - minimum 45s timeout
            timeout = engine._calculate_timeout("Hi")
            self.assertEqual(timeout, 45)

            # Medium text
            medium_text = "A" * 2000
            timeout = engine._calculate_timeout(medium_text)
            self.assertGreaterEqual(timeout, 45)  # Minimum 45s

            # Long text - maximum 300s
            long_text = "A" * 10000
            timeout = engine._calculate_timeout(long_text)
            self.assertGreaterEqual(timeout, 45)
            self.assertLessEqual(timeout, 300)  # Maximum 300s


if __name__ == "__main__":
    unittest.main()
