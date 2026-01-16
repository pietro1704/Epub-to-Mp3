# -*- coding: utf-8 -*-
"""
Unit tests for retry_manager module
"""

import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock

from python_app.src.retry_manager import RetryManager, RetryReport
from python_app.src.synthesis_tracker import SegmentRecord


class TestRetryManager(unittest.IsolatedAsyncioTestCase):
    """Test cases for RetryManager class"""

    def setUp(self):
        """Set up test fixtures"""
        self.retry_manager = RetryManager(max_retries=3)
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up test fixtures"""
        import shutil

        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_initialization(self):
        """Test RetryManager initialization"""
        self.assertEqual(self.retry_manager.max_retries, 3)
        self.assertEqual(len(self.retry_manager.retry_history), 0)

    def test_initialization_custom_retries(self):
        """Test RetryManager with custom max retries"""
        manager = RetryManager(max_retries=5)
        self.assertEqual(manager.max_retries, 5)

    def test_default_max_retries(self):
        """Test default MAX_RETRIES constant"""
        self.assertEqual(RetryManager.MAX_RETRIES, 3)

    async def test_retry_single_segment_success_first_try(self):
        """Test retry succeeds on first attempt"""
        # Create failed segment
        segment = SegmentRecord.create(0, "Test text for retry")
        segment.status = "failed"
        failed_segments = [segment]

        # Mock engine with synthesize_segment that succeeds
        mock_engine = Mock()
        mock_engine.synthesize_segment = AsyncMock(return_value=True)

        output_path = Path(self.temp_dir) / "output.mp3"
        temp_dir = Path(self.temp_dir) / "retry"

        report = await self.retry_manager.retry_failed_segments(
            mock_engine, failed_segments, output_path, temp_dir
        )

        self.assertEqual(report.total_retried, 1)
        self.assertEqual(report.successful, 1)
        self.assertEqual(report.still_failed, 0)
        self.assertEqual(len(report.failed_segments), 0)
        self.assertEqual(len(report.retry_details), 1)
        self.assertEqual(report.retry_details[0]["status"], "success")
        self.assertEqual(report.retry_details[0]["attempt"], 1)

    async def test_retry_single_segment_success_second_try(self):
        """Test retry succeeds on second attempt"""
        segment = SegmentRecord.create(0, "Test text")
        segment.status = "failed"
        failed_segments = [segment]

        # Mock engine that fails first, succeeds second
        call_count = [0]

        async def mock_synthesize(text, output_path, formatting_segments=None):
            call_count[0] += 1
            if call_count[0] == 1:
                return False  # Fail first attempt
            else:
                # Succeed second attempt - create file
                Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                Path(output_path).write_bytes(b"audio" * 100)
                return True

        mock_engine = Mock()
        mock_engine.synthesize_segment = mock_synthesize

        output_path = Path(self.temp_dir) / "output.mp3"
        temp_dir = Path(self.temp_dir) / "retry"

        report = await self.retry_manager.retry_failed_segments(
            mock_engine, failed_segments, output_path, temp_dir
        )

        self.assertEqual(report.successful, 1)
        self.assertEqual(call_count[0], 2)  # Called twice
        self.assertEqual(report.retry_details[0]["attempt"], 2)

    async def test_retry_single_segment_all_attempts_fail(self):
        """Test retry fails after max attempts"""
        segment = SegmentRecord.create(0, "Test text")
        segment.status = "failed"
        failed_segments = [segment]

        # Mock engine that always fails
        mock_engine = Mock()
        mock_engine.synthesize_segment = AsyncMock(return_value=False)

        output_path = Path(self.temp_dir) / "output.mp3"
        temp_dir = Path(self.temp_dir) / "retry"

        report = await self.retry_manager.retry_failed_segments(
            mock_engine, failed_segments, output_path, temp_dir
        )

        self.assertEqual(report.total_retried, 1)
        self.assertEqual(report.successful, 0)
        self.assertEqual(report.still_failed, 1)
        self.assertEqual(len(report.failed_segments), 1)
        self.assertEqual(report.failed_segments[0].index, 0)
        self.assertEqual(report.retry_details[0]["status"], "failed")
        self.assertEqual(report.retry_details[0]["attempts"], 3)

    async def test_retry_multiple_segments_mixed_results(self):
        """Test retry with multiple segments having different outcomes"""
        # Create 3 failed segments
        segments = [
            SegmentRecord.create(0, "Text 0"),
            SegmentRecord.create(1, "Text 1"),
            SegmentRecord.create(2, "Text 2"),
        ]
        for seg in segments:
            seg.status = "failed"

        # Mock engine: segment 0 succeeds, segment 1 succeeds on retry 2, segment 2 always fails
        async def mock_synthesize(text, output_path, formatting_segments=None):
            idx = int(Path(output_path).stem.split("_")[1])  # Extract segment index from filename

            if idx == 0:
                # Always succeed for segment 0
                Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                Path(output_path).write_bytes(b"audio0" * 100)
                return True
            elif idx == 1:
                # Succeed on second call for segment 1
                if not hasattr(mock_synthesize, "seg1_calls"):
                    mock_synthesize.seg1_calls = 0
                mock_synthesize.seg1_calls += 1
                if mock_synthesize.seg1_calls >= 2:
                    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                    Path(output_path).write_bytes(b"audio1" * 100)
                    return True
                return False
            else:
                # Always fail for segment 2
                return False

        mock_engine = Mock()
        mock_engine.synthesize_segment = mock_synthesize

        output_path = Path(self.temp_dir) / "output.mp3"
        temp_dir = Path(self.temp_dir) / "retry"

        report = await self.retry_manager.retry_failed_segments(
            mock_engine, segments, output_path, temp_dir
        )

        self.assertEqual(report.total_retried, 3)
        self.assertEqual(report.successful, 2)  # Segments 0 and 1
        self.assertEqual(report.still_failed, 1)  # Segment 2
        self.assertEqual(len(report.failed_segments), 1)
        self.assertEqual(report.failed_segments[0].index, 2)

    async def test_retry_with_synthesize_async_fallback(self):
        """Test fallback to synthesize_async when synthesize_segment unavailable"""
        segment = SegmentRecord.create(0, "Test text")
        segment.status = "failed"
        failed_segments = [segment]

        # Mock engine without synthesize_segment but with synthesize_async
        async def mock_synthesize_async(
            text, output_path, formatting_segments=None, progress_callback=None, chunk_callback=None
        ):
            Path(output_path).parent.mkdir(parents=True, exist_ok=True)
            Path(output_path).write_bytes(b"audio" * 200)
            return Path(output_path)

        mock_engine = Mock()
        mock_engine.synthesize_async = mock_synthesize_async

        output_path = Path(self.temp_dir) / "output.mp3"
        temp_dir = Path(self.temp_dir) / "retry"

        report = await self.retry_manager.retry_failed_segments(
            mock_engine, failed_segments, output_path, temp_dir
        )

        self.assertEqual(report.successful, 1)
        self.assertEqual(report.retry_details[0]["status"], "success")

    async def test_retry_with_no_synthesis_methods(self):
        """Test when engine has no synthesis methods"""
        segment = SegmentRecord.create(0, "Test text")
        segment.status = "failed"
        failed_segments = [segment]

        # Mock engine without any synthesis methods
        mock_engine = Mock()

        output_path = Path(self.temp_dir) / "output.mp3"
        temp_dir = Path(self.temp_dir) / "retry"

        report = await self.retry_manager.retry_failed_segments(
            mock_engine, failed_segments, output_path, temp_dir
        )

        # Should fail since no synthesis methods available
        self.assertEqual(report.successful, 0)
        self.assertEqual(report.still_failed, 1)

    async def test_retry_with_exception(self):
        """Test retry when synthesis raises exception"""
        segment = SegmentRecord.create(0, "Test text")
        segment.status = "failed"
        failed_segments = [segment]

        # Mock engine that raises exception
        async def mock_synthesize_error(text, output_path, formatting_segments=None):
            raise RuntimeError("Network error")

        mock_engine = Mock()
        mock_engine.synthesize_segment = mock_synthesize_error

        output_path = Path(self.temp_dir) / "output.mp3"
        temp_dir = Path(self.temp_dir) / "retry"

        report = await self.retry_manager.retry_failed_segments(
            mock_engine, failed_segments, output_path, temp_dir
        )

        # Should fail gracefully
        self.assertEqual(report.successful, 0)
        self.assertEqual(report.still_failed, 1)

    async def test_retry_creates_temp_directory(self):
        """Test that retry creates temp directory if it doesn't exist"""
        segment = SegmentRecord.create(0, "Test text")
        segment.status = "failed"
        failed_segments = [segment]

        mock_engine = Mock()
        mock_engine.synthesize_segment = AsyncMock(return_value=False)

        output_path = Path(self.temp_dir) / "output.mp3"
        temp_dir = Path(self.temp_dir) / "nonexistent_retry_dir"

        # Verify temp dir doesn't exist
        self.assertFalse(temp_dir.exists())

        await self.retry_manager.retry_failed_segments(
            mock_engine, failed_segments, output_path, temp_dir
        )

        # Verify temp dir was created
        self.assertTrue(temp_dir.exists())

    async def test_retry_file_naming(self):
        """Test that retry files are named correctly"""
        segment = SegmentRecord.create(5, "Test text")  # Index 5
        segment.status = "failed"
        failed_segments = [segment]

        created_files = []

        async def mock_synthesize(text, output_path, formatting_segments=None):
            created_files.append(str(output_path))
            Path(output_path).parent.mkdir(parents=True, exist_ok=True)
            Path(output_path).write_bytes(b"audio")
            return True

        mock_engine = Mock()
        mock_engine.synthesize_segment = mock_synthesize

        output_path = Path(self.temp_dir) / "output.mp3"
        temp_dir = Path(self.temp_dir) / "retry"

        await self.retry_manager.retry_failed_segments(
            mock_engine, failed_segments, output_path, temp_dir
        )

        # Check that file was named with segment index and attempt number
        self.assertEqual(len(created_files), 1)
        filename = Path(created_files[0]).name
        self.assertIn("retry_5_1", filename)  # segment 5, attempt 1
        self.assertTrue(filename.endswith(".mp3"))

    async def test_empty_failed_segments_list(self):
        """Test retry with empty failed segments list"""
        mock_engine = Mock()
        output_path = Path(self.temp_dir) / "output.mp3"
        temp_dir = Path(self.temp_dir) / "retry"

        report = await self.retry_manager.retry_failed_segments(
            mock_engine, [], output_path, temp_dir
        )

        self.assertEqual(report.total_retried, 0)
        self.assertEqual(report.successful, 0)
        self.assertEqual(report.still_failed, 0)
        self.assertEqual(len(report.retry_details), 0)


