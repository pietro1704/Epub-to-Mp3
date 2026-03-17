"""
Automatic retry system for missing TTS segments.

This module provides automatic retry for segments that failed during TTS
conversion, attempting to re-synthesize them and insert them in the correct position.
"""

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Protocol

from python_app.src.synthesis_tracker import SegmentRecord

logger = logging.getLogger(__name__)


@dataclass
class RetryReport:
    """Retry attempt report."""

    total_retried: int
    successful: int
    still_failed: int
    failed_segments: List[SegmentRecord]
    retry_details: List[Dict[str, Any]]


class RetryableEngine(Protocol):
    """Protocol for engines that support segment retry."""

    async def synthesize_segment(
        self,
        text: str,
        output_path: Path,
        formatting_segments: List[tuple] = None,
    ) -> bool:
        """
        Synthesize a single text segment.

        Args:
            text: Text to synthesize
            output_path: Path to save the audio file
            formatting_segments: Formatting segments (optional)

        Returns:
            True on success, False otherwise
        """
        ...


class RetryManager:
    """Automatic retry manager for missing segments."""

    MAX_RETRIES = 3

    def __init__(self, max_retries: int = MAX_RETRIES):
        """
        Initialize the retry manager.

        Args:
            max_retries: Maximum number of retry attempts per segment
        """
        self.max_retries = max_retries
        self.retry_history: List[Dict[str, Any]] = []

    async def retry_failed_segments(
        self,
        engine: Any,  # TTSEngine with synthesize_segment support
        failed_segments: List[SegmentRecord],
        output_path: Path,
        temp_dir: Path,
    ) -> RetryReport:
        """
        Attempt to re-synthesize segments that failed.

        Args:
            engine: TTS engine to use for retry
            failed_segments: List of segments that failed
            output_path: Path to the final MP3 file
            temp_dir: Temporary directory for retry files

        Returns:
            RetryReport with retry results
        """
        temp_dir.mkdir(parents=True, exist_ok=True)
        retry_results = []
        still_failed_segments = []

        logger.info(
            f"Starting retry for {len(failed_segments)} failed segments "
            f"(max {self.max_retries} attempts each)"
        )

        for segment in failed_segments:
            success = False

            for attempt in range(1, self.max_retries + 1):
                logger.info(
                    f"Retry attempt {attempt}/{self.max_retries} for segment {segment.index}"
                )

                # Attempt to re-synthesize only this segment
                temp_path = temp_dir / f"retry_{segment.index}_{attempt}.mp3"

                try:
                    # Check if engine supports synthesize_segment
                    if hasattr(engine, "synthesize_segment"):
                        success = await engine.synthesize_segment(segment.text, temp_path)
                    elif hasattr(engine, "synthesize_async"):
                        # Fallback: use synthesize_async
                        result = await engine.synthesize_async(
                            segment.text,
                            temp_path,
                            formatting_segments=[],
                            progress_callback=None,
                            chunk_callback=None,
                        )
                        success = result is not None
                    else:
                        logger.error("Engine does not support segment synthesis")
                        success = False

                    if success and temp_path.exists():
                        logger.info(f"✓ Segment {segment.index} recovered on attempt {attempt}")

                        retry_results.append(
                            {
                                "segment_index": segment.index,
                                "status": "success",
                                "attempt": attempt,
                                "audio_path": str(temp_path),
                            }
                        )
                        break  # Success, move to next segment

                except Exception as e:
                    logger.warning(
                        f"Retry attempt {attempt} failed for segment {segment.index}: {e}"
                    )
                    success = False

            if not success:
                logger.error(
                    f"✗ Segment {segment.index} still failed after {self.max_retries} attempts"
                )
                still_failed_segments.append(segment)
                retry_results.append(
                    {
                        "segment_index": segment.index,
                        "status": "failed",
                        "attempts": self.max_retries,
                    }
                )

        # Statistics
        successful_retries = len([r for r in retry_results if r.get("status") == "success"])

        report = RetryReport(
            total_retried=len(failed_segments),
            successful=successful_retries,
            still_failed=len(still_failed_segments),
            failed_segments=still_failed_segments,
            retry_details=retry_results,
        )

        logger.info(
            f"Retry complete: {report.successful}/{report.total_retried} recovered, "
            f"{report.still_failed} still failed"
        )

        return report

    def _inject_audio_at_position(self, main_file: Path, segment_file: Path, position: int) -> bool:
        """
        Insert segment audio at the correct position in the main file.

        NOTE: This is a complex operation that requires:
        1. Reading the main file
        2. Splitting at the correct positions
        3. Inserting the new segment
        4. Concatenating everything

        For now, this function only documents the interface.
        The real implementation will be done when integrating with the engines.

        Args:
            main_file: Main MP3 file
            segment_file: Segment file to insert
            position: Position (index) where to insert

        Returns:
            True on success, False otherwise
        """
        logger.warning(
            "Audio injection not yet implemented. "
            "Segments will need to be reprocessed in full chapter conversion."
        )
        return False
