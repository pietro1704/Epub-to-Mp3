# -*- coding: utf-8 -*-
"""Piper CLI wrapper used for offline synthesis."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import platform
import re
import shutil
import sys
import tempfile
import time
import unicodedata
from pathlib import Path
from typing import Dict, List, Optional, Tuple

_IS_MACOS = platform.system().lower() == "darwin"

# Piper can emit very noisy per-token warnings (e.g. missing phoneme IDs),
# which significantly slows long chapter synthesis due to terminal I/O.
with contextlib.suppress(Exception):
    logging.getLogger("piper.phoneme_ids").setLevel(logging.ERROR)
with contextlib.suppress(Exception):
    logging.getLogger("piper").setLevel(logging.ERROR)

# Chunk size for parallel Piper synthesis (env-configurable)
_PIPER_CHUNK_CHARS = int(os.environ.get("PIPER_CHUNK_CHARS", "5000"))


def _split_text_into_chunks(text: str, max_chars: int) -> List[str]:
    """Split text into chunks at sentence boundaries, respecting max_chars."""
    if len(text) <= max_chars:
        return [text]

    chunks: List[str] = []
    remaining = text

    while remaining:
        if len(remaining) <= max_chars:
            chunks.append(remaining)
            break

        # Find the best split point near max_chars
        candidate = remaining[:max_chars]
        # Prefer splitting at sentence end (.!?\n)
        split_pos = -1
        for pattern in (r"[.!?]\s", r"\n"):
            for m in re.finditer(pattern, candidate):
                split_pos = m.end()
        # Fallback: split at last space
        if split_pos < max_chars // 2:
            last_space = candidate.rfind(" ")
            if last_space > max_chars // 2:
                split_pos = last_space + 1
        # Last resort: hard split
        if split_pos < max_chars // 2:
            split_pos = max_chars

        chunk = remaining[:split_pos].rstrip()
        if chunk:
            chunks.append(chunk)
        remaining = remaining[split_pos:].lstrip()

    return chunks


def _merge_small_chunks(chunks: List[str], max_chars: int, min_chars: int) -> List[str]:
    """Merge tiny adjacent chunks to reduce Piper process startup overhead."""
    if len(chunks) <= 1:
        return chunks

    merged: List[str] = []
    current = ""
    min_chars = max(1, min(min_chars, max_chars))

    for raw_chunk in chunks:
        chunk = raw_chunk.strip()
        if not chunk:
            continue
        candidate = f"{current} {chunk}".strip() if current else chunk
        if current and len(candidate) > max_chars:
            merged.append(current)
            current = chunk
            continue
        current = candidate
        if len(current) >= min_chars:
            merged.append(current)
            current = ""

    if current:
        if merged and len(current) < min_chars:
            tail = f"{merged[-1]} {current}".strip()
            if len(tail) <= max_chars:
                merged[-1] = tail
            else:
                merged.append(current)
        else:
            merged.append(current)

    return merged or chunks


def _is_reference_heavy_text(text: str) -> bool:
    """Detect end-matter style text that performs poorly with many tiny chunks."""
    if not text:
        return False
    lowered = text.lower()
    end_matter_keywords = (
        "bibliografia",
        "bibliography",
        "referências",
        "references",
        "créditos",
        "creditos",
        "credits",
        "notas",
        "notes",
        "posfácio",
        "posfacio",
        "afterword",
        "sobre o autor",
        "about the author",
    )
    if any(keyword in lowered for keyword in end_matter_keywords):
        return True

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) >= 8:
        short_lines = sum(1 for line in lines if len(line) <= 140)
        if short_lines / len(lines) >= 0.6:
            return True

    years = len(re.findall(r"\b(?:1[6-9]\d{2}|20\d{2})\b", text))
    semicolons = text.count(";")
    if years >= 8 and semicolons >= 6:
        return True

    return False


def _planned_piper_chunk_chars(text: str, base_chars: int) -> int:
    """Use larger chunks for reference-heavy end matter to avoid chunk explosion."""
    base_chars = max(1200, int(base_chars))
    if _is_reference_heavy_text(text):
        return min(6000, max(base_chars, int(base_chars * 1.75)))
    return base_chars


def _sanitize_text_for_piper(text: str) -> str:
    """Normalize text and drop problematic combining marks before Piper."""
    if not text:
        return ""
    normalized = unicodedata.normalize("NFC", text)
    # After NFC, most Latin accents are precomposed. Remaining isolated combining
    # marks tend to trigger Piper "missing phoneme" warnings and add heavy overhead.
    cleaned = "".join(ch for ch in normalized if unicodedata.category(ch) != "Mn")
    cleaned = re.sub(r"[ \t]{2,}", " ", cleaned)
    return cleaned.strip()


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

    async def _synthesize_chunked(
        self,
        text: str,
        output_path: Path,
        model_path: Path,
        progress_callback=None,
        chunk_callback=None,
        pre_segment_callback=None,
    ) -> Optional[Path]:
        """Synthesize text with parallel chunking for large inputs.

        Splits text into chunks of ~PIPER_CHUNK_CHARS, synthesizes them in
        parallel (bounded by semaphore), and concatenates WAV outputs.
        For short texts, falls back to single-shot synthesis.
        """
        max_chunk_chars = _planned_piper_chunk_chars(text, self._effective_chunk_chars())
        chunks = _split_text_into_chunks(text, max_chunk_chars)
        chunks = _merge_small_chunks(
            chunks,
            max_chunk_chars,
            min_chars=max(1400, int(max_chunk_chars * 0.55)),
        )

        # Short text: single shot (no overhead)
        if len(chunks) <= 1:
            if pre_segment_callback:
                with contextlib.suppress(Exception):
                    pre_segment_callback(text, len(text))
            return await self._synthesize_single(text, output_path, model_path)

        # Need ffmpeg for concatenation
        if not shutil.which("ffmpeg"):
            # Fallback: single shot
            return await self._synthesize_single(text, output_path, model_path)

        # Use a per-synthesis isolated temp dir so parallel chapters don't
        # share piper_chunk files and trigger cross-contamination.
        temp_dir = Path(tempfile.mkdtemp(prefix="piper_synth_"))
        temp_files: List[Path] = []
        try:
            for idx in range(len(chunks)):
                tf = tempfile.NamedTemporaryFile(
                    delete=False,
                    suffix=".wav",
                    dir=temp_dir,
                    prefix=f"piper_chunk{idx:03d}_",
                )
                tf.close()
                temp_files.append(Path(tf.name))

            # Synthesize all chunks in parallel (semaphore limits concurrency)
            tasks: Dict[int, asyncio.Task[Optional[Path]]] = {}
            for idx, (chunk_text, temp_path) in enumerate(zip(chunks, temp_files)):
                if pre_segment_callback:
                    with contextlib.suppress(Exception):
                        pre_segment_callback(chunk_text, len(text))
                tasks[idx] = asyncio.create_task(
                    self._synthesize_single(chunk_text, temp_path, model_path)
                )

            task_results: Dict[int, Optional[Path]] = {}
            if tasks:
                gathered = await asyncio.gather(*tasks.values())
                task_results = {
                    chunk_idx: result for chunk_idx, result in zip(tasks.keys(), gathered)
                }

            # Check all succeeded
            for idx, file_path in enumerate(temp_files):
                result = task_results.get(idx)
                if result is None:
                    return None
                if not file_path.exists():
                    return None
                with contextlib.suppress(OSError):
                    if file_path.stat().st_size <= 0:
                        return None
                if progress_callback:
                    try:
                        progress_callback(chunks[idx], len(text))
                    except Exception:
                        pass
                if chunk_callback:
                    try:
                        chunk_callback(idx, temp_files[idx], chunks[idx])
                    except (TypeError, Exception):
                        pass

            # Concatenate WAV files using ffmpeg
            concat_list = tempfile.NamedTemporaryFile(
                delete=False,
                suffix=".txt",
                dir=temp_dir,
                prefix="piper_concat_",
            )
            try:
                for tf in temp_files:
                    concat_list.write(f"file '{tf}'\n".encode("utf-8"))
                concat_list.close()

                wav_out = output_path.with_suffix(".wav")
                ffmpeg_proc = await asyncio.create_subprocess_exec(
                    "ffmpeg",
                    "-y",
                    "-f",
                    "concat",
                    "-safe",
                    "0",
                    "-i",
                    str(concat_list.name),
                    "-c",
                    "copy",
                    str(wav_out),
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                try:
                    await asyncio.wait_for(ffmpeg_proc.wait(), timeout=120.0)
                except asyncio.TimeoutError:
                    ffmpeg_proc.kill()
                    with contextlib.suppress(Exception):
                        await ffmpeg_proc.wait()
                    return None
                if ffmpeg_proc.returncode != 0 or not wav_out.exists():
                    return None

                # If output_path expects wav, we're done
                if output_path.suffix.lower() == ".wav":
                    if wav_out != output_path:
                        wav_out.rename(output_path)
                    return output_path if output_path.exists() else None

                # Otherwise move wav to the expected output
                wav_out.rename(output_path)
                return output_path if output_path.exists() else None
            finally:
                Path(concat_list.name).unlink(missing_ok=True)
        finally:
            for tf in temp_files:
                with contextlib.suppress(OSError):
                    tf.unlink()
            with contextlib.suppress(OSError):
                shutil.rmtree(temp_dir, ignore_errors=True)

    def _resolve_model_for_language(self, language: Optional[str]) -> Path:
        code = (language or "").split("-", 1)[0].lower()
        return self.language_models.get(code) or self.model_path

    async def _synthesize_with_character_voices(
        self,
        text: str,
        output_path: Path,
        *,
        progress_callback=None,
        chunk_callback=None,
        pre_segment_callback=None,
    ) -> Optional[Path]:
        """Mirror of Edge-TTS dialogue splitting for Piper.

        Splits ``text`` into narrator/character spans using the same
        ``dialogue_splitter`` Edge uses; synthesises each span with the
        matching Piper model; concatenates the WAV outputs into
        ``output_path``. Returns ``None`` and lets the caller fall back
        to single-voice synthesis when:

          * the splitter found only one role (no quoted dialogue);
          * numpy/soundfile aren't available (concat impossible);
          * any individual span synthesis failed.
        """
        if np is None or sf is None:
            return None
        try:
            from ..dialogue_splitter import split_into_dialogue_spans
        except Exception:
            return None

        spans = split_into_dialogue_spans(text)
        roles = {span.role for span in spans if span.text.strip()}
        if len(roles) < 2:
            # Pure narration or pure dialogue — single-voice path is fine.
            return None

        temp_dir = Path(tempfile.mkdtemp(prefix="piper_charvoice_"))
        temp_files: List[Path] = []
        try:
            for idx, span in enumerate(spans):
                payload = span.text.strip()
                if not payload:
                    continue
                model = (
                    self.character_model_path
                    if span.role == "character"
                    else self.narrator_model_path
                )
                temp_file = tempfile.NamedTemporaryFile(
                    delete=False,
                    suffix=".wav",
                    dir=temp_dir,
                    prefix=f"piper_role_{span.role}_{idx}_",
                )
                temp_file.close()
                temp_path = Path(temp_file.name)
                temp_files.append(temp_path)
                if pre_segment_callback:
                    with contextlib.suppress(Exception):
                        pre_segment_callback(payload, len(text))
                result = await self._synthesize_single(payload, temp_path, model)
                if result is None:
                    return None
                if progress_callback:
                    with contextlib.suppress(Exception):
                        progress_callback(payload, len(text))
                if chunk_callback:
                    with contextlib.suppress(TypeError):
                        chunk_callback(idx, temp_path, payload)
                    with contextlib.suppress(Exception):
                        chunk_callback(idx, temp_path)

            if not temp_files:
                return None

            audio_chunks: List[np.ndarray] = []
            sample_rate: Optional[int] = None
            for path in temp_files:
                data, sr = sf.read(str(path))
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
            for path in temp_files:
                with contextlib.suppress(OSError):
                    path.unlink()
            with contextlib.suppress(OSError):
                shutil.rmtree(temp_dir, ignore_errors=True)

        return output_path if Path(output_path).exists() else None

    async def _synthesize_single(
        self, text: str, output_path: Path, model_path: Path
    ) -> Optional[Path]:
        piper_bin = _find_piper_binary()
        command = (
            piper_bin,
            "--model",
            str(model_path),
            "--output_file",
            str(output_path),
        )
        max_retries = max(0, int(os.environ.get("PIPER_CHUNK_MAX_RETRIES", "1") or "1"))
        stall_seconds = float(os.environ.get("PIPER_CHUNK_STALL_SECONDS", "45") or "45")
        stall_seconds = max(0.0, stall_seconds)

        # **FIXED**: Use semaphore to limit simultaneous processes
        async with self._semaphore:
            for _attempt in range(max_retries + 1):
                with contextlib.suppress(Exception):
                    output_path.unlink(missing_ok=True)
                try:
                    process = await asyncio.create_subprocess_exec(
                        *command,
                        stdin=asyncio.subprocess.PIPE,
                        stdout=asyncio.subprocess.DEVNULL,
                        stderr=asyncio.subprocess.DEVNULL,
                    )
                    if stall_seconds > 0:
                        ok = await self._communicate_with_stall_watchdog(
                            process=process,
                            payload=text.encode("utf-8"),
                            output_path=output_path,
                            stall_seconds=stall_seconds,
                        )
                        if not ok:
                            continue
                    else:
                        await process.communicate(input=text.encode("utf-8"))
                except Exception:
                    continue

                if process.returncode == 0 and Path(output_path).exists():
                    return output_path

        return None

    async def _communicate_with_stall_watchdog(
        self,
        *,
        process: asyncio.subprocess.Process,
        payload: bytes,
        output_path: Path,
        stall_seconds: float,
    ) -> bool:
        """Abort stuck Piper process when output file stops growing for too long."""
        task = asyncio.create_task(process.communicate(input=payload))
        last_size = -1
        last_growth = time.time()
        try:
            while not task.done():
                await asyncio.sleep(1.0)
                current_size = 0
                with contextlib.suppress(OSError):
                    current_size = int(output_path.stat().st_size)
                if current_size > last_size:
                    last_size = current_size
                    last_growth = time.time()
                    continue
                if (time.time() - last_growth) >= stall_seconds:
                    with contextlib.suppress(Exception):
                        process.kill()
                    with contextlib.suppress(Exception):
                        await process.wait()
                    with contextlib.suppress(Exception):
                        task.cancel()
                    return False
            with contextlib.suppress(Exception):
                await task
        finally:
            if not task.done():
                with contextlib.suppress(Exception):
                    task.cancel()
        return True

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
