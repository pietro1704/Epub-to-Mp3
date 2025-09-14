# -*- coding: utf-8 -*-
"""Utility helpers shared across the application and the tests."""

from __future__ import annotations

import asyncio
import re
from pathlib import Path
from typing import Optional


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
        safe_name = cls.sanitize_filename(chapter_name or f"Chapter {index}")
        safe_name = safe_name.replace(" ", "_")
        return f"{index:03d}_{safe_name}.mp3"

    @classmethod
    def get_output_path(cls, chapter_name: str, output_dir: Path, index: int) -> Path:
        return Path(output_dir) / cls.build_output_filename(chapter_name, index)


class AudioProcessor:
    """Async audio helpers implemented with ``ffmpeg``."""

    @staticmethod
    async def convert_to_mp3(input_file: Path, output_file: Path, bitrate: str = "32k") -> Optional[Path]:
        input_path = Path(input_file)
        output_path = Path(output_file)

        if not input_path.exists():
            return None

        output_path.parent.mkdir(parents=True, exist_ok=True)

        command = (
            "ffmpeg",
            "-y",
            "-i",
            str(input_path),
            "-b:a",
            bitrate,
            str(output_path),
        )

        try:
            process = await asyncio.create_subprocess_exec(
                *command,
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
        return file_path.exists() and file_path.is_file() and file_path.stat().st_size >= min_size_bytes


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


__all__ = ["FileManager", "AudioProcessor", "TextValidator"]
