# -*- coding: utf-8 -*-
"""
Unit tests focused on the Edge TTS engine segmentation heuristics.
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.tts import edge_engine
from src.tts.edge_engine import SIMPLIFIED_SEGMENT_MAX_CHARS, EdgeTTSEngine


class TestEdgeTTSSegmentation(unittest.TestCase):
    """Validate that Edge segmentation preserves full chapter content."""

    def setUp(self) -> None:
        self._original_edge_tts = edge_engine.edge_tts
        edge_engine.edge_tts = Mock()
        self.engine = EdgeTTSEngine("test-voice")

    def tearDown(self) -> None:
        edge_engine.edge_tts = self._original_edge_tts

    def _normalise(self, text: str) -> str:
        return " ".join((text or "").split())

    def test_prepare_segments_preserves_text(self):
        """Segmented text should reconstruct the original payload."""
        base_text = " ".join(f"Sentence {i}." for i in range(2000))
        segments = self.engine._prepare_segments(base_text)

        reconstructed = " ".join(segment for _, segment in segments)

        self.assertEqual(
            self._normalise(reconstructed),
            self._normalise(base_text),
            "Segmentation must not drop characters from the payload",
        )

    def test_segments_respect_duration_cap(self):
        """Each segment must stay under the configured duration limit."""
        payload = " ".join(f"Sentence {i}." for i in range(1500))
        segments = self.engine._prepare_segments(payload)

        for _, segment in segments:
            estimated_seconds = self.engine._estimate_duration(segment)
            self.assertLessEqual(
                estimated_seconds,
                self.engine._max_segment_seconds + 1,
                "Segment exceeds the maximum expected duration",
            )

    def test_calculate_timeout_scales_with_text(self):
        """Timeouts should scale with estimated duration within safe bounds (otimizado)."""
        short_text = "Short sentence."
        long_text = " ".join(f"Sentence {i}." for i in range(4000))

        short_timeout = self.engine._calculate_timeout(short_text)
        long_timeout = self.engine._calculate_timeout(long_text)

        self.assertGreater(long_timeout, short_timeout, "Longer text should have a higher timeout")
        self.assertGreaterEqual(short_timeout, 45, "Short timeout should honour minimum (45s)")
        self.assertLessEqual(long_timeout, 300, "Timeout must stay under ceiling (300s)")

    def test_all_segments_processed(self):
        """CRITICAL: Verify that ALL segments are processed, not just the first one."""
        # Create text that will generate multiple segments
        long_text = " ".join(f"This is sentence number {i} with some content." for i in range(500))

        segments = self.engine._prepare_segments(long_text)

        # Should generate multiple segments for long text
        self.assertGreater(len(segments), 1, "Long text should generate multiple segments")

        # Reconstruct full text from segments
        reconstructed = " ".join(segment_text for _, segment_text in segments)

        # CRITICAL: All text must be preserved
        self.assertEqual(
            self._normalise(reconstructed),
            self._normalise(long_text),
            "CRITICAL BUG: Some segments are being lost! This causes audio truncation.",
        )

        # Verify each segment is non-empty
        for idx, (voice, segment_text) in enumerate(segments):
            self.assertTrue(
                segment_text.strip(), f"Segment {idx} is empty - segments should contain text"
            )

    def test_segment_loop_processes_all_segments(self):
        """Verify that the segment processing loop doesn't stop prematurely."""
        # Simulate a chapter with content that generates 3 segments
        text_part1 = " ".join(f"Part 1 sentence {i}." for i in range(100))
        text_part2 = " ".join(f"Part 2 sentence {i}." for i in range(100))
        text_part3 = " ".join(f"Part 3 sentence {i}." for i in range(100))
        full_text = f"{text_part1} {text_part2} {text_part3}"

        segments = self.engine._prepare_segments(full_text)

        # Count how many segments were created
        segment_count = len(segments)
        self.assertGreater(segment_count, 0, "Should have at least one segment")

        # Verify all parts are present in the segments
        reconstructed = " ".join(segment_text for _, segment_text in segments)

        self.assertIn("Part 1", reconstructed, "Part 1 missing from segments")
        self.assertIn("Part 2", reconstructed, "Part 2 missing from segments")
        self.assertIn("Part 3", reconstructed, "Part 3 missing from segments")

    def test_no_segments_lost_in_preparation(self):
        """Ensure _prepare_segments doesn't drop any text chunks."""
        # Text WITHOUT language tags to avoid cleanup interference
        complex_text = (
            """
        Chapter 1: Introduction

        This is the first paragraph with some content.
        This is the second paragraph with more content.

        Este é texto em português sem tags especiais.

        Back to English with numbers: 1, 2, 3, 4, 5.
        More content here to make it realistic and long enough.
        """
            * 20
        )  # Repeat to make it long enough for multiple segments

        segments = self.engine._prepare_segments(complex_text)

        # Verify we have segments
        self.assertGreater(len(segments), 0, "Should generate segments")

        # Reconstruct and compare
        reconstructed = " ".join(segment_text for _, segment_text in segments)

        # Normalize both for comparison (remove extra whitespace)
        normalized_original = self._normalise(complex_text)
        normalized_reconstructed = self._normalise(reconstructed)

        # Character count should match (allowing for whitespace normalization)
        original_chars = len(normalized_original.replace(" ", ""))
        reconstructed_chars = len(normalized_reconstructed.replace(" ", ""))

        # Allow small tolerance for cleanup (< 1%)
        tolerance = original_chars * 0.01
        char_diff = abs(reconstructed_chars - original_chars)

        self.assertLessEqual(
            char_diff,
            tolerance,
            f"Lost {char_diff} characters during segmentation (>{tolerance:.0f} tolerance)!",
        )

    def test_force_micro_segments_breaks_text(self):
        """Hard-failing segments should be force-split into smaller pieces."""
        stubborn_text = " ".join(f"Palavra {i}" for i in range(2000))
        tracker = set()

        micro_segments = self.engine._force_micro_segments("pt-BR-Voice", stubborn_text, tracker)

        self.assertIsNotNone(micro_segments, "Should create micro segments for long stubborn text")
        self.assertGreater(len(micro_segments), 1, "Micro splitting must produce multiple segments")

        for _, chunk in micro_segments:
            self.assertLess(
                len(chunk),
                len(stubborn_text),
                "Each micro chunk must be smaller than original text",
            )
            self.assertTrue(chunk.strip(), "Micro segments must contain text")

    def test_should_force_plain_text_detects_markup(self):
        noisy_text = " ".join("**palavra** _italic_ [[fmt:bold]]texto[[/fmt]]" for _ in range(100))
        self.assertTrue(
            self.engine._should_force_plain_text(noisy_text),
            "Heavy markup should trigger plain text mode",
        )

        clean_text = " ".join(f"Palavra {i}" for i in range(50))
        self.assertFalse(
            self.engine._should_force_plain_text(clean_text),
            "Simple paragraphs should not force plain mode",
        )

    def test_simplify_segment_text_can_skip_limit(self):
        text = " ".join(f"**Palavra {i}**" for i in range(1000))
        limited = self.engine._simplify_segment_text(text)
        self.assertLessEqual(len(limited), SIMPLIFIED_SEGMENT_MAX_CHARS)

        unlimited = self.engine._simplify_segment_text(text, limit_chars=None)
        self.assertGreater(
            len(unlimited),
            len(limited),
            "Unlimited simplification should retain more content than limited mode",
        )

    def test_parallel_batch_size_respects_slots(self):
        """Batch computation must follow the configured parallel slots."""
        self.engine._enable_parallel = True
        self.engine._parallel_slots = 4
        self.assertEqual(self.engine._determine_parallel_batch_size(10), 4)
        self.assertEqual(self.engine._determine_parallel_batch_size(2), 2)

    def test_parallel_batch_size_never_zero(self):
        """Even if slots are misconfigured or disabled, batch size must stay >= 1."""
        self.engine._enable_parallel = True
        self.engine._parallel_slots = 0
        self.assertEqual(self.engine._determine_parallel_batch_size(5), 1)

        self.engine._enable_parallel = False
        self.engine._parallel_slots = 4
        self.assertEqual(self.engine._determine_parallel_batch_size(5), 1)

    def test_identity_pool_includes_primary_voice(self):
        self.assertIn("test-voice", self.engine._voice_rotation_pool)

    def test_rotate_retry_voice_switches_after_rate_limit_window(self):
        self.engine._voice_rotation_pool = ["v1", "v2", "v3"]
        self.engine._identity_rotation_enabled = True
        self.engine._rate_limit_streak = 3
        rotated = self.engine._rotate_retry_voice("v1")
        self.assertIn(rotated, {"v2", "v3"})
        self.assertNotEqual(rotated, "v1")

    def test_parallel_streaming_retries_first_gap_before_emitting_later_chunks(self):
        """Streaming must not publish chunk N+1 before the first missing chunk N."""

        async def _run() -> None:
            self.engine._enable_parallel = True
            self.engine._parallel_slots = 2

            call_counts = {"segment-0": 0, "segment-1": 0}
            emitted_indices: list[int] = []

            async def fake_synthesize(text, voice, output_path, append=False):
                call_counts[text] += 1
                await asyncio.sleep(0.01 if text == "segment-0" else 0)
                if text == "segment-0" and call_counts[text] == 1:
                    return False
                Path(output_path).write_bytes(b"mp3")
                return True

            self.engine._synthesize_segment = fake_synthesize  # type: ignore[method-assign]

            with tempfile.TemporaryDirectory() as tmpdir:
                output_path = Path(tmpdir) / "chapter.mp3"
                result = await self.engine._synthesize_parallel(
                    output_path,
                    [("test-voice", "segment-0"), ("test-voice", "segment-1")],
                    force_plain_segments=False,
                    chunk_callback=lambda idx, *_args: emitted_indices.append(idx),
                )

            self.assertIsNotNone(result)
            self.assertEqual(emitted_indices, [0, 1])
            self.assertEqual(call_counts["segment-0"], 2)
            self.assertEqual(call_counts["segment-1"], 1)

        import asyncio

        asyncio.run(_run())


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
