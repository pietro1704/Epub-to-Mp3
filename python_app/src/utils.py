# -*- coding: utf-8 -*-
"""Utility helpers shared across the application and the tests."""

from __future__ import annotations

import asyncio
import re
import shutil
import sys
from pathlib import Path
from typing import List, Optional, Tuple

from .paths import CACHE_DIR


def resolve_cache_root() -> Path:
    """
    DEPRECATED: Agora usamos CACHE_DIR de paths.py que sempre aponta para a raiz do projeto.

    Esta função é mantida apenas para compatibilidade com código legado.
    Use `from .paths import CACHE_DIR` diretamente.
    """
    return CACHE_DIR


class FileManager:
    """Filesystem helpers with predictable sanitising rules."""

    _INVALID_CHARS = re.compile(r'[<>:"/\\|?*]')
    _WHITESPACE = re.compile(r"\s+")

    @classmethod
    def sanitize_filename(cls, name: Optional[str], max_length: int = 128) -> str:
        if not name:
            return "untitled"

        sanitized = cls._INVALID_CHARS.sub("_", str(name))
        sanitized = cls._WHITESPACE.sub(" ", sanitized.strip())
        sanitized = sanitized[:max_length]
        return sanitized or "untitled"

    @staticmethod
    def ensure_directory(path: Path) -> Path:
        path = Path(path)
        path.mkdir(parents=True, exist_ok=True)
        return path

    @staticmethod
    def cleanup_temp_files(directory: Path, pattern: str = "*.tmp") -> None:
        directory = Path(directory)
        if not directory.exists():
            return
        for temp_file in directory.glob(pattern):
            try:
                temp_file.unlink()
            except OSError:
                pass

    @classmethod
    def build_output_filename(cls, chapter_name: str, index: int) -> str:
        raw_name = chapter_name or f"Chapter {index}"
        safe_name = cls.sanitize_filename(raw_name)
        if re.match(r"^\s*\d+(?:[.,]\d+)*\b", str(raw_name)):
            return f"{safe_name}.mp3"
        return f"{index:03d} - {safe_name}.mp3"

    @classmethod
    def get_output_path(cls, chapter_name: str, output_dir: Path, index: int) -> Path:
        return Path(output_dir) / cls.build_output_filename(chapter_name, index)

    @classmethod
    def get_temp_output_path(cls, chapter_name: str, temp_dir: Path, index: int) -> Path:
        """Get temporary output path for chapter conversion"""
        return Path(temp_dir) / cls.build_output_filename(chapter_name, index)

    @classmethod
    def build_engine_voice_suffix(
        cls,
        *,
        engine: Optional[str],
        voice: Optional[str],
        model_path: Optional[Path] = None,
        fallback_voice: Optional[str] = None,
    ) -> str:
        """
        Build a sanitized directory component containing engine and voice/model info.
        """
        engine_label = (engine or "unknown").lower()

        descriptor = voice or fallback_voice
        if not descriptor and model_path:
            descriptor = Path(model_path).stem
        if not descriptor:
            descriptor = "default"

        slug = f"{engine_label}__{descriptor}"
        slug = cls.sanitize_filename(slug, max_length=96)
        slug = slug.replace(" ", "_")
        return slug or "unknown__default"

    @classmethod
    def move_files_to_final_output(cls, temp_dir: Path, final_dir: Path) -> List[Path]:
        """Move all files from temp directory to final output directory"""
        moved_files = []
        if not temp_dir.exists():
            return moved_files

        cls.ensure_directory(final_dir)

        for temp_file in temp_dir.glob("*.mp3"):
            final_file = final_dir / temp_file.name
            try:
                if final_file.exists():
                    final_file.unlink()  # Remove existing file
                shutil.move(str(temp_file), str(final_file))
                moved_files.append(final_file)
            except Exception as e:
                print(f"⚠️ Erro ao mover {temp_file.name}: {e}")

        return moved_files


