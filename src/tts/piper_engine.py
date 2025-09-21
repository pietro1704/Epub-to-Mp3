# -*- coding: utf-8 -*-
"""Piper CLI wrapper used for offline synthesis."""

from __future__ import annotations

import asyncio
import contextlib
import os
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:  # pragma: no cover - optional dependency
    import numpy as np
    import soundfile as sf
except ImportError:  # pragma: no cover
    np = None  # type: ignore
    sf = None  # type: ignore

try:  # pragma: no cover - optional dependency
    from ..language import LanguageMarkup
except ImportError:  # pragma: no cover
    LanguageMarkup = None  # type: ignore

# **FIXED**: Semáforo global para limitar processos simultâneos do Piper
_piper_semaphore = None

def _get_piper_semaphore():
    global _piper_semaphore
    if _piper_semaphore is None:
        # Máximo 8 processos Piper simultâneos
        _piper_semaphore = asyncio.Semaphore(8)
    return _piper_semaphore


class PiperTTSEngine:
    """Invoke the Piper binary with the configured model."""

    def __init__(
        self,
        model_path: Path,
        *,
        primary_language: Optional[str] = None,
        language_voices: Optional[Dict[str, str]] = None,
    ) -> None:
        self.model_path = Path(model_path)
        if not self.model_path.exists():
            raise FileNotFoundError(f"Model not found: {self.model_path}")
        self.primary_language = (primary_language or "auto").split('-', 1)[0].lower()
        self.language_voices = language_voices or {}

    async def synthesize_async(self, text: str, output_path: Path, formatting_segments=None) -> Optional[Path]:
        if not text:
            return None

        # Note: formatting_segments currently ignored by Piper TTS
        # Could be used for voice modulation or post-processing in future versions

        contains_markup = LanguageMarkup is not None and "[[lang:" in text.lower()
        default_language = self.primary_language if self.primary_language not in {"", "auto", "unknown"} else "unknown"

        if not contains_markup:
            plain_text = text
        else:
            plain_text = LanguageMarkup.strip(text) if LanguageMarkup else text

        segments: List[Tuple[str, str]]
        if contains_markup and LanguageMarkup is not None:
            parsed = LanguageMarkup.parse(text, default_language)
            segments = [(segment.language, segment.text) for segment in parsed if segment.text]
        else:
            segments = [(default_language, plain_text)]

        if len(segments) == 1:
            return await self._synthesize_single(segments[0][1], output_path)

        if np is None or sf is None:
            combined_text = " ".join(segment for _, segment in segments)
            return await self._synthesize_single(combined_text, output_path)

        temp_files: List[Path] = []
        try:
            for idx, (_, segment_text) in enumerate(segments):
                segment_text = segment_text.strip()
                if not segment_text:
                    continue
                temp_path = Path(f"/tmp/piper_segment_{idx}_{hash(segment_text) % 10000}.wav")
                temp_files.append(temp_path)
                result = await self._synthesize_single(segment_text, temp_path)
                if result is None:
                    return None

            if not temp_files:
                return None

            audio_chunks: List[np.ndarray] = []
            sample_rate = None
            for file_path in temp_files:
                data, sr = sf.read(str(file_path))
                if sample_rate is None:
                    sample_rate = sr
                elif sr != sample_rate:
                    data = self._resample_audio(data, sr, sample_rate)
                audio_chunks.append(data)

            if not audio_chunks or sample_rate is None:
                return None

            combined = np.concatenate(audio_chunks, axis=0)
            sf.write(str(output_path), combined, sample_rate)
        finally:
            for temp_path in temp_files:
                with contextlib.suppress(OSError):
                    temp_path.unlink()

        return output_path if Path(output_path).exists() else None

    async def _synthesize_single(self, text: str, output_path: Path) -> Optional[Path]:
        command = (
            "piper",
            "--model",
            str(self.model_path),
            "--output_file",
            str(output_path),
        )

        # **FIXED**: Usar semáforo para limitar processos simultâneos
        semaphore = _get_piper_semaphore()
        async with semaphore:
            try:
                process = await asyncio.create_subprocess_exec(
                    *command,
                    stdin=asyncio.subprocess.PIPE,
                )
                await process.communicate(input=text.encode("utf-8"))
            except Exception:
                return None

            if process.returncode != 0:
                return None

        return output_path if Path(output_path).exists() else None

    @staticmethod
    def _resample_audio(data, current_sr: int, target_sr: int):  # pragma: no cover - depends on numpy availability
        if np is None or current_sr == target_sr:
            return data
        ratio = target_sr / current_sr
        indices = np.round(np.arange(0, len(data), 1 / ratio)).astype(int)
        indices = indices[indices < len(data)]
        return data[indices]


__all__ = ["PiperTTSEngine"]
