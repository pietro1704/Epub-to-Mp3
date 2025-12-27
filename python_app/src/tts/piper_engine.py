# -*- coding: utf-8 -*-
"""Piper CLI wrapper used for offline synthesis."""

from __future__ import annotations

import asyncio
import contextlib
import os
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Optional dependencies resolved lazily to avoid crashes in restricted environments.
np = None  # type: ignore
sf = None  # type: ignore

try:  # pragma: no cover - optional dependency
    import numpy as _np  # type: ignore
    import soundfile as _sf  # type: ignore

    np = _np  # type: ignore
    sf = _sf  # type: ignore
except Exception:  # pragma: no cover
    pass

try:  # pragma: no cover - optional dependency
    from ..language import LanguageMarkup
except ImportError:  # pragma: no cover
    LanguageMarkup = None  # type: ignore

try:  # pragma: no cover - optional dependency
    from ..text_formatting import TextFormattingProcessor
except ImportError:  # pragma: no cover
    TextFormattingProcessor = None  # type: ignore

# **FIXED**: Semáforo global para limitar processos simultâneos do Piper
_piper_semaphore = None


def _get_piper_semaphore():
    global _piper_semaphore
    if _piper_semaphore is None:
        try:
            max_procs = int(os.environ.get("PIPER_MAX_PROCS", "").strip() or "0")
        except ValueError:
            max_procs = 0
        if max_procs <= 0:
            cpu_count = os.cpu_count() or 1
            max_procs = max(1, min(3, cpu_count))
        _piper_semaphore = asyncio.Semaphore(max_procs)
    return _piper_semaphore


class PiperTTSEngine:
    """Invoke the Piper binary with the configured model."""

    def __init__(
        self,
        model_path: Path,
        *,
        primary_language: Optional[str] = None,
        language_voices: Optional[Dict[str, str]] = None,
        formatting_cues_enabled: bool = True,
        formatting_locale: str = "pt",
        max_procs: Optional[int] = None,
    ) -> None:
        self.model_path = Path(model_path)
        if not self.model_path.exists():
            raise FileNotFoundError(f"Model not found: {self.model_path}")
        self.primary_language = (primary_language or "auto").split("-", 1)[0].lower()
        raw_language_voices = language_voices or {}
        self.language_voices = {
            (key or "").split("-", 1)[0].lower(): value
            for key, value in raw_language_voices.items()
            if value
        }
        self.language_models: Dict[str, Path] = {}
        for code, value in self.language_voices.items():
            try:
                candidate = Path(str(value))
            except Exception:
                continue
            if candidate.exists() and candidate.is_file():
                self.language_models[code] = candidate
        self.verbose = False
        locale_root = (formatting_locale or "pt").split("-", 1)[0].lower()
        if locale_root not in {"pt", "en"}:
            locale_root = "en"
        self.formatting_locale = locale_root
        self.formatting_cues_enabled = bool(formatting_cues_enabled)
        self._semaphore = self._resolve_semaphore(max_procs)

    @staticmethod
    def _resolve_semaphore(max_procs: Optional[int]) -> asyncio.Semaphore:
        if max_procs is None:
            return _get_piper_semaphore()
        try:
            parsed = int(max_procs)
        except (TypeError, ValueError):
            return _get_piper_semaphore()
        if parsed <= 0:
            return _get_piper_semaphore()
        return asyncio.Semaphore(parsed)

    def supports_multilingual(self) -> bool:
        """Piper supports multilingual via language-specific models"""
        # Piper uses separate models per language, so multilingual requires switching models
        return bool(self.language_voices)

    def supports_emphasis(self) -> bool:
        """Piper supports basic emphasis via pause markers"""
        return True

    async def synthesize_async(
        self, text: str, output_path: Path, formatting_segments=None
    ) -> Optional[Path]:
        if not text:
            return None

        if TextFormattingProcessor:
            formatter = TextFormattingProcessor(
                cues_enabled=getattr(self, "formatting_cues_enabled", True),
                cue_locale=getattr(self, "formatting_locale", "pt"),
            )
            try:
                converted = formatter.to_audible_text(text, formatting_segments)
                if converted:
                    if self.verbose and converted != text:
                        print(
                            f"🔍 [VERBOSE] PiperTTS texto ajustado para áudio: {len(converted)} chars"
                        )
                    text = converted
            except Exception as exc:
                if self.verbose:
                    print(
                        f"🔍 [VERBOSE] PiperTTS falha ao preparar texto com formatação ({exc}); prosseguindo com limpeza básica"
                    )
                text = formatter.clean_tts_text(text)
        else:
            text = text.strip()

        contains_markup = LanguageMarkup is not None and "[[lang:" in text.lower()
        default_language = (
            self.primary_language
            if self.primary_language not in {"", "auto", "unknown"}
            else "unknown"
        )

        if not contains_markup:
            plain_text = (
                TextFormattingProcessor.clean_tts_text(text) if TextFormattingProcessor else text
            )
        else:
            plain_text = LanguageMarkup.strip(text) if LanguageMarkup else text

        segments: List[Tuple[str, str]]
        if contains_markup and LanguageMarkup is not None:
            parsed = LanguageMarkup.parse(text, default_language)
            segments = []
            for segment in parsed:
                if not segment or not segment.text:
                    continue
                segment_text = (
                    TextFormattingProcessor.clean_tts_text(segment.text)
                    if TextFormattingProcessor
                    else segment.text
                )
                segments.append((segment.language, segment_text))
        else:
            segments = [(default_language, plain_text)]

        if len(segments) == 1:
            lang, segment_text = segments[0]
            model = self._resolve_model_for_language(lang)
            return await self._synthesize_single(segment_text, output_path, model)

        if np is None or sf is None:
            combined_text = " ".join(segment for _, segment in segments)
            model = self._resolve_model_for_language(default_language)
            return await self._synthesize_single(combined_text, output_path, model)

        temp_files: List[Path] = []
        try:
            for idx, (language, segment_text) in enumerate(segments):
                segment_text = segment_text.strip()
                if not segment_text:
                    continue
                # **FIX**: Use output_path.parent para isolar por livro
                import tempfile

                temp_file = tempfile.NamedTemporaryFile(
                    delete=False, suffix=".wav", dir=output_path.parent, prefix=f"piper_seg{idx}_"
                )
                temp_file.close()
                temp_path = Path(temp_file.name)
                temp_files.append(temp_path)
                model = self._resolve_model_for_language(language)
                result = await self._synthesize_single(segment_text, temp_path, model)
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

    def _resolve_model_for_language(self, language: Optional[str]) -> Path:
        code = (language or "").split("-", 1)[0].lower()
        return self.language_models.get(code) or self.model_path

    async def _synthesize_single(
        self, text: str, output_path: Path, model_path: Path
    ) -> Optional[Path]:
        command = (
            "piper",
            "--model",
            str(model_path),
            "--output_file",
            str(output_path),
        )

        # **FIXED**: Usar semáforo para limitar processos simultâneos
        async with self._semaphore:
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
    def _resample_audio(
        data, current_sr: int, target_sr: int
    ):  # pragma: no cover - depends on numpy availability
        if np is None or current_sr == target_sr:
            return data
        ratio = target_sr / current_sr
        indices = np.round(np.arange(0, len(data), 1 / ratio)).astype(int)
        indices = indices[indices < len(data)]
        return data[indices]


__all__ = ["PiperTTSEngine"]