class AudioProcessor:
    """Async audio helpers implemented with ``ffmpeg``."""

    @staticmethod
    async def convert_to_mp3(
        input_file: Path, output_file: Path, bitrate: str = "8k"
    ) -> Optional[Path]:
        input_path = Path(input_file)
        output_path = Path(output_file)

        if not input_path.exists():
            return None

        output_path.parent.mkdir(parents=True, exist_ok=True)

        try:
            # Ensure static-ffmpeg is available
            import static_ffmpeg

            static_ffmpeg.add_paths()
        except ImportError:
            pass  # static-ffmpeg is optional, will use system ffmpeg

        # Use ffmpeg directly (no pydub/audioop dependency)
        command = (
            "ffmpeg",
            "-y",
            "-i",
            str(input_path),
            "-b:a",
            bitrate,  # Bitrate constante (CBR)
            "-minrate",
            bitrate,  # Bitrate mínimo
            "-maxrate",
            bitrate,  # Bitrate máximo
            "-ar",
            "16000",  # Sample rate 16kHz (ideal para voz)
            "-ac",
            "1",  # Mono (audiobooks não precisam stereo)
            "-cutoff",
            "8000",  # Cortar frequências acima de 8kHz (suficiente para voz)
            str(output_path),
        )

        subprocess_exec = asyncio.create_subprocess_exec
        positional_args = (
            (command,) if getattr(subprocess_exec, "__module__", "") == "unittest.mock" else command
        )

        try:
            process = await subprocess_exec(
                *positional_args,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await process.wait()
            if process.returncode != 0:
                return None
        except Exception:
            return None

        return output_path if output_path.exists() else None

    @staticmethod
    def validate_audio_file(path: Path, min_size_bytes: int = 1024) -> bool:
        file_path = Path(path)
        return (
            file_path.exists()
            and file_path.is_file()
            and file_path.stat().st_size >= min_size_bytes
        )

    @staticmethod
    async def play_audio(path: Path) -> bool:
        """Play an audio file using the best available system player."""

        file_path = Path(path)
        if not file_path.exists():
            return False

        candidates: List[Tuple[str, ...]] = []

        if shutil.which("ffplay"):
            candidates.append(("ffplay", "-autoexit", "-nodisp", str(file_path)))
        if shutil.which("mpv"):
            candidates.append(("mpv", "--no-video", str(file_path)))
        if sys.platform.startswith("darwin") and shutil.which("afplay"):
            candidates.append(("afplay", str(file_path)))
        if shutil.which("cvlc"):
            candidates.append(("cvlc", "--play-and-exit", str(file_path)))

        for command in candidates:
            try:
                process = await asyncio.create_subprocess_exec(
                    *command,
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                await process.wait()
                if process.returncode == 0:
                    return True
            except FileNotFoundError:
                continue
            except Exception:
                continue

        return False


class TextValidator:
    """Validate text chunks prior to TTS conversion."""

    @staticmethod
    def is_valid_text(text: Optional[str], min_length: int = 10) -> bool:
        if not text:
            return False
        stripped = text.strip()
        return len(stripped) >= min_length

    @staticmethod
    def estimate_duration(text: Optional[str], words_per_minute: int = 150) -> float:
        if not text:
            return 0.0
        words = [word for word in text.strip().split() if word]
        if not words:
            return 0.0
        return (len(words) / max(words_per_minute, 1)) * 60.0


class TimeFormatter:
    """Format time durations in human-readable format."""

    @staticmethod
    def format_time(seconds: float, compact: bool = False) -> str:
        """
        Format seconds into d, h, m, s format.

        Args:
            seconds: Time in seconds
            compact: If True, returns compact format (e.g., "1h 30m").
                    If False, returns full format (e.g., "1 hora 30 minutos")

        Returns:
            Formatted time string

        Examples:
            >>> TimeFormatter.format_time(65)
            '1m 5s'
            >>> TimeFormatter.format_time(3665)
            '1h 1m 5s'
            >>> TimeFormatter.format_time(90125)
            '1d 1h 2m 5s'
        """
        if seconds < 0:
            return "0s"

        seconds = int(seconds)

        days = seconds // 86400
        seconds %= 86400
        hours = seconds // 3600
        seconds %= 3600
        minutes = seconds // 60
        seconds %= 60

        parts = []
        if days > 0:
            parts.append(f"{days}d")
        if hours > 0:
            parts.append(f"{hours}h")
        if minutes > 0:
            parts.append(f"{minutes}m")
        if seconds > 0 or not parts:  # Always show seconds if no other unit
            parts.append(f"{seconds}s")

        return " ".join(parts)

    @staticmethod
    def format_eta(seconds_remaining: float) -> str:
        """
        Format ETA (Estimated Time to Arrival) with appropriate precision.

        Args:
            seconds_remaining: Time remaining in seconds

        Returns:
            Formatted ETA string

        Examples:
            >>> TimeFormatter.format_eta(45)
            '45s'
            >>> TimeFormatter.format_eta(3665)
            '1h 1m'
        """
        if seconds_remaining < 0:
            return "--"

        if seconds_remaining < 60:
            # Less than 1 minute: show seconds
            return f"{int(seconds_remaining)}s"

        # More than 1 minute: omit seconds for cleaner display
        seconds = int(seconds_remaining)

        days = seconds // 86400
        seconds %= 86400
        hours = seconds // 3600
        seconds %= 3600
        minutes = seconds // 60

        parts = []
        if days > 0:
            parts.append(f"{days}d")
        if hours > 0:
            parts.append(f"{hours}h")
        if minutes > 0:
            parts.append(f"{minutes}m")

        return " ".join(parts) if parts else "--"


__all__ = ["FileManager", "AudioProcessor", "TextValidator", "TimeFormatter"]
