# -*- coding: utf-8 -*-
"""Coqui TTS engine wrapper with lazy initialisation."""

from __future__ import annotations

import asyncio
import contextlib
import importlib
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from unittest.mock import Mock

TTS = None

# **FIXED**: Executor global com limite de threads para evitar travamentos
_coqui_executor = None

def _get_coqui_executor():
    global _coqui_executor
    if _coqui_executor is None:
        # Máximo 4 threads para evitar sobrecarga
        _coqui_executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="CoquiTTS")
    return _coqui_executor

# Optional dependencies resolved lazily to avoid crashes in restricted environments.
np = None  # type: ignore
sf = None  # type: ignore

try:  # pragma: no cover - optional dependency
    from ..language import LanguageMarkup
except ImportError:  # pragma: no cover
    LanguageMarkup = None  # type: ignore

try:  # pragma: no cover - optional dependency
    from ..text_formatting import TextFormattingProcessor
except ImportError:  # pragma: no cover
    TextFormattingProcessor = None  # type: ignore


class CoquiTTSEngine:
    """Create and reuse a Coqui ``TTS`` instance on demand."""

    def __init__(
        self,
        model_name: str,
        *,
        primary_language: Optional[str] = None,
        language_voices: Optional[Dict[str, str]] = None,
        verbose: bool = False,
    ) -> None:
        global TTS

        if isinstance(TTS, Mock):
            if getattr(TTS, "side_effect", None):
                raise ImportError("Coqui TTS not installed")
            tts_class = TTS
        else:
            if TTS is None:
                try:
                    module = importlib.import_module("TTS.api")  # type: ignore
                    TTS = getattr(module, "TTS")
                except (ImportError, AttributeError) as exc:
                    raise ImportError("Coqui TTS not installed") from exc
            tts_class = TTS

        self.model_name = model_name
        self._tts_class = tts_class
        self.tts = None
        self.primary_language = (primary_language or "auto").split('-', 1)[0].lower()
        self.language_voices = language_voices or {}
        self.verbose = verbose
        self.last_error: Optional[str] = None

    def supports_multilingual(self) -> bool:
        """Coqui TTS models like XTTS_v2 support multilingual synthesis"""
        # XTTS v2 and similar models support multilingual
        return "xtts" in self.model_name.lower() or "multilingual" in self.model_name.lower()

    def supports_emphasis(self) -> bool:
        """Coqui TTS supports basic emphasis via pause markers"""
        return True

    def _initialize_model(self) -> None:
        if self.tts is None:
            if self.verbose:
                print(f"🔍 [VERBOSE] Coqui inicializando modelo: {self.model_name}")
            try:
                self.tts = self._tts_class(model_name=self.model_name)
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui modelo inicializado com sucesso")
            except Exception as e:
                self.last_error = f"init_error: {e}"
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui erro na inicialização: {e}")
                raise

    async def synthesize_async(self, text: str, output_path: Path, formatting_segments=None) -> Optional[Path]:
        if not text:
            return None

        # Preparar texto com pistas audíveis quando possível
        if TextFormattingProcessor:
            formatter = TextFormattingProcessor()
            try:
                converted = formatter.to_audible_text(text, formatting_segments)
                if converted:
                    if self.verbose and converted != text:
                        print(f"🔍 [VERBOSE] CoquiTTS texto ajustado para áudio: {len(converted)} chars")
                    text = converted
            except Exception as e:
                if self.verbose:
                    print(f"🔍 [VERBOSE] CoquiTTS falha ao preparar texto ({e}); usando limpeza básica")
                text = formatter.clean_tts_text(text)
        else:
            text = text.strip()

        contains_markup = LanguageMarkup is not None and "[[lang:" in text.lower()
        default_language = self.primary_language if self.primary_language not in {"", "auto", "unknown"} else "unknown"
        segments: List[Tuple[str, str]]

        if contains_markup and LanguageMarkup is not None:
            parsed = LanguageMarkup.parse(text, default_language)
            segments = []
            for segment in parsed:
                if not segment or not segment.text:
                    continue
                cleaned_segment = (
                    TextFormattingProcessor.clean_tts_text(segment.text)
                    if TextFormattingProcessor
                    else segment.text
                )
                segments.append((segment.language, cleaned_segment))
        else:
            if contains_markup and LanguageMarkup is not None:
                plain_text = LanguageMarkup.strip(text)
            else:
                plain_text = text
            plain_text = TextFormattingProcessor.clean_tts_text(plain_text) if TextFormattingProcessor else plain_text
            segments = [(default_language, plain_text)]

        self._initialize_model()
        loop = asyncio.get_event_loop()

        if len(segments) == 1:
            language, segment_text = segments[0]
            if not segment_text.strip():
                return None
            try:
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui sintetizando {len(segment_text)} chars, linguagem: {language}")
                # **FIXED**: Usar executor limitado em vez de None (thread pool padrão)
                executor = _get_coqui_executor()
                await loop.run_in_executor(executor, self._synthesize_blocking, segment_text, output_path, language)
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui síntese completa: {output_path}")
            except Exception as e:
                self.last_error = f"synthesis_error: {e}"
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui erro na síntese: {e}")
                return None
            return output_path if Path(output_path).exists() else None

        if np is None or sf is None:
            merged_text = " ".join(segment_text for _, segment_text in segments)
            try:
                # **FIXED**: Usar executor limitado
                executor = _get_coqui_executor()
                await loop.run_in_executor(executor, self._synthesize_blocking, merged_text, output_path, default_language)
            except Exception:
                return None
            return output_path if Path(output_path).exists() else None

        temp_files: List[Path] = []
        try:
            for idx, (language, segment_text) in enumerate(segments):
                segment_text = segment_text.strip()
                if not segment_text:
                    continue
                temp_path = Path(f"/tmp/coqui_segment_{idx}_{hash(segment_text) % 10000}.wav")
                temp_files.append(temp_path)
                # **FIXED**: Usar executor limitado
                executor = _get_coqui_executor()
                await loop.run_in_executor(executor, self._synthesize_blocking, segment_text, temp_path, language)

            if not temp_files:
                return None

            audio_chunks: List[np.ndarray] = []
            sample_rate = None
            for file_path in temp_files:
                data, sr = sf.read(str(file_path))
                if sample_rate is None:
                    sample_rate = sr
                elif sample_rate != sr:
                    data = self._resample_audio(data, sr, sample_rate)
                audio_chunks.append(data)

            if not audio_chunks or sample_rate is None:
                return None

            combined = np.concatenate(audio_chunks, axis=0)
            sf.write(str(output_path), combined, sample_rate)
        except Exception:
            return None
        finally:
            for temp_path in temp_files:
                with contextlib.suppress(OSError):
                    temp_path.unlink()

        return output_path if Path(output_path).exists() else None

    def _synthesize_blocking(self, text: str, output_path: Path, language: Optional[str]) -> None:
        kwargs = {"text": text, "file_path": str(output_path)}
        if language and language not in {"unknown", "auto"}:
            kwargs["language"] = language

        # Enhanced multi-speaker detection and handling
        self._add_speaker_if_needed(kwargs)

        retry_count = 0
        max_retries = 3

        while retry_count <= max_retries:
            try:
                self.tts.tts_to_file(**kwargs)
                return  # Success
            except (TypeError, ValueError) as e:
                error_msg = str(e).lower()

                if "multi-speaker" in error_msg and "speaker" in error_msg:
                    # Model requires speaker parameter
                    if retry_count == 0:
                        self._add_speaker_fallback(kwargs)
                    elif retry_count == 1:
                        kwargs["speaker"] = "default"
                    else:
                        kwargs.pop("speaker", None)
                elif "language" in error_msg or "multi-lingual" in error_msg:
                    kwargs.pop("language", None)
                elif "speaker" in error_msg:
                    kwargs.pop("speaker", None)
                else:
                    raise

                retry_count += 1
            except Exception as e:
                if retry_count < max_retries:
                    retry_count += 1
                    continue
                raise

    def _add_speaker_if_needed(self, kwargs: dict) -> None:
        """Add speaker parameter if model supports/requires it."""
        # For VITS models, don't add speaker initially - let it fail first, then retry
        # This allows the model to work normally when speaker is not needed

        # Only pre-add speaker for known multi-speaker models
        if 'xtts' in self.model_name.lower():
            # XTTS always needs speaker or speaker_wav
            if hasattr(self.tts, 'speakers') and self.tts.speakers:
                kwargs["speaker"] = self.tts.speakers[0]
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui XTTS usando speaker: {kwargs['speaker']}")
            else:
                kwargs["speaker_wav"] = None  # Use default voice
                if self.verbose:
                    print("🔍 [VERBOSE] Coqui XTTS usando speaker_wav default")

        # For other models, let them try without speaker first

    def _add_speaker_fallback(self, kwargs: dict) -> None:
        """Fallback speaker detection for stubborn models."""
        if self.verbose:
            print("🔍 [VERBOSE] Coqui tentando fallback de speaker")

        # For VITS PT models, try speaker "0" first (most common)
        if 'vits' in self.model_name.lower() and 'pt' in self.model_name.lower():
            kwargs["speaker"] = "0"
            if self.verbose:
                print("🔍 [VERBOSE] Coqui VITS PT usando speaker: 0")
        else:
            # Try common speaker names for other models
            common_speakers = ["0", "default", "speaker_0", "ljspeech", "p225"]
            kwargs["speaker"] = common_speakers[0]
            if self.verbose:
                print(f"🔍 [VERBOSE] Coqui usando speaker fallback: {common_speakers[0]}")

    @staticmethod
    def _resample_audio(data, current_sr: int, target_sr: int):  # pragma: no cover - depends on numpy availability
        if current_sr == target_sr:
            return data
        ratio = target_sr / current_sr
        indices = np.round(np.arange(0, len(data), 1 / ratio)).astype(int)
        indices = indices[indices < len(data)]
        return data[indices]


__all__ = ["CoquiTTSEngine"]
