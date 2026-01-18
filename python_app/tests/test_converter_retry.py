import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from python_app.src.config import ConversionConfig
from python_app.src.converter import AudioConverter


class _FakeTracker:
    def __init__(self, missing_segments):
        self._missing = missing_segments

    def get_missing_segments(self):
        return self._missing


class _FakeEngine:
    def __init__(self, tracker=None):
        self._tracker = tracker

    def get_synthesis_tracker(self):
        return self._tracker


class TestConverterSegmentRetry(unittest.IsolatedAsyncioTestCase):
    async def test_attempt_segment_retry_no_tracker(self):
        converter = AudioConverter()
        config = ConversionConfig(engine="edge")
        with tempfile.TemporaryDirectory() as tmp_dir:
            output_path = Path(tmp_dir) / "out.mp3"
            output_path.write_bytes(b"data")
            engine = object()
            result = await converter._attempt_segment_retry(
                engine, 1, "1", output_path, config=config
            )
            self.assertFalse(result)

    async def test_attempt_segment_retry_no_missing(self):
        converter = AudioConverter()
        config = ConversionConfig(engine="edge")
        with tempfile.TemporaryDirectory() as tmp_dir:
            output_path = Path(tmp_dir) / "out.mp3"
            output_path.write_bytes(b"data")
            engine = _FakeEngine(_FakeTracker([]))
            result = await converter._attempt_segment_retry(
                engine, 1, "1", output_path, config=config
            )
            self.assertFalse(result)

    @patch("python_app.src.retry_manager.RetryManager")
    async def test_attempt_segment_retry_success(self, mock_retry_manager):
        report = SimpleNamespace(successful=1, total_retried=1, still_failed=0)
        mock_instance = mock_retry_manager.return_value
        mock_instance.retry_failed_segments = AsyncMock(return_value=report)

        converter = AudioConverter()
        config = ConversionConfig(engine="edge")
        with tempfile.TemporaryDirectory() as tmp_dir:
            output_path = Path(tmp_dir) / "out.mp3"
            output_path.write_bytes(b"data")
            engine = _FakeEngine(_FakeTracker([0]))

            result = await converter._attempt_segment_retry(
                engine, 1, "1", output_path, config=config
            )

        self.assertTrue(result)
        mock_instance.retry_failed_segments.assert_awaited_once()
