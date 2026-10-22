"""Piper regression scenarios, collected by test_tts."""

from python_app.tests._tts_test_support import AsyncMock as AsyncMock
from python_app.tests._tts_test_support import Path as Path
from python_app.tests._tts_test_support import os as os
from python_app.tests._tts_test_support import patch as patch
from python_app.tests._tts_test_support import sys as sys
from python_app.tests._tts_test_support import tempfile as tempfile
from python_app.tests._tts_test_support import unittest as unittest


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