class TestRetryReport(unittest.TestCase):
    """Test cases for RetryReport dataclass"""

    def test_creation(self):
        """Test RetryReport creation"""
        segment = SegmentRecord.create(0, "Test")
        segment.status = "failed"

        report = RetryReport(
            total_retried=3,
            successful=2,
            still_failed=1,
            failed_segments=[segment],
            retry_details=[
                {"segment_index": 0, "status": "success", "attempt": 1},
                {"segment_index": 1, "status": "success", "attempt": 2},
                {"segment_index": 2, "status": "failed", "attempts": 3},
            ],
        )

        self.assertEqual(report.total_retried, 3)
        self.assertEqual(report.successful, 2)
        self.assertEqual(report.still_failed, 1)
        self.assertEqual(len(report.failed_segments), 1)
        self.assertEqual(len(report.retry_details), 3)

    def test_all_successful(self):
        """Test RetryReport when all retries successful"""
        report = RetryReport(
            total_retried=5,
            successful=5,
            still_failed=0,
            failed_segments=[],
            retry_details=[{"segment_index": i, "status": "success"} for i in range(5)],
        )

        self.assertEqual(report.total_retried, 5)
        self.assertEqual(report.successful, 5)
        self.assertEqual(report.still_failed, 0)
        self.assertEqual(len(report.failed_segments), 0)

    def test_all_failed(self):
        """Test RetryReport when all retries failed"""
        failed_segs = [SegmentRecord.create(i, f"Text {i}") for i in range(3)]
        for seg in failed_segs:
            seg.status = "failed"

        report = RetryReport(
            total_retried=3,
            successful=0,
            still_failed=3,
            failed_segments=failed_segs,
            retry_details=[
                {"segment_index": i, "status": "failed", "attempts": 3} for i in range(3)
            ],
        )

        self.assertEqual(report.total_retried, 3)
        self.assertEqual(report.successful, 0)
        self.assertEqual(report.still_failed, 3)
        self.assertEqual(len(report.failed_segments), 3)


if __name__ == "__main__":
    unittest.main()
