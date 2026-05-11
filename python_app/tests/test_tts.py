# -*- coding: utf-8 -*-
"""
Unit tests for simplified TTS modules
"""

import asyncio
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

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

    def test_available_engines_includes_piper_without_models(self):
        """Piper should be advertised when the binary exists even if no models are cached."""
        with (
            patch("shutil.which", return_value="/usr/bin/piper"),
            patch("src.tts.factory.is_piper_supported_environment", return_value=True),
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

            # Use PIPER_MODEL_DIR so the factory finds the temp dir first
            with patch.dict("os.environ", {"PIPER_MODEL_DIR": str(models_dir)}):
                result = self.factory._find_piper_model()

                self.assertEqual(result.name, "test_model.onnx")

    def test_find_piper_model_not_found(self):
        """Test finding Piper model when none exists and download also fails"""
        with tempfile.TemporaryDirectory() as temp_dir:
            models_dir = Path(temp_dir) / "nonexistent"

        with patch("src.tts.factory.Path") as mock_path:
            mock_path.return_value = models_dir
            # Simulate download failure so FileNotFoundError is still raised
            with patch("urllib.request.urlretrieve", side_effect=OSError("network error")):
                with self.assertRaises(FileNotFoundError):
                    self.factory._find_piper_model()

    def test_find_piper_model_preferred_language_not_found_downloads_instead_of_wrong_model(self):
        """When models exist but not for the preferred language, download the right one
        instead of silently returning a wrong-language model."""
        with tempfile.TemporaryDirectory() as temp_dir:
            # Test via _download_default_piper_model: "es" → ES model, not EN fallback.
            # Use PIPER_MODEL_DIR to avoid writing to the real models directory.
            with patch("urllib.request.urlretrieve") as mock_dl:

                def fake_urlretrieve(url, dest):
                    Path(dest).write_text("dummy")

                mock_dl.side_effect = fake_urlretrieve
                with patch.dict("os.environ", {"PIPER_MODEL_DIR": temp_dir}):
                    result = self.factory._download_default_piper_model("es")
                    self.assertIsNotNone(result)
                    self.assertIn("es_ES", str(result))

    def test_find_piper_model_unknown_language_fallback_downloads_english_not_portuguese(self):
        """Unknown language fallback downloads English model, not Portuguese."""
        with patch("urllib.request.urlretrieve") as mock_dl:
            downloaded_paths = []

            def fake_urlretrieve(url, dest):
                downloaded_paths.append(url)
                Path(dest).write_text("dummy")

            mock_dl.side_effect = fake_urlretrieve
            # "xx" is unknown — should fall back to "en", not "pt"
            with tempfile.TemporaryDirectory() as temp_dir:
                with patch.dict("os.environ", {"PIPER_MODEL_DIR": temp_dir}):
                    result = self.factory._download_default_piper_model("xx")
                    self.assertIsNotNone(result)
                    self.assertTrue(
                        any("en_US" in url for url in downloaded_paths),
                        f"Expected English model download, got: {downloaded_paths}",
                    )
                    self.assertFalse(
                        any("pt_BR" in url for url in downloaded_paths),
                        f"Should not download Portuguese model for unknown language: {downloaded_paths}",
                    )


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
            mock_process.returncode = 0

            async def _communicate(input=None):
                output_path.write_text("A" * 2000)
                return (b"success", b"")

            mock_process.communicate.side_effect = _communicate
            mock_subprocess.return_value = mock_process

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

    async def test_synthesize_chunked_synthesizes_all_chunks(self):
        """Chunked synthesis always synthesizes every chunk in an isolated temp dir."""
        from src.tts.piper_engine import PiperTTSEngine

        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "chunked.wav"

        async def fake_synthesize_single(text, path, model_path):
            Path(path).write_bytes(b"RIFF" + b"\x00" * 300)
            return Path(path)

        ffmpeg_calls = {"count": 0}

        async def fake_ffmpeg(*args, **kwargs):
            ffmpeg_calls["count"] += 1
            # Write the output WAV to the last positional arg (output path)
            out = Path(args[-1])
            out.write_bytes(b"RIFF" + b"\x00" * 300)
            proc = AsyncMock()
            proc.returncode = 0

            async def _wait():
                return 0

            proc.wait.side_effect = _wait
            return proc

        with patch("src.tts.piper_engine._split_text_into_chunks", return_value=["a", "b"]):
            with patch("src.tts.piper_engine._merge_small_chunks", return_value=["a", "b"]):
                with patch.object(
                    engine, "_synthesize_single", side_effect=fake_synthesize_single
                ) as mock_single:
                    with patch(
                        "src.tts.piper_engine.asyncio.create_subprocess_exec",
                        side_effect=fake_ffmpeg,
                    ):
                        result = await engine._synthesize_chunked(
                            "ab",
                            output_path,
                            self.model_path,
                        )

        self.assertEqual(result, output_path)
        self.assertEqual(ffmpeg_calls["count"], 1)
        # Both chunks must be synthesized; isolated temp dir means no stale reuse.
        self.assertEqual(mock_single.call_count, 2)

    async def test_synthesize_single_retries_after_failed_attempt(self):
        """Single chunk synthesis should retry when first subprocess attempt fails."""
        from src.tts.piper_engine import PiperTTSEngine

        engine = PiperTTSEngine(self.model_path)
        output_path = Path(self.temp_dir) / "retry.wav"
        calls = {"count": 0}

        def _build_process(return_code: int):
            proc = AsyncMock()
            proc.returncode = return_code

            async def _communicate(input=None):
                calls["count"] += 1
                if return_code == 0:
                    output_path.write_bytes(b"RIFF" + b"\x00" * 300)
                return (b"", b"")

            proc.communicate.side_effect = _communicate
            return proc

        with patch.dict(
            os.environ, {"PIPER_CHUNK_STALL_SECONDS": "0", "PIPER_CHUNK_MAX_RETRIES": "1"}
        ):
            with patch(
                "src.tts.piper_engine.asyncio.create_subprocess_exec",
                side_effect=[_build_process(1), _build_process(0)],
            ):
                result = await engine._synthesize_single("retry text", output_path, self.model_path)

        self.assertEqual(result, output_path)
        self.assertEqual(calls["count"], 2)


if __name__ == "__main__":
    unittest.main()
