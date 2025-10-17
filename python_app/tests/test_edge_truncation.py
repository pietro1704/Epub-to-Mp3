# -*- coding: utf-8 -*-
"""
Critical test: Detect audio truncation at ~1 minute mark
"""

import unittest
import tempfile
import asyncio
from pathlib import Path
from unittest.mock import Mock

import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.tts import edge_engine
from src.tts.edge_engine import EdgeTTSEngine


class TestEdgeTruncationBug(unittest.IsolatedAsyncioTestCase):
    """Test suite specifically for the 1-minute audio truncation bug"""

    def setUp(self) -> None:
        self._original_edge_tts = edge_engine.edge_tts
        edge_engine.edge_tts = Mock()
        self.temp_dir = tempfile.mkdtemp()
        self.engine = EdgeTTSEngine("pt-BR-FranciscaNeural", verbose=True)

    def tearDown(self) -> None:
        edge_engine.edge_tts = self._original_edge_tts
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    async def test_realistic_chapter_length_5_minutes(self):
        """Simulate a realistic 5-minute chapter (average speaking rate)"""
        # Average speaking: 150 words/min = 750 words for 5 min
        # Average word length: 5 chars + 1 space = 6 chars/word
        # Total: 750 * 6 = ~4500 chars
        realistic_text = " ".join(
            f"Esta é a frase número {i} com conteúdo realista que faz sentido."
            for i in range(750)
        )

        output_path = Path(self.temp_dir) / "test_5min.mp3"

        # Mock the actual synthesis to avoid calling Microsoft API
        async def mock_synthesize_segment(text, voice, path, append):
            # Just create a fake file
            path = Path(path)
            if append and path.exists():
                with path.open("ab") as f:
                    f.write(b"audio" * 100)
            else:
                with path.open("wb") as f:
                    f.write(b"audio" * 100)
            return True

        self.engine._synthesize_segment = mock_synthesize_segment

        # Synthesize
        result = await self.engine.synthesize_async(realistic_text, output_path)

        # Verify result
        self.assertIsNotNone(result, "Synthesis should succeed for 5-min chapter")
        self.assertTrue(output_path.exists(), "Output file should exist")

        # Verify ALL segments were processed
        # Calculate expected segments (Edge TTS limits to ~55s per segment)
        # 4500 chars / ~700 chars per segment = ~6-7 segments
        expected_min_segments = 5
        # The engine should have processed at least this many segments

        # Check the file size as a proxy for segment count
        # Each segment writes 100*5 = 500 bytes, so we expect at least 5*500 = 2500 bytes
        file_size = output_path.stat().st_size
        expected_min_size = expected_min_segments * 500
        self.assertGreaterEqual(
            file_size,
            expected_min_size,
            f"File too small ({file_size} bytes)! Expected at least {expected_min_size} bytes. "
            f"This suggests segments were not all processed (truncation bug)."
        )

    async def test_all_segments_processed_not_just_first(self):
        """CRITICAL: Verify that ALL segments are processed, not just the first 1 minute"""
        # Create text that will generate exactly 5 segments
        # Each segment: ~1000 chars (roughly 40 seconds of speech)
        parts = []
        for i in range(5):
            part = f"PARTE {i} início. " + " ".join(
                f"Frase {j} da parte {i}." for j in range(80)
            ) + f" PARTE {i} fim."
            parts.append(part)

        full_text = " ".join(parts)
        output_path = Path(self.temp_dir) / "test_all_segments.mp3"

        # Track which segments were actually processed
        processed_segments = []

        async def tracking_synthesize_segment(text, voice, path, append):
            # Record segment index based on content
            for i in range(5):
                if f"PARTE {i} início" in text:
                    processed_segments.append(i)
                    break

            # Simulate synthesis
            path = Path(path)
            if append and path.exists():
                with path.open("ab") as f:
                    f.write(b"audio" * 100)
            else:
                with path.open("wb") as f:
                    f.write(b"audio" * 100)
            return True

        self.engine._synthesize_segment = tracking_synthesize_segment

        # Synthesize
        result = await self.engine.synthesize_async(full_text, output_path)

        # CRITICAL ASSERTION: All 5 parts must be processed
        self.assertEqual(
            len(processed_segments),
            5,
            f"Only {len(processed_segments)}/5 parts processed! "
            f"Processed: {processed_segments}. This is the TRUNCATION BUG!"
        )

        # Verify they were processed in order
        self.assertEqual(
            processed_segments,
            [0, 1, 2, 3, 4],
            f"Segments processed out of order or skipped: {processed_segments}"
        )

    async def test_segment_failure_does_not_abort_all_remaining(self):
        """Verify that if segment 2 fails, segments 3, 4, 5 are still processed"""
        parts = [f"Segmento {i}. " * 100 for i in range(5)]
        full_text = " ".join(parts)
        output_path = Path(self.temp_dir) / "test_resilience.mp3"

        # Track segments
        processed = []
        call_count = [0]

        async def failing_segment_2(text, voice, path, append):
            call_count[0] += 1

            # Identify segment
            for i in range(5):
                if f"Segmento {i}" in text:
                    # Fail on segment 1 (0-indexed) to simulate a mid-chapter failure
                    if i == 1:
                        return False  # Fail!

                    processed.append(i)
                    break

            # Simulate synthesis
            path = Path(path)
            if append and path.exists():
                with path.open("ab") as f:
                    f.write(b"audio" * 100)
            else:
                with path.open("wb") as f:
                    f.write(b"audio" * 100)
            return True

        self.engine._synthesize_segment = failing_segment_2

        # Synthesize
        result = await self.engine.synthesize_async(full_text, output_path)

        # Should still succeed (with retry logic)
        self.assertIsNotNone(result, "Should succeed even with one segment failure")

        # Segments 0, 2, 3, 4 should be processed (segment 1 failed)
        # With retry, segment 1 will be called twice (original + 1 retry)
        expected_processed = [0, 2, 3, 4]
        self.assertEqual(
            sorted(processed),
            expected_processed,
            f"Expected {expected_processed} but got {processed}. "
            f"Segment 1 should fail, but others should continue!"
        )


if __name__ == "__main__":
    unittest.main()
