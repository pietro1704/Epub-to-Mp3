# -*- coding: utf-8 -*-
"""Piper CLI wrapper used for offline synthesis."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import platform
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .piper_chunk_synthesis import PiperChunkSynthesis
from .piper_process_synthesis import PiperProcessSynthesis
from .piper_text_policy import (
    _is_reference_heavy_text as _is_reference_heavy_text,
    _merge_small_chunks as _merge_small_chunks,
    _planned_piper_chunk_chars as _planned_piper_chunk_chars,
    _sanitize_text_for_piper as _sanitize_text_for_piper,
    _split_text_into_chunks as _split_text_into_chunks,
)

_IS_MACOS = platform.system().lower() == "darwin"

# Piper can emit very noisy per-token warnings (e.g. missing phoneme IDs),
# which significantly slows long chapter synthesis due to terminal I/O.
with contextlib.suppress(Exception):
    logging.getLogger("piper.phoneme_ids").setLevel(logging.ERROR)
with contextlib.suppress(Exception):
    logging.getLogger("piper").setLevel(logging.ERROR)

# Chunk size for parallel Piper synthesis (env-configurable)
_PIPER_CHUNK_CHARS = int(os.environ.get("PIPER_CHUNK_CHARS", "5000"))


_DISABLE_NATIVE_DEPENDENCIES = _IS_MACOS and os.environ.get("FORCE_PIPER_NATIVE_DEPS", "0") != "1"

# Optional dependencies resolved lazily to avoid crashes in restricted environments.
np = None  # type: ignore
sf = None  # type: ignore

if not _DISABLE_NATIVE_DEPENDENCIES:
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

# **FIXED**: Global semaphore to limit simultaneous Piper processes
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
            max_procs = max(2, cpu_count)
        _piper_semaphore = asyncio.Semaphore(max_procs)
    return _piper_semaphore


_piper_prewarm_done: bool = False


def prewarm_piper(language: Optional[str] = None) -> bool:
    """Best-effort warm-up for Piper: locate the binary and resolve the
    model file for ``language`` so the first chapter does not pay either
    cost. Returns ``True`` when both lookups succeed, ``False`` otherwise.
    Idempotent within a process.
    """
    global _piper_prewarm_done
    if _piper_prewarm_done:
        return True
    try:
        binary = _find_piper_binary()
        if not binary or binary == "piper":
            # Still falls through if `piper` is on PATH at synthesis time,
            # but we couldn't confirm it now.
            return False
        # Probe the model directory for a matching voice. We don't load
        # ONNX (Piper is subprocess-based — load happens per call) but we
        # do confirm the file exists so synthesis doesn't choke later.
        try:
            from ..paths import MODELS_DIR  # type: ignore
        except Exception:
            MODELS_DIR = None  # type: ignore
        if MODELS_DIR is None:
            _piper_prewarm_done = True
            return True
        code = (language or "").split("-", 1)[0].lower()
        if code:
            piper_dir = Path(MODELS_DIR) / "piper"
            if piper_dir.exists():
                # Any .onnx whose stem starts with the language code counts.
                for model in piper_dir.glob(f"{code}_*.onnx"):
                    if model.is_file():
                        _piper_prewarm_done = True
                        return True
        _piper_prewarm_done = True
        return True
    except Exception:
        return False


def _find_piper_binary() -> str:
    """Find piper binary, checking venv first if running in one."""
    # Check if we're in a venv
    venv_path = getattr(sys, "prefix", None)
    if venv_path and venv_path != getattr(sys, "base_prefix", venv_path):
        # We're in a venv, check venv/bin first
        venv_piper = Path(venv_path) / "bin" / "piper"
        if venv_piper.exists():
            return str(venv_piper)

    # Fall back to system PATH
    piper_path = shutil.which("piper")
    if piper_path:
        return piper_path

    # Last resort: try common locations
    for location in ["/usr/local/bin/piper", "/usr/bin/piper"]:
        if Path(location).exists():
            return location

    # If not found, return "piper" and let it fail with clear error
    return "piper"


class PiperTTSEngine(PiperChunkSynthesis, PiperProcessSynthesis):
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
        enable_character_voices: bool = False,
        narrator_voice: Optional[str] = None,
        character_voice: Optional[str] = None,
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
        self._chunk_char_limit = _PIPER_CHUNK_CHARS

        # Multi-voice narration (v0.3.18): map narrator/character "voices"
        # to Piper model paths. When both resolve to existing files and
        # they differ, the dialogue splitter routes quoted spans through
        # the character model and the rest through the narrator model.
        # Otherwise the engine behaves exactly like the single-voice case.
        self.enable_character_voices = bool(enable_character_voices)
        self.narrator_model_path = self._resolve_voice_to_model(narrator_voice)
        self.character_model_path = self._resolve_voice_to_model(character_voice)
        # Sanity: only enable when both models exist AND are distinct.
        # Identical models would just slow down synthesis with extra
        # concat plumbing for no audible difference.
        if self.enable_character_voices and (
            not self.narrator_model_path
            or not self.character_model_path
            or self.narrator_model_path == self.character_model_path
        ):
            self.enable_character_voices = False

    @staticmethod
    def _resolve_voice_to_model(value: Optional[str]) -> Optional[Path]:
        """Accept either an absolute model path or a model filename.

        The CLI/server pass user-configured voice strings here; if the
        string points to an existing file we use it as the Piper model,
        otherwise we ignore it. Bare voice names that don't resolve to a
        file simply disable the multi-voice path — the warning surfaced
        by `TTSFactory.create_engine` already covers that user-facing
        case (Piper voices are model paths, unlike Edge's voice IDs).
        """
        if not value:
            return None
        try:
            candidate = Path(str(value))
        except (TypeError, ValueError):
            return None
        if candidate.exists() and candidate.is_file():
            return candidate
        return None

    def _effective_chunk_chars(self) -> int:
        """Resolve chunk size dynamically so converter auto-tuning can update it at runtime."""
        try:
            runtime_limit = int(getattr(self, "_chunk_char_limit", 0) or 0)
        except (TypeError, ValueError):
            runtime_limit = 0
        if runtime_limit > 0:
            return runtime_limit
        try:
            env_limit = int(os.environ.get("PIPER_CHUNK_CHARS", "").strip() or "0")
        except ValueError:
            env_limit = 0
        if env_limit > 0:
            return env_limit
        return _PIPER_CHUNK_CHARS

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
        self,
        text: str,
        output_path: Path,
        formatting_segments=None,
        progress_callback=None,
        chunk_callback=None,
        pre_segment_callback=None,
    ) -> Optional[Path]:
        if not text:
            return None

        def _notify_progress(segment_text: str) -> None:
            if not progress_callback:
                return
            try:
                progress_callback(segment_text, len(text))
            except Exception:
                pass

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
                            f"🔍 [VERBOSE] PiperTTS text adjusted for audio: {len(converted)} chars"
                        )
                    text = converted
            except Exception as exc:
                if self.verbose:
                    print(
                        f"🔍 [VERBOSE] PiperTTS failed to prepare text with formatting ({exc}); proceeding with basic cleanup"
                    )
                text = formatter.clean_tts_text(text)
        else:
            text = text.strip()

        text = _sanitize_text_for_piper(text)

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
            # When character-voice mode is active, route narrator/character
            # spans to two different Piper models and concatenate the
            # results. The single-language fast path stays for everything
            # else so the common case has no extra concat overhead.
            if (
                self.enable_character_voices
                and self.narrator_model_path
                and self.character_model_path
            ):
                routed = await self._synthesize_with_character_voices(
                    segment_text,
                    output_path,
                    progress_callback=progress_callback,
                    chunk_callback=chunk_callback,
                    pre_segment_callback=pre_segment_callback,
                )
                if routed is not None:
                    return routed
                # Fall through to single-voice synthesis if anything in
                # the multi-voice path failed (concat error, no spans
                # detected). Better a single voice than no audio.
            return await self._synthesize_chunked(
                segment_text,
                output_path,
                model,
                progress_callback=progress_callback,
                chunk_callback=chunk_callback,
                pre_segment_callback=pre_segment_callback,
            )

        if np is None or sf is None:
            combined_text = " ".join(segment for _, segment in segments)
            model = self._resolve_model_for_language(default_language)
            return await self._synthesize_single(combined_text, output_path, model)

        temp_seg_dir = Path(tempfile.mkdtemp(prefix="piper_mseg_"))
        temp_files: List[Path] = []
        try:
            for idx, (language, segment_text) in enumerate(segments):
                segment_text = segment_text.strip()
                if not segment_text:
                    continue
                temp_file = tempfile.NamedTemporaryFile(
                    delete=False, suffix=".wav", dir=temp_seg_dir, prefix=f"piper_seg{idx}_"
                )
                temp_file.close()
                temp_path = Path(temp_file.name)
                temp_files.append(temp_path)
                model = self._resolve_model_for_language(language)
                if pre_segment_callback:
                    with contextlib.suppress(Exception):
                        pre_segment_callback(segment_text, len(text))
                result = await self._synthesize_single(segment_text, temp_path, model)
                if result is None:
                    return None
                _notify_progress(segment_text)
                if chunk_callback:
                    try:
                        chunk_callback(idx, temp_path, segment_text)
                    except TypeError:
                        # Fallback for callbacks that don't accept text parameter
                        try:
                            chunk_callback(idx, temp_path)
                        except Exception:
                            pass
                    except Exception:
                        pass

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
            with contextlib.suppress(OSError):
                shutil.rmtree(temp_seg_dir, ignore_errors=True)

        return output_path if Path(output_path).exists() else None


    def _resolve_model_for_language(self, language: Optional[str]) -> Path:
        code = (language or "").split("-", 1)[0].lower()
        return self.language_models.get(code) or self.model_path


__all__ = ["PiperTTSEngine"]
