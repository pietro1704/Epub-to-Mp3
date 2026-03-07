"""
Audio validator for checking integrity and duration of MP3 files.

Validates TTS-generated audio files by comparing expected vs actual duration
and detecting file corruption.
"""

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass
class ValidationResult:
    """Audio validation result."""

    is_valid: bool
    expected_duration: float
    actual_duration: float
    duration_diff_percent: float
    error_message: Optional[str] = None


class AudioValidator:
    """Validator for TTS-generated MP3 audio files."""

    DEFAULT_WORDS_PER_MINUTE = 150  # Average speaking speed

    def __init__(self, words_per_minute: int = DEFAULT_WORDS_PER_MINUTE):
        """
        Initialize the validator.

        Args:
            words_per_minute: Expected speaking speed for duration estimation
        """
        self.words_per_minute = words_per_minute

    def estimate_duration(self, text: str) -> float:
        """
        Estimate expected duration of text in seconds.

        Args:
            text: Text to estimate duration for

        Returns:
            Estimated duration in seconds
        """
        words = re.findall(r"\b\w+\b", text)
        word_count = len(words)

        if word_count == 0:
            return 0.0

        duration_seconds = (word_count / self.words_per_minute) * 60
        return duration_seconds

    def get_audio_duration(self, audio_path: Path) -> Optional[float]:
        """
        Get the actual duration of an audio file.

        Args:
            audio_path: Path to the audio file

        Returns:
            Duration in seconds, or None if it cannot be determined
        """
        if not audio_path.exists():
            return None

        try:
            try:
                from mutagen.mp3 import MP3

                audio = MP3(str(audio_path))
                return audio.info.length
            except ImportError:
                pass

            try:
                from pydub import AudioSegment

                audio = AudioSegment.from_mp3(str(audio_path))
                return len(audio) / 1000.0  # pydub returns milliseconds
            except ImportError:
                pass

            try:
                import soundfile as sf

                info = sf.info(str(audio_path))
                return info.duration
            except ImportError:
                pass

            return None

        except Exception:
            return None

    def validate_audio_file(self, audio_path: Path) -> bool:
        """
        Check whether an audio file exists and is not corrupted.

        Args:
            audio_path: Path to the audio file

        Returns:
            True if the file is valid, False otherwise
        """
        if not audio_path.exists():
            return False

        # Minimum size check (1 KB)
        if audio_path.stat().st_size < 1024:
            return False

        # If duration cannot be determined, the file may be corrupted
        duration = self.get_audio_duration(audio_path)
        if duration is None or duration <= 0:
            return False

        return True

    def validate_duration(
        self, text: str, audio_path: Path, tolerance: float = 0.15
    ) -> ValidationResult:
        """
        Validate whether audio duration matches the expected text duration.

        Args:
            text: Source text
            audio_path: Path to generated audio file
            tolerance: Allowed duration difference (default: 15%)

        Returns:
            ValidationResult with validation details
        """
        expected_duration = self.estimate_duration(text)
        actual_duration = self.get_audio_duration(audio_path)

        if actual_duration is None:
            return ValidationResult(
                is_valid=False,
                expected_duration=expected_duration,
                actual_duration=0.0,
                duration_diff_percent=0.0,
                error_message=f"Could not determine audio duration for {audio_path.name}",
            )

        if expected_duration > 0:
            duration_diff_percent = (
                (actual_duration - expected_duration) / expected_duration
            ) * 100
        else:
            duration_diff_percent = 0.0

        is_valid = abs(duration_diff_percent) <= (tolerance * 100)

        error_message = None
        if not is_valid:
            error_message = (
                f"Duration mismatch: expected {expected_duration:.1f}s, "
                f"got {actual_duration:.1f}s ({duration_diff_percent:+.1f}% diff)"
            )

        return ValidationResult(
            is_valid=is_valid,
            expected_duration=expected_duration,
            actual_duration=actual_duration,
            duration_diff_percent=duration_diff_percent,
            error_message=error_message,
        )

    def validate_chapter(self, chapter_text: str, audio_path: Path) -> ValidationResult:
        """
        Validate a complete chapter's audio file.

        Args:
            chapter_text: Chapter text
            audio_path: Path to the chapter's audio file

        Returns:
            ValidationResult with validation details
        """
        if not self.validate_audio_file(audio_path):
            expected_duration = self.estimate_duration(chapter_text)
            return ValidationResult(
                is_valid=False,
                expected_duration=expected_duration,
                actual_duration=0.0,
                duration_diff_percent=0.0,
                error_message=f"Audio file is corrupted or missing: {audio_path.name}",
            )

        # Validar duração
        return self.validate_duration(chapter_text, audio_path)
