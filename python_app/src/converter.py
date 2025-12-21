# -*- coding: utf-8 -*-
"""Audio conversion pipeline wired to the TTS engines."""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, replace
import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Set

import psutil
from mutagen.id3 import ID3, APIC, TIT2, TALB, TPE1
from mutagen.mp3 import MP3

from .ebook_reader import EbookReader, Chapter
from .config import ConversionConfig
from .tts.factory import TTSFactory
from .utils import AudioProcessor, FileManager, TextValidator, resolve_cache_root
from .progress import ProgressTracker
from .i18n import Localization, get_localization
from .cache_manager import CacheManager
from .speed_controller import AdaptiveSpeedController
from .chapter_utils import deduplicate_chapters_by_content


@dataclass
class ConversionResult:
    """Result of audio conversion"""
    success: bool
    total_chapters: int
    converted_chapters: int
    output_files: List[Path]
    errors: List[str]


@dataclass
class ChapterConversionOutcome:
    """Outcome of a single chapter conversion."""

    index: int
    name: str
    path: Optional[Path]
    error: Optional[str] = None
    slowdown: bool = False


class AudioConverter:
    """Coordinate ebook parsing, TTS synthesis and post-processing."""

    def __init__(self, localization: Optional[Localization] = None) -> None:
        self.tts_factory = TTSFactory()
        self.audio_processor = AudioProcessor()
        self.file_manager = FileManager()
        self.progress = ProgressTracker()
        self.cache_manager = CacheManager()
        self.speed_controller = AdaptiveSpeedController()
        self._requirements_attempted = False
        self.loc = localization or get_localization()
        self.verbose = False
        self._current_book_path: Optional[Path] = None
        self.show_tts_output = False  # Only show TTS output in verbose mode
        self._retry_original_texts: Dict[str, str] = {}
        self._parallel_state: Dict[str, Any] = {
            "ceiling": 1,
            "current": 1,
            "best_throughput": 0.0,
            "last_throughput": None,
            "degrade_runs": 0,
        }
        self._health_state: Dict[str, Any] = {"active": False}
        self._health_watchdog: Optional[asyncio.Task] = None
        self._cover_art: Optional[dict] = None

    @staticmethod
    def _speech_text(chapter: Chapter) -> str:
        text = getattr(chapter, "speech_text", None)
        if text is None:
            text = chapter.text or ""
        return text

    def _extract_cover_art(self, reader: EbookReader) -> Optional[dict]:
        extractor = getattr(reader, "extract_cover_image", None)
        if callable(extractor):
            try:
                cover = extractor()
            except Exception:
                cover = None
            if cover and getattr(cover, "data", None):
                return {
                    "data": cover.data,
                    "mime": getattr(cover, "media_type", "image/jpeg") or "image/jpeg",
                }
        return None

    def _embed_id3_metadata(
        self,
        mp3_path: Path,
        *,
        title: str,
        album: Optional[str],
        artist: Optional[str],
        cover_art: Optional[dict],
    ) -> None:
        try:
            audio = MP3(mp3_path, ID3=ID3)
            if audio.tags is None:
                audio.add_tags()
        except Exception:
            return

        try:
            audio.tags.delall("TIT2")
            audio.tags.delall("TALB")
            audio.tags.delall("TPE1")
            audio.tags.delall("APIC")
        except Exception:
            pass

        try:
            audio.tags["TIT2"] = TIT2(encoding=3, text=title or mp3_path.name)
            if album:
                audio.tags["TALB"] = TALB(encoding=3, text=album)
            if artist:
                audio.tags["TPE1"] = TPE1(encoding=3, text=artist)
            if cover_art and cover_art.get("data"):
                mime = cover_art.get("mime") or "image/jpeg"
                try:
                    audio.tags.add(
                        APIC(
                            encoding=3,
                            mime=mime,
                            type=3,
                            desc="Cover",
                            data=cover_art["data"],
                        )
                    )
                except Exception:
                    pass
            audio.save()
        except Exception:
            if self.verbose:
                print(f"   ⚠️ Falha ao embutir metadados ID3 em {mp3_path.name}")

    @staticmethod
    def _title_from_filename(mp3_path: Path) -> str:
        stem = mp3_path.stem
        parts = stem.split("_", 1)
        candidate = stem
        if len(parts) == 2 and parts[0].isdigit():
            candidate = parts[1]
        candidate = candidate.replace("_", " ").strip()
        return candidate or mp3_path.name

    def _apply_final_id3_tags(
        self,
        files: Iterable[Path],
        *,
        default_album: Optional[str],
        artist: Optional[str],
        cover_art: Optional[dict],
    ) -> None:
        album_fallback = default_album or ""
        for mp3_path in files:
            try:
                path_obj = Path(mp3_path)
            except TypeError:
                continue
            if path_obj.suffix.lower() != ".mp3" or not path_obj.exists():
                continue
            title = self._title_from_filename(path_obj)
            album = album_fallback or path_obj.parent.name
            self._embed_id3_metadata(
                path_obj,
                title=title,
                album=album,
                artist=artist or None,
                cover_art=cover_art,
            )

    @staticmethod
    def _bitrate_to_bps(bitrate: Optional[str]) -> Optional[int]:
        if bitrate is None:
            return None
        text = str(bitrate).strip().lower()
        if not text:
            return None
        multiplier = 1_000 if text.endswith(("kbps", "k")) else 1
        if text.endswith("mbps") or text.endswith("m"):
            multiplier = 1_000_000
        suffixes = ("mbps", "kbps", "bps", "m", "k")
        for suffix in suffixes:
            if text.endswith(suffix):
                text = text[: -len(suffix)]
                break
        text = text.strip()
        if not text:
            return None
        try:
            value = float(text)
        except ValueError:
            return None
        bps = int(value * multiplier)
        return bps if bps > 0 else None

    @classmethod
    def _expected_audio_bytes(cls, estimated_seconds: float, bitrate: Optional[str]) -> Optional[int]:
        if estimated_seconds <= 0:
            return None
        bps = cls._bitrate_to_bps(bitrate)
        if not bps:
            return None
        expected = estimated_seconds * (bps / 8.0)
        return int(expected)

    def _probe_audio_duration(self, audio_path: Path) -> Optional[float]:
        try:
            result = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(audio_path),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode == 0:
                value = result.stdout.strip()
                if value:
                    duration = float(value)
                    if duration > 0:
                        return duration
        except FileNotFoundError:
            pass
        except Exception:
            pass
        return None

    def _detect_short_audio_output(
        self,
        audio_path: Path,
        payload_text: Optional[str],
        config: ConversionConfig,
    ) -> Optional[str]:
        audio_path = Path(audio_path)
        if not audio_path.exists() or not payload_text:
            return None

        try:
            file_size = audio_path.stat().st_size
        except OSError:
            file_size = 0

        stripped = payload_text.strip() if payload_text else ""
        if len(stripped) < 2000:
            return None

        estimated_seconds = TextValidator.estimate_duration(stripped)
        if estimated_seconds < 150:
            return None

        actual_seconds = self._probe_audio_duration(audio_path)
        if actual_seconds and actual_seconds >= estimated_seconds * 0.60:
            return None
        if actual_seconds and actual_seconds >= max(estimated_seconds - 90, estimated_seconds * 0.5):
            return None

        expected_bytes = self._expected_audio_bytes(estimated_seconds, getattr(config, "bitrate", "8k"))
        ratio_warning = False
        approx_seconds = None
        if expected_bytes:
            minimum_expected = max(int(expected_bytes * 0.55), 180_000)
            if file_size < minimum_expected:
                ratio_warning = True
        if not ratio_warning and actual_seconds is None:
            bitrate_bps = self._bitrate_to_bps(getattr(config, "bitrate", "8k")) or 8_000
            approx_seconds_calc = (file_size * 8) / max(bitrate_bps, 1)
            approx_seconds = int(approx_seconds_calc)
            if approx_seconds < estimated_seconds * 0.55:
                ratio_warning = True

        if not ratio_warning and actual_seconds is None:
            return None

        short_seconds = approx_seconds if approx_seconds is not None else int(actual_seconds or 0)
        if actual_seconds is not None:
            short_seconds = int(actual_seconds)

        expected_display = int(estimated_seconds)
        if short_seconds <= 0:
            short_seconds = max(int((file_size or 1) / 1000), 1)

        return (
            f"Áudio possivelmente truncado ({file_size} bytes ≈ {short_seconds}s, esperado ≈ {expected_display}s)"
        )

    def _load_cached_payload(
        self,
        chapter: Chapter,
        index: int,
        temp_dir: Path,
    ) -> Optional[str]:
        try:
            text_dir = Path(temp_dir) / "text"
            safe_name = self.file_manager.sanitize_filename(getattr(chapter, "name", None) or f"Chapter {index}")
            candidate = text_dir / f"{index} - {safe_name}-pre-tts.txt"
            if candidate.exists():
                return candidate.read_text(encoding="utf-8")
        except OSError:
            pass
        return None

    def _prepare_truncation_retry_payload(
        self,
        chapter: Chapter,
        canonical_label: str,
        attempts_so_far: int,
    ) -> None:
        """Simplify chapter payload before a retry after truncated audio detection."""
        baseline = self._retry_original_texts.get(canonical_label)
        if baseline is None:
            baseline = self._speech_text(chapter)
            self._retry_original_texts[canonical_label] = baseline

        updated_text: Optional[str] = None
        try:
            from ..language import LanguageMarkup
        except ImportError:
            LanguageMarkup = None  # type: ignore

        if attempts_so_far <= 1:
            if LanguageMarkup:
                stripped = LanguageMarkup.strip(baseline)  # type: ignore[attr-defined]
                if stripped and stripped.strip() and stripped != self._speech_text(chapter):
                    updated_text = stripped
        elif attempts_so_far == 2:
            stripped = LanguageMarkup.strip(baseline) if LanguageMarkup else baseline  # type: ignore[attr-defined]
            cleaned = re.sub(r"\[\[fmt:[^\]]+\]\]|\[\[/fmt\]\]", "", stripped or "")
            updated_text = cleaned.strip()
            chapter.formatting_segments = None
        else:
            stripped = LanguageMarkup.strip(baseline) if LanguageMarkup else baseline  # type: ignore[attr-defined]
            truncated = (stripped or "")[: max(12_000, len(stripped or "") // 2 or 6_000)]
            updated_text = truncated.strip()
            chapter.formatting_segments = None

        if updated_text and updated_text != self._speech_text(chapter):
            chapter.speech_text = updated_text

    @staticmethod
    def _chapter_display_name(chapter: Chapter, index: int) -> str:
        """Return the label consistently used when reporting chapter status."""
        name = getattr(chapter, "name", None)
        if name:
            return str(name)
        return f"Chapter {index}"

    @staticmethod
    def _build_error_map(errors: Iterable[str]) -> Dict[str, str]:
        """Map `\"Chapter\": \"error\"` from the converter error list."""
        error_map: Dict[str, str] = {}
        for entry in errors or []:
            if not entry:
                continue
            if ":" in entry:
                name, message = entry.rsplit(":", 1)
                error_map[name.strip()] = message.strip()
            else:
                error_map[entry.strip()] = ""
        return error_map

    def _register_chapter_lookup(
        self,
        lookup: Dict[str, tuple[Chapter, int, str]],
        label: str,
        chapter: Chapter,
        index: int,
    ) -> None:
        """Register multiple lookup keys for a chapter name."""
        canonical = label.strip() or label
        variants = {
            canonical,
            canonical.strip(),
            " ".join(canonical.split()),
        }
        lower = canonical.lower()
        variants.add(lower)
        variants.add(lower.strip())
        sanitized = self.file_manager.sanitize_filename(canonical)
        if sanitized:
            variants.add(sanitized)
            variants.add(sanitized.lower())
        for key in variants:
            if not key:
                continue
            lookup.setdefault(key, (chapter, index, canonical))

    def _lookup_chapter_entry(
        self,
        lookup: Dict[str, tuple[Chapter, int, str]],
        name: str,
    ) -> Optional[tuple[Chapter, int, str]]:
        """Find a chapter entry in the lookup using relaxed matching."""
        if not name:
            return None
        candidates = [
            name,
            name.strip(),
            " ".join(name.split()),
        ]
        lower = name.lower()
        candidates.append(lower)
        candidates.append(lower.strip())
        sanitized = self.file_manager.sanitize_filename(name)
        if sanitized:
            candidates.append(sanitized)
            candidates.append(sanitized.lower())
        seen: set[str] = set()
        for candidate in candidates:
            if not candidate or candidate in seen:
                continue
            seen.add(candidate)
            entry = lookup.get(candidate)
            if entry:
                return entry
        return None

    def _normalise_failure_keys(
        self,
        failures: Dict[str, str],
        lookup: Dict[str, tuple[Chapter, int, str]],
    ) -> tuple[Dict[str, str], Dict[str, str]]:
        """Normalise failure keys to canonical chapter labels."""
        normalised: Dict[str, str] = {}
        unresolved: Dict[str, str] = {}
        for raw_name, message in failures.items():
            entry = self._lookup_chapter_entry(lookup, raw_name)
            if entry:
                _, _, canonical = entry
                normalised[canonical] = message
            else:
                unresolved[raw_name] = message
        return normalised, unresolved

    def _detect_failed_chapters_by_output(
        self,
        chapters: List[Chapter],
        temp_dir: Path,
    ) -> Dict[str, str]:
        """Detect chapters that lack a valid audio artifact after conversion."""
        detected: Dict[str, str] = {}
        for idx, chapter in enumerate(chapters, start=1):
            label = self._chapter_display_name(chapter, idx).strip()
            output_path = self.file_manager.get_temp_output_path(chapter.name, temp_dir, idx)
            if not output_path.exists():
                detected[label] = "Arquivo ausente após tentativa inicial"
                continue
            try:
                size = output_path.stat().st_size
            except OSError:
                size = 0
            if size <= 1000:
                detected[label] = f"Arquivo inválido ({size} bytes)"
        return detected

    def _validate_and_clean_cache(self, chapters: List[Chapter], output_dir: Path, config: ConversionConfig) -> None:
        """Validate cache: if MP3 exists but pre-tts.txt doesn't, delete MP3"""
        text_dir = Path(output_dir) / "text"
        deleted_count = 0

        for idx, chapter in enumerate(chapters):
            chapter_num = idx + 1
            chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_num}"
            safe_name = self.file_manager.sanitize_filename(chapter_name)

            # Check for pre-tts.txt
            pre_tts_file = text_dir / f"{chapter_num} - {safe_name}-pre-tts.txt"

            # Check for MP3
            mp3_path = self.file_manager.get_temp_output_path(chapter.name, output_dir, chapter_num)

            # If MP3 exists but pre-tts.txt doesn't → cache invalidated, delete MP3
            if mp3_path.exists() and not pre_tts_file.exists():
                if self.verbose:
                    print(f"   🗑️ Cache inválido para capítulo {chapter_num}: {mp3_path.name}")
                mp3_path.unlink()
                deleted_count += 1

        if deleted_count > 0:
            print(f"🗑️ {deleted_count} arquivo(s) MP3 removido(s) (cache inválido)")

    def _generate_all_text_files(self, chapters: List[Chapter], output_dir: Path, config: ConversionConfig) -> None:
        """Generate all text files BEFORE starting TTS conversion"""
        text_dir = Path(output_dir) / "text"
        text_dir.mkdir(parents=True, exist_ok=True)

        # Import TextFormattingProcessor to apply the same processing as TTS
        try:
            from .text_formatting import TextFormattingProcessor
            formatter = TextFormattingProcessor()
        except ImportError:
            formatter = None

        def _prepare_payload(chapter_index: int, chapter_obj: Chapter) -> tuple[int, str, str, str]:
            chapter_name_local = getattr(chapter_obj, "name", None) or f"Chapter {chapter_index}"
            parsed_text_local = chapter_obj.text or ""
            speech_text_local = self._speech_text(chapter_obj)
            if formatter:
                formatting_segments_local = getattr(chapter_obj, 'formatting_segments', None)
                pre_tts_text_local = formatter.to_audible_text(speech_text_local, formatting_segments_local)
            else:
                pre_tts_text_local = speech_text_local
            return (chapter_index, chapter_name_local, parsed_text_local, pre_tts_text_local or "")

        files_generated = 0
        with ThreadPoolExecutor(max_workers=min(4, (os.cpu_count() or 1))) as executor:
            futures = [
                executor.submit(_prepare_payload, idx + 1, chapter)
                for idx, chapter in enumerate(chapters)
            ]

            for future in futures:
                chapter_num, chapter_name, parsed_text, pre_tts_text = future.result()
                safe_name = self.file_manager.sanitize_filename(chapter_name)
                parsed_path = text_dir / f"{chapter_num} - {safe_name}-parsed.txt"
                pre_tts_path = text_dir / f"{chapter_num} - {safe_name}-pre-tts.txt"

                if parsed_path.exists() and pre_tts_path.exists():
                    continue

                parsed_path.write_text(parsed_text, encoding="utf-8")
                pre_tts_path.write_text(pre_tts_text, encoding="utf-8")
                files_generated += 2

                if self.verbose:
                    print(f"   📄 {chapter_num}. {chapter_name}")
                    print(f"      → {parsed_path.name}")
                    print(f"      → {pre_tts_path.name}")
                    if formatter and parsed_text != pre_tts_text:
                        chars_added = len(pre_tts_text) - len(parsed_text)
                        print(f"      ℹ️  Formatação adicionou {chars_added} chars (cues audíveis)")

        if files_generated == 0 and self.verbose:
            print("   ♻️ Todos os arquivos .txt já existem (usando cache)")

    def _reset_parallel_state(self, recommended_parallel: int) -> None:
        """Initialise the dynamic parallelism state."""
        target = max(1, int(recommended_parallel or 1))
        self._parallel_state = {
            "ceiling": target,
            "current": target,
            "best_throughput": 0.0,
            "last_throughput": None,
            "degrade_runs": 0,
        }
        with contextlib.suppress(Exception):
            # Warm up psutil cpu_percent to avoid 0.0 on first reading
            psutil.cpu_percent(interval=None)

    def _estimate_chapter_chars(self, chapter: Chapter) -> int:
        """Estimate the number of characters for a chapter."""
        try:
            text = self._speech_text(chapter)
        except Exception:
            text = getattr(chapter, "text", "") or ""
        return len(text or "")

    def _resource_snapshot(self) -> tuple[float, float]:
        """Return (cpu_percent, ram_available_gb)."""
        cpu_pct = 0.0
        ram_gb = 0.0
        with contextlib.suppress(Exception):
            cpu_pct = float(psutil.cpu_percent(interval=None))
        with contextlib.suppress(Exception):
            mem = psutil.virtual_memory()
            ram_gb = float(mem.available / (1024**3))
        return (cpu_pct, ram_gb)

    def _auto_tune_parallelism(
        self,
        *,
        throughput: Optional[float],
        batch_errors: int,
    ) -> tuple[int, Optional[str]]:
        """Decide the next chapter parallelism level based on telemetry."""
        state = self._parallel_state or {}
        ceiling = max(1, int(state.get("ceiling") or 1))
        current = max(1, min(ceiling, int(state.get("current") or 1)))
        best = float(state.get("best_throughput") or 0.0)
        last = state.get("last_throughput")
        degrade_runs = int(state.get("degrade_runs") or 0)
        cpu_pct, ram_gb = self._resource_snapshot()
        reason: Optional[str] = None
        new_value = current

        if batch_errors > 0:
            new_value = max(1, current - 1)
            state["degrade_runs"] = min(3, degrade_runs + 1)
            reason = f"reduzindo para {new_value} capítulo(s) simultâneos após {batch_errors} erro(s)"
        else:
            state["degrade_runs"] = max(0, degrade_runs - 1)
            if throughput:
                if throughput > best:
                    state["best_throughput"] = throughput
                if last and throughput < last * 0.78 and current > 1:
                    new_value = current - 1
                    reason = (
                        f"throughput caiu de ~{int(last)} para ~{int(throughput)} chars/s → "
                        f"{new_value} capítulo(s)"
                    )
                elif last and throughput >= last * 1.18 and current < ceiling:
                    new_value = current + 1
                    reason = (
                        f"throughput atingiu ~{int(throughput)} chars/s → "
                        f"testando {new_value} capítulo(s)"
                    )
                elif not last and current < ceiling and throughput >= max(best, 1.0):
                    new_value = current + 1
                    reason = (
                        f"lote inicial rápido (~{int(throughput)} chars/s) → "
                        f"{new_value} capítulo(s)"
                    )

            if not reason:
                if ram_gb < 0.45 and new_value > 1:
                    new_value = new_value - 1
                    reason = f"RAM livre baixa ({ram_gb:.1f} GB) → limitando a {new_value}"
                elif cpu_pct < 55.0 and new_value < ceiling:
                    new_value = new_value + 1
                    reason = f"CPU em {int(cpu_pct)}% → liberando {new_value} capítulo(s)"
                elif cpu_pct > 94.0 and throughput and throughput < best * 0.85 and new_value > 1:
                    new_value = new_value - 1
                    reason = f"CPU saturada ({int(cpu_pct)}%) sem ganho → {new_value} capítulo(s)"

        new_value = max(1, min(ceiling, new_value))
        if throughput:
            state["last_throughput"] = throughput
        elif "last_throughput" not in state:
            state["last_throughput"] = None
        state["current"] = new_value
        self._parallel_state = state
        return new_value, reason

    def _start_health_watchdog(self, total_chapters: int) -> None:
        """Launch watchdog to observe stalled conversions."""
        if total_chapters <= 0:
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return
        state = {
            "active": True,
            "total": max(total_chapters, 0),
            "completed": 0,
            "last_progress": time.time(),
            "warn_emitted": False,
            "action_emitted": False,
        }
        self._health_state = state
        if self._health_watchdog:
            self._health_watchdog.cancel()
        self._health_watchdog = loop.create_task(self._watch_conversion_health())

    async def _stop_health_watchdog(self) -> None:
        """Stop watchdog task."""
        state = getattr(self, "_health_state", None)
        if isinstance(state, dict):
            state["active"] = False
        task = self._health_watchdog
        self._health_watchdog = None
        if task:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

    def _mark_health_progress(
        self,
        chapter_index: int,
        success: bool,
        elapsed: float,
        error: Optional[str] = None,
    ) -> None:
        """Update watchdog state after each chapter."""
        state = getattr(self, "_health_state", None)
        if not isinstance(state, dict) or not state.get("active"):
            return
        state["last_progress"] = time.time()
        state["completed"] = min(state.get("completed", 0) + 1, state.get("total", 0))
        state["last_chapter"] = chapter_index
        state["last_success"] = bool(success)
        state["last_elapsed"] = float(elapsed or 0.0)
        state["last_error"] = error or ""
        state["warn_emitted"] = False
        state["action_emitted"] = False

    async def _watch_conversion_health(self) -> None:
        """Background loop that watches for long stalls."""
        warning_threshold = 90.0
        action_threshold = 150.0
        check_interval = 15.0
        while True:
            await asyncio.sleep(check_interval)
            state = getattr(self, "_health_state", None)
            if not isinstance(state, dict) or not state.get("active"):
                break
            total = state.get("total", 0)
            completed = state.get("completed", 0)
            if total and completed >= total:
                break
            last_progress = state.get("last_progress") or time.time()
            stalled = time.time() - last_progress
            if stalled >= action_threshold and not state.get("action_emitted"):
                state["action_emitted"] = True
                last_chapter = state.get("last_chapter")
                info = f"{int(stalled)}s sem concluir capítulos"
                if last_chapter:
                    info += f" (último capítulo #{last_chapter})"
                print(f"\n🩺 Watchdog: {info} – investigando gargalo")
                if not self._apply_watchdog_backpressure():
                    print("   Sugestão: verifique conexão ou permitir fallback offline (Coqui/Piper).")
            elif stalled >= warning_threshold and not state.get("warn_emitted"):
                state["warn_emitted"] = True
                print(f"\n⚠️ Watchdog: Nenhum capítulo finalizado há {int(stalled)}s – aguardando progresso...")

    def _apply_watchdog_backpressure(self) -> bool:
        """Reduce parallelism when stalling to regain stability."""
        state = self._parallel_state or {}
        current = int(state.get("current") or 1)
        ceiling = int(state.get("ceiling") or current)
        if current > 1:
            new_value = max(1, current - 1)
            state["current"] = new_value
            state["ceiling"] = max(1, min(new_value, ceiling))
            self._parallel_state = state
            print(f"   🧠 Watchdog: reduzindo capítulos simultâneos {current} → {new_value}")
            return True
        return False

    async def convert(self, reader: EbookReader, config: ConversionConfig) -> ConversionResult:
        """Convert all chapters in ``reader`` according to ``config``."""

        # Enable verbose mode if requested
        self.verbose = getattr(config, 'verbose', False)
        # Show TTS output only in verbose mode
        self.show_tts_output = self.verbose

        if self.verbose:
            print("🔍 [VERBOSE] AudioConverter.convert() iniciado")
            print(f"🔍 [VERBOSE] Configuração: engine={getattr(config, 'engine', 'unknown')}, mode=sequential")

        # Setup paths
        reader_path = getattr(reader, "file_path", None)
        try:
            self._current_book_path = Path(reader_path) if reader_path else None
        except TypeError:
            self._current_book_path = None

        output_dir = self._setup_output_directory(config)
        # Setup temporary directory for conversion (uses .cache)
        temp_dir = self._setup_temp_directory(config)
        chapters = list(reader.get_chapter_structure(preserve_all=config.preserve_all_chapters) or [])
        chapters, duplicates_removed = deduplicate_chapters_by_content(chapters)
        if duplicates_removed:
            print(f"🧹 Capítulos duplicados removidos automaticamente: {duplicates_removed}")
        if getattr(config, "priority_selectors", None):
            chapters = self._prioritize_chapters(chapters, config.priority_selectors)
        total_chapters = len(chapters)
        chapter_lookup: Dict[str, tuple[Chapter, int, str]] = {}
        for idx, chapter in enumerate(chapters, start=1):
            label = self._chapter_display_name(chapter, idx)
            self._register_chapter_lookup(chapter_lookup, label, chapter, idx)

        if self.verbose:
            print(f"🔍 [VERBOSE] Total de capítulos: {total_chapters}")
            print(f"🔍 [VERBOSE] Diretório de saída: {output_dir}")
            print(f"🔍 [VERBOSE] Diretório temporário: {temp_dir}")

        print(self.loc.t("conversion_start", title=reader.title, chapters=total_chapters))
        print(self.loc.t("conversion_output", path=output_dir))
        chapter_parallel_count = int(os.getenv("CHAPTER_PARALLEL_COUNT", "1"))
        self._reset_parallel_state(chapter_parallel_count)
        if chapter_parallel_count > 1:
            print(f"🚀 Modo paralelo automático: até {chapter_parallel_count} capítulos simultâneos")
        else:
            print("🔄 Modo sequencial automático: processando capítulos um por vez")

        if total_chapters == 0:
            empty_result = ConversionResult(True, 0, 0, [], [])
            self._report_results(empty_result)
            return empty_result

        self._start_health_watchdog(total_chapters)

        # **NEW**: Generate ALL .txt files BEFORE starting TTS conversion
        print("\n📝 Gerando arquivos de texto...")
        self._generate_all_text_files(chapters, temp_dir, config)
        print(f"✅ {total_chapters} arquivos de texto gerados\n")

        cover_art = self._extract_cover_art(reader)
        book_title = reader.title or getattr(config, "book_title", None) or (self._current_book_path.stem if self._current_book_path else "")
        book_author = reader.author or ""
        self.progress.start(total_chapters, description=self.loc.t("progress_description"))

        is_auto_engine = (config.engine or "").lower() == "auto"
        auto_engine_pool: Dict[str, tuple[ConversionConfig, object]] = {}
        try:
            if is_auto_engine:
                auto_engine_pool = self._prepare_auto_engines(config)
                if not auto_engine_pool:
                    raise RuntimeError("Nenhuma engine disponível no modo automático")
                tts_engine = None
            else:
                tts_engine = self.tts_factory.create_engine(config)
        except ImportError as exc:
            if self._install_requirements():
                if is_auto_engine:
                    auto_engine_pool = self._prepare_auto_engines(config)
                    if not auto_engine_pool:
                        raise RuntimeError("Nenhuma engine disponível no modo automático")
                    tts_engine = None
                else:
                    tts_engine = self.tts_factory.create_engine(config)
            else:
                raise
        if is_auto_engine:
            voice_label = "Auto (Edge/Coqui/Piper)"
        else:
            voice_label = getattr(tts_engine, "voice", None) or config.voice or "(auto)"
        print(self.loc.t("conversion_engine_voice", engine=config.engine, voice=voice_label))
        if getattr(config, "languages", None):
            print(self.loc.t("conversion_languages", languages=", ".join(config.languages)))

        if self.verbose:
            print(f"🔍 [VERBOSE] Engine configurado: {type(tts_engine).__name__}")

        # Choose parallel or sequential based on hardware detection
        if chapter_parallel_count > 1:
            result = await self._convert_chapters_parallel(
                chapters,
                tts_engine,
                temp_dir,
                config,
                max_concurrent_chapters=chapter_parallel_count,
                is_auto_engine=is_auto_engine,
                auto_engine_pool=auto_engine_pool,
            )
        else:
            result = await self._convert_chapters_sequential(
                chapters,
                tts_engine,
                temp_dir,
                config,
                is_auto_engine=is_auto_engine,
                auto_engine_pool=auto_engine_pool,
            )

        total_output_files = list(result.output_files)
        raw_failures = self._build_error_map(result.errors)
        pending_failures, unresolved_failures = self._normalise_failure_keys(raw_failures, chapter_lookup)
        unresolved_pool: Dict[str, str] = dict(unresolved_failures)
        attempts_used: Dict[str, int] = {label: 1 for label in pending_failures}

        for unresolved in unresolved_failures:
            print(f"⚠️ Não foi possível correlacionar capítulo com falha: {unresolved}")

        max_retry_rounds = 5
        extra_retry_value = None
        if getattr(config, "extra", None):
            extra_retry_value = config.extra.get("max_auto_retries") or config.extra.get("max_retries")
        if extra_retry_value is None:
            extra_retry_value = getattr(config, "max_auto_retries", None)
        try:
            if extra_retry_value is not None:
                max_retry_rounds = max(0, int(extra_retry_value))
        except (ValueError, TypeError):
            pass
        if not pending_failures and result.converted_chapters < total_chapters:
            fallback_detected = self._detect_failed_chapters_by_output(chapters, temp_dir)
            if fallback_detected:
                for label in fallback_detected:
                    attempts_used.setdefault(label, 1)
                pending_failures.update(fallback_detected)
                print(f"\n⚠️ Capítulos sem áudio válido detectados: {len(fallback_detected)}")
                if self.verbose:
                    print("   → " + ", ".join(sorted(fallback_detected.keys())))

        if pending_failures:
            failed_labels = ", ".join(sorted(pending_failures.keys()))
            print(f"\n⚠️ Capítulos com falha detectados: {len(pending_failures)}")
            if self.verbose:
                print(f"   → {failed_labels}")

        retry_round = 1
        while pending_failures and retry_round <= max_retry_rounds:
            failed_names = list(pending_failures.keys())
            chapters_to_retry_info = []
            missing_names = []
            for name in failed_names:
                entry = self._lookup_chapter_entry(chapter_lookup, name)
                if entry:
                    chapter_obj, original_idx, canonical_label = entry
                    chapters_to_retry_info.append((chapter_obj, original_idx, canonical_label))
                    attempts_used.setdefault(canonical_label, 1)
                else:
                    missing_names.append(name)

            for missing in missing_names:
                message = pending_failures.pop(missing, "")
                unresolved_pool[missing] = message or "Motivo desconhecido"
                attempts_used.pop(missing, None)
                print(f"⚠️ Não foi possível localizar capítulo para retry: {missing}")

            if not chapters_to_retry_info:
                break

            for chapter_obj, _original_idx, canonical_label in chapters_to_retry_info:
                failure_message = pending_failures.get(canonical_label, "")
                if "Áudio possivelmente truncado" in (failure_message or ""):
                    attempts_so_far = attempts_used.get(canonical_label, 1)
                    self._prepare_truncation_retry_payload(chapter_obj, canonical_label, attempts_so_far)

            chapters_to_retry_info.sort(key=lambda item: item[1])
            chapters_to_retry = [item[0] for item in chapters_to_retry_info]

            print(f"\n🔁 Reprocessando {len(chapters_to_retry)} capítulo(s) com falha (tentativa {retry_round}/{max_retry_rounds})")
            retry_config = replace(config, force_reprocess=True)
            retry_result = await self._convert_chapters_sequential(chapters_to_retry, tts_engine, temp_dir, retry_config)

            total_output_files.extend(retry_result.output_files)
            retry_error_map = self._build_error_map(retry_result.errors)
            normalised_retry, unresolved_retry = self._normalise_failure_keys(retry_error_map, chapter_lookup)
            for unresolved, message in unresolved_retry.items():
                print(f"⚠️ Falha retornada sem correspondência: {unresolved}")
                unresolved_pool[unresolved] = message or "Motivo desconhecido"

            for chapter_obj, original_idx, canonical_label in chapters_to_retry_info:
                attempts_used[canonical_label] = attempts_used.get(canonical_label, 1) + 1
                if canonical_label in normalised_retry:
                    pending_failures[canonical_label] = normalised_retry[canonical_label]
                else:
                    if canonical_label in pending_failures:
                        print(f"✅ Capítulo recuperado: {canonical_label}")
                    pending_failures.pop(canonical_label, None)

            retry_round += 1

        if pending_failures:
            print(f"\n⚠️ Alguns capítulos ainda falharam após {max_retry_rounds} tentativa(s).")
        elif attempts_used and any(attempts > 1 for attempts in attempts_used.values()):
            print("\n✅ Todos os capítulos foram convertidos após tentativas adicionais.")

        unique_outputs: List[Path] = []
        seen_outputs = set()
        for path in total_output_files:
            key = str(path)
            if key in seen_outputs:
                continue
            seen_outputs.add(key)
            unique_outputs.append(path)

        result.output_files = unique_outputs
        result.converted_chapters = len(unique_outputs)

        if pending_failures:
            ordered_errors = []
            for name, message in pending_failures.items():
                entry = self._lookup_chapter_entry(chapter_lookup, name)
                idx = entry[1] if entry else total_chapters + 1
                ordered_errors.append((idx, name, message))
            ordered_errors.sort(key=lambda item: item[0])
            result.errors = [
                f"{name}: {message} (tentativas: {attempts_used.get(name, 'n/d')})" if message else f"{name} (tentativas: {attempts_used.get(name, 'n/d')})"
                for _, name, message in ordered_errors
            ]
        else:
            result.errors = []

        if unresolved_pool:
            for name, message in unresolved_pool.items():
                result.errors.append(f"{name}: {message} (não correlacionado)")

        result.success = not pending_failures and not unresolved_pool

        # Move files from temp to final output directory only if conversion was successful
        if result.success and result.converted_chapters > 0:
            if self.verbose:
                print(f"🔍 [VERBOSE] Movendo {len(result.output_files)} arquivos para diretório final...")

            moved_files = self.file_manager.move_files_to_final_output(temp_dir, output_dir)
            result.output_files = moved_files

            if moved_files:
                print(f"📁 {len(moved_files)} arquivos movidos para: {output_dir}")
                album_name = book_title or (self._current_book_path.stem if self._current_book_path else output_dir.name)
                self._apply_final_id3_tags(
                    moved_files,
                    default_album=album_name,
                    artist=book_author or None,
                    cover_art=cover_art,
                )

            self._cleanup_temp_audio(temp_dir)
        else:
            print("❌ Conversão falhou - arquivos temporários mantidos para debug")

        await self._stop_health_watchdog()
        self.progress.finish()
        self._report_results(result)
        return result

    def _setup_output_directory(self, config: ConversionConfig) -> Path:
        base_dir = Path(config.output_dir)
        if config.book_title:
            base_dir = base_dir / self.file_manager.sanitize_filename(config.book_title)
        engine_suffix = self._build_engine_signature(config)
        base_dir = base_dir / engine_suffix
        return self.file_manager.ensure_directory(base_dir)

    def _setup_temp_directory(self, config: ConversionConfig) -> Path:
        """Setup temporary directory for conversion files"""
        custom_cache = getattr(config, "cache_dir", None)
        if custom_cache:
            base_cache = Path(custom_cache)
        else:
            try:
                base_cache = resolve_cache_root()
                if config.book_title:
                    safe_title = self.file_manager.sanitize_filename(config.book_title)
                    base_cache = base_cache / safe_title
                else:
                    base_cache = base_cache / "conversion"
            except (RuntimeError, OSError) as e:
                # Fallback para diretório temporário do sistema
                import tempfile
                print(f"⚠️ Cache indisponível: {e}")
                print("💡 Usando diretório temporário do sistema")
                base_cache = Path(tempfile.mkdtemp(prefix="epub_to_mp3_"))

        engine_suffix = self._build_engine_signature(config)
        temp_dir = self.file_manager.ensure_directory(base_cache / engine_suffix)
        config.cache_dir = temp_dir
        return temp_dir

    def _build_engine_signature(self, config: ConversionConfig) -> str:
        voice = getattr(config, "voice", None)
        model_path = getattr(config, "model_path", None)
        fallback_voice = None
        if not voice and config.language_voices:
            fallback_voice = next(iter(config.language_voices.values()), None)
        return self.file_manager.build_engine_voice_suffix(
            engine=getattr(config, "engine", None),
            voice=voice,
            model_path=model_path,
            fallback_voice=fallback_voice,
        )


    async def _convert_chapters_parallel(
        self,
        chapters: Iterable[Chapter],
        tts_engine,
        output_dir: Path,
        config: ConversionConfig,
        max_concurrent_chapters: int = 3,
        *,
        is_auto_engine: bool = False,
        auto_engine_pool: Optional[Dict[str, tuple[ConversionConfig, object]]] = None,
    ) -> ConversionResult:
        """Converte múltiplos capítulos em paralelo para máxima velocidade."""
        chapters_list = list(chapters)
        if not chapters_list:
            return ConversionResult(True, 0, 0, [], [])

        total_chapters = len(chapters_list)
        recommended = max(1, int(max_concurrent_chapters or 1))
        self._parallel_state.setdefault("ceiling", recommended)
        self._parallel_state["ceiling"] = recommended
        self._parallel_state["current"] = max(1, min(recommended, int(self._parallel_state.get("current") or recommended)))
        print(f"🚀 Modo paralelo: processando {total_chapters} capítulos (atual {self._parallel_state['current']} simultâneos)")

        # Validate and clean cache (once for all chapters)
        self._validate_and_clean_cache(chapters_list, output_dir, config)

        # Generate all text files (once for all chapters)
        self._generate_all_text_files(chapters_list, output_dir, config)

        all_converted_files: List[Path] = []
        all_errors: List[str] = []
        converted_total = 0
        idx = 0
        batch_index = 0

        while idx < total_chapters:
            desired = int(self._parallel_state.get("current", recommended) or recommended)
            remaining = total_chapters - idx
            current_parallel = max(1, min(desired, remaining))
            batch = chapters_list[idx: idx + current_parallel]
            idx += len(batch)
            batch_index += 1
            print(f"📦 Batch {batch_index}: {len(batch)} capítulo(s) em paralelo (meta {current_parallel})")

            tasks = []
            for chapter in batch:
                task = self._convert_chapters_sequential(
                    [chapter],
                    tts_engine,
                    output_dir,
                    config,
                    is_auto_engine=is_auto_engine,
                    auto_engine_pool=auto_engine_pool,
                )
                tasks.append(task)

            # Wait for all chapters in this batch to complete
            batch_start = time.time()
            results = await asyncio.gather(*tasks, return_exceptions=True)
            batch_elapsed = max(time.time() - batch_start, 0.001)

            batch_errors = 0
            batch_chars = sum(self._estimate_chapter_chars(chapter) for chapter in batch)

            for result in results:
                if isinstance(result, Exception):
                    all_errors.append(str(result))
                    batch_errors += 1
                elif isinstance(result, ConversionResult):
                    all_converted_files.extend(result.output_files)
                    all_errors.extend(result.errors)
                    converted_total += result.converted_chapters
                    batch_errors += len(result.errors)

            batch_throughput = (batch_chars / batch_elapsed) if batch_chars else None
            if batch_throughput and self.verbose:
                print(f"   📈 Batch {batch_index}: ~{int(batch_throughput)} chars/s ({int(batch_elapsed)}s)")

            if idx < total_chapters:
                next_parallel, reason = self._auto_tune_parallelism(
                    throughput=batch_throughput,
                    batch_errors=batch_errors,
                )
                self._parallel_state["current"] = next_parallel
                if reason:
                    print(f"🧠 Auto-tune: {reason}")
                else:
                    print(f"🧠 Ajuste automático mantém {next_parallel} capítulo(s) simultâneos")

        return ConversionResult(
            success=len(all_errors) == 0,
            total_chapters=total_chapters,
            converted_chapters=converted_total or len(all_converted_files),
            output_files=all_converted_files,
            errors=all_errors,
        )

    async def _convert_chapters_sequential(
        self,
        chapters: Iterable[Chapter],
        tts_engine,
        output_dir: Path,
        config: ConversionConfig,
        *,
        is_auto_engine: bool = False,
        auto_engine_pool: Optional[Dict[str, tuple[ConversionConfig, object]]] = None,
    ) -> ConversionResult:
        """Converte capítulos sequencialmente, SEM sistema de paralelismo."""
        chapters_list = list(chapters)
        if not chapters_list:
            return ConversionResult(True, 0, 0, [], [])

        print(f"🔄 Modo sequencial: processando {len(chapters_list)} capítulos")

        # **NEW**: Check for cache invalidation BEFORE generating text files
        # If MP3 exists but pre-tts.txt doesn't, delete MP3 (cache invalidated)
        self._validate_and_clean_cache(chapters_list, output_dir, config)

        # **NEW**: Generate ALL text files BEFORE starting conversion
        self._generate_all_text_files(chapters_list, output_dir, config)

        converted_files: List[Path] = []
        errors: List[str] = []
        cooldown_pattern = re.compile(r"cooldown\\s+(\\d+)s", re.IGNORECASE)

        edge_unavailable_hits = 0
        auto_engine_pool = auto_engine_pool or {}

        def can_use_piper() -> bool:
            return shutil.which("piper") is not None

        def build_best_offline_engine(
            reason: Optional[str] = None,
            *,
            tracker: Optional[dict] = None,
            engine_ref: Optional[dict] = None,
        ) -> bool:
            if is_auto_engine:
                return False

            nonlocal tts_engine, config
            if config.engine.lower() != "edge":
                return False

            try:
                coqui_config = replace(config, engine="coqui", voice=None, model_path=None)
                coqui_config.voice = (
                    self.tts_factory.voice_provider.get_voice("coqui", coqui_config.primary_language)
                    or "tts_models/multilingual/multi-dataset/xtts_v2"
                )
                coqui_config.language_voices = self.tts_factory.voice_provider.build_language_voice_map(
                    "coqui",
                    coqui_config.languages
                    or ([coqui_config.primary_language] if coqui_config.primary_language != "auto" else []),
                    coqui_config.voice,
                    primary_language=coqui_config.primary_language,
                )
                tts_engine = self.tts_factory.create_engine(coqui_config)
                config = coqui_config
                if tracker is not None:
                    tracker["label"] = (config.engine or "").lower()
                if engine_ref is not None:
                    engine_ref["object"] = tts_engine
                if reason:
                    print(f"⚡ {reason} → migrando para XTTS (Coqui, offline)")
                else:
                    print("🔁 Fallback automático: Edge indisponível → XTTS (Coqui, offline)")
                return True
            except ImportError:
                if self.verbose:
                    print("   ⚠️ XTTS indisponível (pacote TTS não instalado)")
            except Exception as exc:
                if self.verbose:
                    print(f"   ⚠️ Fallback para XTTS falhou: {exc}")

            if can_use_piper():
                try:
                    piper_config = replace(config, engine="piper", voice=None, model_path=None)
                    piper_config.voice = self.tts_factory.voice_provider.get_voice("piper", piper_config.primary_language)
                    piper_config.language_voices = self.tts_factory.voice_provider.build_language_voice_map(
                        "piper",
                        piper_config.languages
                        or ([piper_config.primary_language] if piper_config.primary_language != "auto" else []),
                        piper_config.voice,
                        primary_language=piper_config.primary_language,
                    )
                    tts_engine = self.tts_factory.create_engine(piper_config)
                    config = piper_config
                    if tracker is not None:
                        tracker["label"] = (config.engine or "").lower()
                    if engine_ref is not None:
                        engine_ref["object"] = tts_engine
                    if reason:
                        print(f"⚡ {reason} → migrando para Piper (offline)")
                    else:
                        print("🔁 Fallback automático: Edge indisponível → Piper (offline)")
                    return True
                except Exception as exc:
                    if self.verbose:
                        print(f"   ⚠️ Fallback para Piper falhou: {exc}")

            return False

        if (config.engine or "").lower() == "edge" and not is_auto_engine and hasattr(tts_engine, "_probe_edge_health"):
            try:
                voice = getattr(tts_engine, "voice", None)
                healthy = await tts_engine._probe_edge_health(voice)  # type: ignore[attr-defined]
                if not healthy and build_best_offline_engine("Edge indisponível no health-check"):
                    if self.verbose:
                        print("   ⚠️ Edge pré-check falhou; usando engine offline antes de iniciar capítulos")
            except Exception:
                pass

        if is_auto_engine:
            async def wait_edge_cooldown_if_needed(
                context: str,
                tracker: Optional[dict] = None,
                engine_ref: Optional[dict] = None,
            ) -> bool:
                return False
        else:
            async def wait_edge_cooldown_if_needed(
                context: str,
                tracker: Optional[dict] = None,
                engine_ref: Optional[dict] = None,
            ) -> bool:
                """
                Handle Edge outages aggressively:
                  - On `NoAudioReceived` or `service_unavailable`, switch to offline (XTTS → Piper) immediately.
                  - If offline engine cannot be created, wait a short cooldown before retrying Edge.
                """
                if (config.engine or "").lower() != "edge":
                    return False
                last_error = getattr(tts_engine, "last_error", None)
                if not last_error:
                    return False

                error_text = str(last_error)
                lower_error = error_text.lower()
                should_switch = (
                    "service_unavailable" in lower_error
                    or "no_audio_payload" in lower_error
                )
                if not should_switch:
                    return False

                match = cooldown_pattern.search(str(last_error))
                seconds = int(match.group(1)) if match else 0
                if seconds <= 0:
                    seconds = 45
                if self.verbose:
                    print(f"   ⚠️ Edge indisponível ({context}) - erro: {last_error}")
                nonlocal edge_unavailable_hits
                edge_unavailable_hits += 1

                if build_best_offline_engine(
                    f"Edge indisponível ({context})",
                    tracker=tracker,
                    engine_ref=engine_ref,
                ):
                    return True

                max_wait = min(seconds, 90)
                if self.verbose:
                    print(f"   ⏳ Sem fallback disponível; aguardando {max_wait}s antes de tentar novamente...")
                waited = 0
                while waited < max_wait:
                    chunk = min(3, max_wait - waited)
                    await asyncio.sleep(chunk)
                    waited += chunk
                    self.progress.tick(f"⏳ Edge indisponível - aguardando {max_wait - waited}s...")
                return True

        def _resolve_tts_output_path(final_mp3_path: Path, engine_name: Optional[str] = None) -> tuple[Path, bool]:
            engine = (engine_name or config.engine or "").lower()
            if engine in {"piper", "coqui"}:
                return final_mp3_path.with_suffix(".wav"), True
            return final_mp3_path, False

        for idx, chapter in enumerate(chapters_list):
            chapter_num = idx + 1
            start_time = time.time()

            # **RESTORED**: Usar progress tracker
            self.progress.start_chapter(chapter.name, chapter_num)
            chapter_label = self._chapter_display_name(chapter, chapter_num)
            speech_text = self._speech_text(chapter)
            current_payload: Optional[str] = speech_text
            chapter_chars = len(speech_text or "")
            chapter_success = False
            chapter_error: Optional[str] = None
            chapter_cached = False
            engine_tracker = {"label": (config.engine or "").lower()}
            engine_instance = {"object": tts_engine}

            try:
                # Conversão para diretório temporário
                output_path = self.file_manager.get_temp_output_path(chapter.name, output_dir, idx + 1)

                # Check if MP3 already exists and is valid (size > 1KB)
                # Note: Cache validation already done by _validate_and_clean_cache()
                if output_path.exists() and not config.force_reprocess:
                    file_size = output_path.stat().st_size
                    if file_size > 1000:  # Mínimo 1KB para áudio válido
                        cached_payload = self._load_cached_payload(chapter, chapter_num, output_dir) or self._speech_text(chapter)
                        truncation_warning = self._detect_short_audio_output(output_path, cached_payload, config)
                        if truncation_warning:
                            if self.verbose:
                                print(f"   ⚠️ Cache inválido detectado: {truncation_warning}")
                            output_path.unlink(missing_ok=True)
                        else:
                            converted_files.append(output_path)
                            chapter_success = True
                            chapter_cached = True
                            self.progress.tick(f"✅ Arquivo já existe ({file_size} bytes)")
                            self.progress.complete_chapter("✅ Completo (cache)")
                            self._retry_original_texts.pop(chapter_label, None)
                            continue
                    else:
                        # Arquivo vazio ou corrompido - remover e reconverter
                        if self.verbose:
                            print(f"   🗑️ Removendo arquivo inválido ({file_size} bytes): {output_path}")
                        output_path.unlink(missing_ok=True)
                        output_path.with_suffix(".wav").unlink(missing_ok=True)

                # Sintetizar com heartbeat e timeout (otimizado)
                speech_text = speech_text or ""
                preview = self._chapter_preview(speech_text)
                if preview:
                    print(f"   📝 Trecho inicial: {preview}")
                current_payload = speech_text
                estimated_seconds = TextValidator.estimate_duration(speech_text)
                if estimated_seconds <= 0:
                    estimated_seconds = max(chapter_chars / 15.0, 30.0)
                switched_for_size = False
                auto_order: Optional[List[str]] = None
                attempted_auto: Set[str] = set()
                if is_auto_engine:
                    picked_engine, auto_order = self._pick_auto_engine(chapter_chars, estimated_seconds, auto_engine_pool)
                    attempted_auto.add(picked_engine)
                    engine_tracker["label"] = picked_engine
                    engine_instance["object"] = auto_engine_pool[picked_engine][1]
                    # Record engine selection for future ranking
                    if not self.speed_controller._current_engine:
                        self.speed_controller.record_engine_switch(picked_engine)
                else:
                    engine_tracker["label"] = (config.engine or "").lower()
                    engine_instance["object"] = tts_engine

                current_engine_label = engine_tracker.get("label") or (config.engine or "").lower()
                tts_engine = engine_instance["object"]
                if tts_engine is None:
                    raise RuntimeError("Nenhuma engine TTS disponível")

                tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(output_path, current_engine_label)

                if (config.engine or "").lower() == "edge" and not is_auto_engine:
                    threshold_chars = max(getattr(config, "edge_auto_offline_chars", 0), 0)
                    threshold_seconds = max(getattr(config, "edge_auto_offline_seconds", 0), 0)
                    edge_reason = None
                    if threshold_chars and chapter_chars >= threshold_chars:
                        edge_reason = f"Capítulo muito grande ({chapter_chars} caracteres)"
                    elif threshold_seconds and estimated_seconds >= threshold_seconds:
                        edge_reason = f"Capítulo estimado em {int(estimated_seconds)}s"
                    if edge_reason and build_best_offline_engine(
                        edge_reason,
                        tracker=engine_tracker,
                        engine_ref=engine_instance,
                    ):
                        switched_for_size = True
                        current_engine_label = engine_tracker.get("label") or (config.engine or "").lower()
                        tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(output_path, current_engine_label)

                decision = self.speed_controller.before_chapter(
                    engine_tracker["label"],
                    chapter_index=chapter_num,
                    chapter_name=chapter_label,
                    chapter_chars=chapter_chars,
                    tts_engine=engine_instance["object"],
                    config=config,
                    verbose=self.verbose,
                )
                if decision.message:
                    print(decision.message)

                # Timeout otimizado: mais agressivo para falhar rápido
                # Base: duração estimada * 1.5 + 30s buffer
                base_timeout = estimated_seconds * 1.5 + 30.0
                timeout_seconds = max(base_timeout, 60.0)  # Mínimo 60s
                timeout_seconds = min(timeout_seconds, 600.0)  # Máximo 10 min
                if decision.timeout_scale:
                    timeout_seconds = timeout_seconds * decision.timeout_scale
                timeout_seconds = int(timeout_seconds)

                if self.verbose:
                    print(f"🎤 [{chapter_num}/{len(chapters_list)}] {chapter.name}: Iniciando síntese TTS")
                    print(f"   📝 Texto: {chapter_chars} caracteres (timeout: {timeout_seconds}s)")

                self.progress.tick(f"🎤 Sintetizando {chapter_chars} chars (timeout: {timeout_seconds}s)...")

                # Heartbeat para mostrar progresso (otimizado: 3s em vez de 1s)
                heartbeat_active = True
                start_synthesis = time.time()

                async def synthesis_heartbeat():
                    spinner_frames = ["⚙️", "🔧"]
                    frame_idx = 0
                    while heartbeat_active:
                        await asyncio.sleep(3)  # Atualizar a cada 3 segundos (reduz overhead)
                        if not heartbeat_active:
                            break
                        elapsed = int(time.time() - start_synthesis)
                        frame = spinner_frames[frame_idx % len(spinner_frames)]
                        self.progress.tick(f"{frame} Sintetizando... {elapsed}s/{timeout_seconds}s ({chapter_chars} chars)")
                        frame_idx += 1

                heartbeat_task = asyncio.create_task(synthesis_heartbeat())

                try:
                    if self.verbose:
                        print(f"   🔄 Executando comando TTS: {type(tts_engine).__name__}")

                    synthesis_result = None
                    max_attempts = 1 if (config.engine or "").lower() == "edge" else 2
                    last_tts_output_path = tts_output_path
                    last_needs_transcode = needs_mp3_transcode
                    for attempt in range(max_attempts):
                        current_engine_label = engine_tracker.get("label") or (config.engine or "").lower()
                        tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(output_path, current_engine_label)
                        last_tts_output_path = tts_output_path
                        last_needs_transcode = needs_mp3_transcode
                        synthesis_result = await asyncio.wait_for(
                            tts_engine.synthesize_async(
                                speech_text,
                                tts_output_path,
                                formatting_segments=getattr(chapter, 'formatting_segments', None)
                            ),
                            timeout=timeout_seconds
                        )
                        if synthesis_result:
                            break
                        waited = await wait_edge_cooldown_if_needed(
                            f"tentativa {attempt + 1}/{max_attempts}",
                            tracker=engine_tracker,
                            engine_ref=engine_instance,
                        )
                        if not waited:
                            break

                    if synthesis_result and last_needs_transcode:
                        if self.verbose:
                            print(f"🔍 [VERBOSE] Convertendo WAV→MP3: {last_tts_output_path.name} → {output_path.name} (bitrate={config.bitrate})")
                        converted = await self.audio_processor.convert_to_mp3(
                            last_tts_output_path,
                            output_path,
                            bitrate=config.bitrate,
                        )
                        if self.verbose and converted is None:
                            print("🔍 [VERBOSE] Falha ao converter WAV→MP3 (ffmpeg)")
                        synthesis_result = converted
                        with contextlib.suppress(OSError):
                            last_tts_output_path.unlink(missing_ok=True)

                    if self.verbose and synthesis_result:
                        print(f"   ✅ TTS concluído: {output_path.name}")
                except asyncio.TimeoutError:
                    elapsed = int(time.time() - start_synthesis)
                    if self.verbose:
                        print(f"   ⚠️ TIMEOUT: Capítulo travado após {elapsed}s")
                    self.progress.tick(f"⚠️ TIMEOUT após {elapsed}s - tentando fallback sem idioma...")

                    # **FALLBACK**: Remover marcação de idioma e tentar novamente
                    try:
                        from ..language import LanguageMarkup
                        base_text = self._speech_text(chapter)
                        clean_text = LanguageMarkup.strip(base_text) if LanguageMarkup else base_text
                        current_payload = clean_text
                        clean_chars = len(clean_text)
                        fallback_timeout = timeout_seconds // 2

                        if self.verbose:
                            print(f"   🔄 RETRY: Tentando novamente sem marcas de idioma")
                            print(f"   📝 RETRY: {clean_chars} chars (timeout: {fallback_timeout}s)")

                        self.progress.tick(f"🔄 Fallback: {clean_chars} chars (timeout: {fallback_timeout}s)")

                        # Heartbeat para fallback (otimizado: 3s)
                        heartbeat_active = True
                        start_fallback = time.time()

                        async def fallback_heartbeat():
                            spinner_frames = ["🚑", "🔥"]
                            frame_idx = 0
                            while heartbeat_active:
                                await asyncio.sleep(3)
                                if not heartbeat_active:
                                    break
                                elapsed_fb = int(time.time() - start_fallback)
                                frame = spinner_frames[frame_idx % len(spinner_frames)]
                                self.progress.tick(f"{frame} FALLBACK {elapsed_fb}s/{fallback_timeout}s")
                                frame_idx += 1

                        fallback_task = asyncio.create_task(fallback_heartbeat())

                        try:
                            current_engine_label = engine_tracker.get("label") or (config.engine or "").lower()
                            tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(output_path, current_engine_label)
                            synthesis_result = await asyncio.wait_for(
                                tts_engine.synthesize_async(clean_text, tts_output_path, formatting_segments=None),
                                timeout=fallback_timeout
                            )
                            if synthesis_result and needs_mp3_transcode:
                                if self.verbose:
                                    print(f"🔍 [VERBOSE] Convertendo WAV→MP3 (fallback): {tts_output_path.name} → {output_path.name} (bitrate={config.bitrate})")
                                converted = await self.audio_processor.convert_to_mp3(
                                    tts_output_path,
                                    output_path,
                                    bitrate=config.bitrate,
                                )
                                if self.verbose and converted is None:
                                    print("🔍 [VERBOSE] Falha ao converter WAV→MP3 (fallback)")
                                synthesis_result = converted
                                with contextlib.suppress(OSError):
                                    tts_output_path.unlink(missing_ok=True)
                            if self.verbose and synthesis_result:
                                print(f"   ✅ RETRY: Sucesso no fallback!")
                        finally:
                            heartbeat_active = False
                            fallback_task.cancel()
                            with contextlib.suppress(asyncio.CancelledError):
                                await fallback_task

                    except (ImportError, asyncio.TimeoutError):
                        total_elapsed = int(time.time() - start_synthesis)
                        if self.verbose:
                            print(f"   ⚠️ FALLBACK: Tentativa dupla falhou, tentando síntese simples")
                        self.progress.tick(f"🔄 Última tentativa: síntese simples...")

                        # **THIRD ATTEMPT**: Synthesis with minimal text processing
                        try:
                            # Get first 1000 chars as emergency fallback
                            emergency_text = (speech_text or "")[:1000].strip()
                            if emergency_text:
                                emergency_timeout = 30  # Short timeout for emergency
                                if self.verbose:
                                    print(f"   🚑 EMERGÊNCIA: {len(emergency_text)} chars (timeout: {emergency_timeout}s)")

                                current_engine_label = engine_tracker.get("label") or (config.engine or "").lower()
                                tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(output_path, current_engine_label)
                                synthesis_result = await asyncio.wait_for(
                                    tts_engine.synthesize_async(emergency_text, tts_output_path, formatting_segments=None),
                                    timeout=emergency_timeout
                                )
                                if synthesis_result and needs_mp3_transcode:
                                    if self.verbose:
                                        print(f"🔍 [VERBOSE] Convertendo WAV→MP3 (emergência): {tts_output_path.name} → {output_path.name} (bitrate={config.bitrate})")
                                    converted = await self.audio_processor.convert_to_mp3(
                                        tts_output_path,
                                        output_path,
                                        bitrate=config.bitrate,
                                    )
                                    if self.verbose and converted is None:
                                        print("🔍 [VERBOSE] Falha ao converter WAV→MP3 (emergência)")
                                    synthesis_result = converted
                                    with contextlib.suppress(OSError):
                                        tts_output_path.unlink(missing_ok=True)
                                if synthesis_result and self.verbose:
                                    print(f"   ✅ EMERGÊNCIA: Sucesso com texto reduzido!")
                            else:
                                synthesis_result = None
                        except Exception as final_e:
                            synthesis_result = None
                            if self.verbose:
                                print(f"   ❌ EMERGÊNCIA: Falhou - {final_e}")

                        if not synthesis_result:
                            total_elapsed = int(time.time() - start_synthesis)
                            error_msg = f"TIMEOUT TRIPLO após {total_elapsed}s - todas as tentativas falharam"
                            if self.verbose:
                                print(f"   ❌ ERRO FINAL: {error_msg}")
                            chapter_error = error_msg
                            errors.append(f"{chapter.name}: {error_msg}")
                            self.progress.complete_chapter(f"❌ {error_msg}")
                            continue  # **STILL CONTINUE** - never give up completely
                finally:
                    heartbeat_active = False
                    heartbeat_task.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await heartbeat_task

                if not synthesis_result and is_auto_engine and auto_order:
                    next_engine = self._next_auto_engine(auto_order, attempted_auto)
                    if next_engine:
                        attempted_auto.add(next_engine)
                        engine_tracker["label"] = next_engine
                        engine_instance["object"] = auto_engine_pool[next_engine][1]
                        tts_engine = engine_instance["object"]
                        if self.verbose:
                            print(f"   ⚡ AUTO: trocando para {next_engine} e tentando novamente")
                        tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(output_path, next_engine)
                        continue

                if synthesis_result and output_path.exists():
                    file_size = output_path.stat().st_size

                    # Validar que o arquivo tem tamanho mínimo (não está vazio/corrompido)
                    if file_size > 1000:  # Mínimo 1KB para áudio válido
                        truncation_warning = self._detect_short_audio_output(
                            output_path,
                            current_payload,
                            config,
                        )
                        if truncation_warning:
                            if self.verbose:
                                print(f"   ⚠️ {truncation_warning}")
                            if hasattr(tts_engine, "last_error"):
                                setattr(tts_engine, "last_error", "short_output")
                            output_path.unlink(missing_ok=True)
                            chapter_error = truncation_warning
                            errors.append(f"{chapter.name}: {truncation_warning}")
                            self.progress.complete_chapter(f"❌ {truncation_warning}")
                            continue

                        converted_files.append(output_path)
                        self._embed_id3_metadata(
                            output_path,
                            title=chapter_label,
                            album=book_title,
                            artist=book_author or None,
                            cover_art=cover_art,
                        )
                        chapter_success = True

                        if self.verbose:
                            print(f"   📊 Arquivo gerado: {file_size} bytes")
                        self.progress.complete_chapter(f"✅ Sucesso ({file_size} bytes)")
                        chapter_elapsed = time.time() - start_time
                        current_engine_label = engine_tracker.get("label") or (config.engine or "").lower()
                        if chapter_chars:
                            throughput = int(chapter_chars / max(chapter_elapsed, 0.001))
                        else:
                            throughput = 0
                        engine_display = (current_engine_label or "engine").upper()
                        print(
                            f"⏱️ [{engine_display}] Capítulo {chapter_num} → "
                            f"{chapter_elapsed:.1f}s para {chapter_chars} chars "
                            f"({throughput or '~0'} chars/s)"
                        )
                        if (
                            current_engine_label == "edge"
                            and not switched_for_size
                            and getattr(config, "edge_auto_offline_seconds", 0)
                        ):
                            slow_cutoff = max(getattr(config, "edge_auto_offline_seconds", 0), 0)
                            if slow_cutoff and chapter_elapsed >= slow_cutoff * 1.4:
                                if build_best_offline_engine(
                                    f"Edge levou {int(chapter_elapsed)}s para este capítulo"
                                ):
                                    if self.verbose:
                                        print("   ⚡ Próximos capítulos migrarão para engine offline pela performance")
                                current_engine_label = engine_tracker.get("label") or (config.engine or "").lower()
                                tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(output_path, current_engine_label)
                        self._retry_original_texts.pop(chapter_label, None)
                    else:
                        # Arquivo muito pequeno - provavelmente corrompido
                        if self.verbose:
                            print(f"   ⚠️ Arquivo muito pequeno ({file_size} bytes) - considerando falha")
                        output_path.unlink(missing_ok=True)
                        synthesis_result = None  # Forçar retry
                else:
                    # **RETRY**: Tentar com idioma padrão em caso de falha
                    if self.verbose:
                        print("   ⚠️ RETRY: Síntese falhou, tentando com idioma padrão")

                    try:
                        # If Edge is on cooldown, wait before retrying to avoid instant failures.
                        await wait_edge_cooldown_if_needed(
                            "antes do retry",
                            tracker=engine_tracker,
                            engine_ref=engine_instance,
                        )

                        # Use only the first part of text with default language
                        simple_text = (speech_text or "")[:2000].strip()
                        current_payload = simple_text
                        if simple_text:
                            self.progress.tick("🔄 Retry: texto simples (idioma padrão)...")
                            retry_timeout = 45

                            synthesis_result = None
                            for attempt in range(2):
                                synthesis_result = await asyncio.wait_for(
                                    tts_engine.synthesize_async(simple_text, output_path, formatting_segments=None),
                                    timeout=retry_timeout,
                                )
                                if synthesis_result:
                                    break
                                waited = await wait_edge_cooldown_if_needed(
                                    f"retry {attempt + 1}/2",
                                    tracker=engine_tracker,
                                    engine_ref=engine_instance,
                                )
                                if not waited:
                                    break

                            if synthesis_result and output_path.exists():
                                file_size = output_path.stat().st_size

                                # Validar tamanho mínimo
                                if file_size > 1000:
                                    truncation_warning = self._detect_short_audio_output(
                                        output_path,
                                        current_payload,
                                        config,
                                    )
                                    if truncation_warning:
                                        if self.verbose:
                                            print(f"   ⚠️ {truncation_warning}")
                                        if hasattr(tts_engine, "last_error"):
                                            setattr(tts_engine, "last_error", "short_output")
                                        output_path.unlink(missing_ok=True)
                                        chapter_error = truncation_warning
                                        errors.append(f"{chapter.name}: {truncation_warning}")
                                        self.progress.complete_chapter(f"❌ {truncation_warning}")
                                        continue

                                    converted_files.append(output_path)
                                    self._embed_id3_metadata(
                                        output_path,
                                        title=chapter_label,
                                        album=book_title,
                                        artist=book_author or None,
                                        cover_art=cover_art,
                                    )
                                    chapter_success = True

                                    if self.verbose:
                                        print(f"   ✅ RETRY: Sucesso com texto simplificado ({file_size} bytes)")
                                    self.progress.complete_chapter("✅ Sucesso (retry)")
                                    chapter_elapsed = time.time() - start_time
                                    current_engine_label = engine_tracker.get("label") or (config.engine or "").lower()
                                    if (
                                        current_engine_label == "edge"
                                        and not switched_for_size
                                        and getattr(config, "edge_auto_offline_seconds", 0)
                                    ):
                                        slow_cutoff = max(getattr(config, "edge_auto_offline_seconds", 0), 0)
                                        if slow_cutoff and chapter_elapsed >= slow_cutoff * 1.4:
                                            if build_best_offline_engine(
                                                f"Edge levou {int(chapter_elapsed)}s para este capítulo"
                                            ):
                                                if self.verbose:
                                                    print("   ⚡ Próximos capítulos migrarão para engine offline pela performance")
                                                current_engine_label = engine_tracker.get("label") or (config.engine or "").lower()
                                                tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(output_path, current_engine_label)
                                    self._retry_original_texts.pop(chapter_label, None)
                                    continue  # Success! Continue to next chapter

                                if self.verbose:
                                    print(f"   ⚠️ RETRY: Arquivo inválido ({file_size} bytes)")
                                output_path.unlink(missing_ok=True)
                    except Exception as retry_e:
                        if self.verbose:
                            print(f"   ❌ RETRY falhou: {retry_e}")

                    # If all retries failed
                    error_msg = f"Falha na síntese"
                    if hasattr(tts_engine, 'last_error') and tts_engine.last_error:
                        error_msg += f": {tts_engine.last_error}"
                    if self.verbose:
                        print(f"   ❌ ERRO FINAL: {error_msg}")
                    chapter_error = error_msg
                    errors.append(f"{chapter.name}: {error_msg}")
                    self.progress.complete_chapter(f"❌ {error_msg}")
                    # **CONTINUE** - never skip chapter, just mark as error

            except Exception as e:
                error_msg = f"Exceção: {str(e)}"
                if self.verbose:
                    print(f"   ❌ ERRO DE EXCEÇÃO: {error_msg}")
                chapter_error = error_msg
                errors.append(f"{chapter.name}: {error_msg}")
                self.progress.complete_chapter(f"❌ {error_msg}")
                # **CONTINUE** - log error but continue processing other chapters
            finally:
                elapsed = time.time() - start_time
                message = self.speed_controller.after_chapter(
                    engine_tracker.get("label") or (config.engine or "").lower(),
                    chapter_index=chapter_num,
                    chapter_name=chapter_label,
                    chapter_chars=chapter_chars,
                    elapsed=elapsed,
                    success=chapter_success,
                    error=chapter_error,
                    from_cache=chapter_cached,
                    tts_engine=engine_instance.get("object"),
                )
                if message:
                    print(message)
                self._mark_health_progress(chapter_num, chapter_success, elapsed, chapter_error)

        success = len(errors) == 0
        return ConversionResult(
            success=success,
            total_chapters=len(chapters_list),
            converted_chapters=len(converted_files),
            output_files=converted_files,
            errors=errors,
        )

    def _prepare_auto_engines(self, base_config: ConversionConfig) -> Dict[str, tuple[ConversionConfig, object]]:
        pool: Dict[str, tuple[ConversionConfig, object]] = {}
        for name in ("coqui", "edge", "piper"):
            try:
                cloned = replace(base_config, engine=name, voice=None, model_path=None)
                cloned.languages = list(base_config.languages)
                cloned.language_voices = {}
                voice = self.tts_factory.voice_provider.get_voice(name, cloned.primary_language)
                cloned.voice = voice
                cloned.language_voices = self.tts_factory.voice_provider.build_language_voice_map(
                    name,
                    cloned.languages
                    or ([cloned.primary_language] if cloned.primary_language and cloned.primary_language != "auto" else []),
                    voice,
                    primary_language=cloned.primary_language,
                )
                engine_instance = self.tts_factory.create_engine(cloned)
                pool[name] = (cloned, engine_instance)
            except Exception:
                continue
        return pool

    def _pick_auto_engine(
        self,
        chapter_chars: int,
        estimated_seconds: float,
        pool: Dict[str, tuple[ConversionConfig, object]],
    ) -> tuple[str, List[str]]:
        """
        Pick the best engine based on real-time performance data.

        Uses SpeedController's ranking system to choose the fastest engine.
        Falls back to static ordering if no performance data available.
        """
        available_engines = list(pool.keys())

        if not available_engines:
            return ("edge", [])

        # Get performance-based ranking from SpeedController
        rankings = self.speed_controller.get_engine_ranking(available_engines)

        if self.verbose and rankings:
            print(f"📊 Engine Rankings (based on recent performance):")
            for engine, score, reason in rankings:
                print(f"   {engine}: {score:.1f}/100 ({reason})")

        # Use ranked order (best first)
        order = [engine for engine, _, _ in rankings]

        # Fallback: if no ranking data, use static optimal order
        if not order:
            def append(order_list: List[str], candidate: str) -> None:
                if candidate in pool and candidate not in order_list:
                    order_list.append(candidate)

            order = []
            append(order, "edge")   # Fastest when healthy
            append(order, "piper")  # Good middle ground
            append(order, "coqui")  # Most reliable but slowest

        if "edge" in order:
            order = ["edge"] + [name for name in order if name != "edge"]

        selected = order[0]

        # Check if we should switch from current engine
        if hasattr(self.speed_controller, '_current_engine') and self.speed_controller._current_engine:
            current = self.speed_controller._current_engine
            if current in available_engines and current != selected:
                switch_recommendation = self.speed_controller.recommend_engine_switch(
                    current,
                    available_engines,
                    verbose=self.verbose
                )
                if switch_recommendation:
                    new_engine, reason = switch_recommendation
                    print(f"🔄 AUTO: Trocando {current} → {new_engine}")
                    print(f"   Motivo: {reason}")
                    selected = new_engine
                    self.speed_controller.record_engine_switch(new_engine)

        return selected, order

    @staticmethod
    def _next_auto_engine(order: List[str], attempted: Set[str]) -> Optional[str]:
        for name in order:
            if name not in attempted:
                return name
        return None

    @staticmethod
    def _chapter_preview(text: str, limit: int = 180) -> str:
        if not text:
            return ""
        preview = " ".join(text.split())
        if len(preview) > limit:
            preview = preview[:limit].rstrip() + "…"
        return preview

    def _prioritize_chapters(self, chapters: List[Chapter], selectors: List[str]) -> List[Chapter]:
        if not selectors:
            return chapters

        prioritized: List[Chapter] = []
        seen_indices: Set[int] = set()
        selectors_normalized = [str(sel).strip().lower() for sel in selectors if str(sel).strip()]

        for selector in selectors_normalized:
            numeric_target: Optional[int] = None
            if selector.replace(".", "", 1).isdigit():
                try:
                    numeric_target = int(float(selector))
                except ValueError:
                    numeric_target = None
            for idx, chapter in enumerate(chapters):
                if idx in seen_indices:
                    continue
                display_name = self._chapter_display_name(chapter, idx + 1).lower()
                if numeric_target is not None and (idx + 1) == numeric_target:
                    prioritized.append(chapter)
                    seen_indices.add(idx)
                    break
                if selector in display_name:
                    prioritized.append(chapter)
                    seen_indices.add(idx)
                    break

        if not prioritized:
            return chapters

        remaining = [chapter for idx, chapter in enumerate(chapters) if idx not in seen_indices]
        return prioritized + remaining


    def _install_requirements(self) -> bool:
        if self._requirements_attempted:
            return False
        self._requirements_attempted = True

        python_root = Path(__file__).resolve().parents[1]
        candidate_paths = [
            Path("requirements.txt"),
            Path.cwd() / "requirements.txt",
            python_root / "requirements.txt",
        ]
        requirements_path = next((path for path in candidate_paths if path.exists()), None)

        if requirements_path is None:
            print(self.loc.t("requirements_not_found"))
            return False

        print(self.loc.t("installing_requirements"))
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "-r", str(requirements_path)],
            check=False,
        )

        if result.returncode == 0:
            print(self.loc.t("requirements_success"))
            return True

        print(self.loc.t("requirements_failure"))
        return False

    async def _convert_single_chapter(
        self,
        semaphore: asyncio.Semaphore,
        chapter: Chapter,
        tts_engine,
        output_dir: Path,
        index: int,
        config: Optional[ConversionConfig] = None,
        progress: Optional[ProgressTracker] = None,
    ) -> ChapterConversionOutcome | Optional[Path]:
        legacy_mode = config is None and progress is None
        if config is None:
            config = ConversionConfig(engine="edge", output_dir=str(output_dir))
        if progress is None:
            progress = self.progress
        chapter_label = chapter.name or f"Chapter {index}"
        output_path = self.file_manager.get_temp_output_path(chapter_label, output_dir, index)
        cache_dir = getattr(config, "cache_dir", None)

        if output_path.exists() and not config.force_reprocess:
            progress.start_chapter(chapter_label, index)
            self._cache_audio(cache_dir, output_path, chapter, index, config)
            status = self.loc.t("status_cached")
            self._announce_stage(index, chapter_label, status)
            if getattr(config, "listen", False):
                progress.tick(self.loc.t("status_playing"))
                played = await self.audio_processor.play_audio(output_path)
                status = self.loc.t("status_complete") if played else self.loc.t("status_play_unavailable")
                self._announce_stage(index, chapter_label, status)
            progress.complete_chapter(status)
            outcome = ChapterConversionOutcome(index=index, name=chapter_label, path=output_path)
            return output_path if legacy_mode else outcome

        progress.start_chapter(chapter_label, index)
        status_holder = {"text": self.loc.t("status_waiting_slot")}
        self._announce_stage(index, chapter_label, status_holder["text"])
        heartbeat_stop = asyncio.Event()

        async def heartbeat():
            try:
                while not heartbeat_stop.is_set():
                    progress.tick(status_holder["text"])
                    await asyncio.sleep(1)
            except asyncio.CancelledError:
                pass

        heartbeat_task = asyncio.create_task(heartbeat())

        try:
            await semaphore.acquire()
            progress.mark_phase_start()
            status_holder["text"] = self.loc.t("status_preparing")
            self._announce_stage(index, chapter_label, status_holder["text"])
            try:
                if self.verbose:
                    chapter_text = chapter.text
                    text_info = f"None" if chapter_text is None else f"{len(chapter_text)} chars"
                    print(f"🔍 [VERBOSE] Chapter {index} text: {text_info}")
                    if chapter_text:
                        print(f"🔍 [VERBOSE] Chapter {index} preview: {str(chapter_text)[:100]}")

                if not TextValidator.is_valid_text(self._speech_text(chapter) or " "):
                    status_holder["text"] = self.loc.t("status_insufficient_text")
                    self._announce_stage(index, chapter_label, status_holder["text"])
                    outcome = ChapterConversionOutcome(
                        index=index,
                        name=chapter_label,
                        path=None,
                        error=status_holder["text"],
                    )
                    return None if legacy_mode else outcome

                try:
                    chunks = ChapterProcessor.chunk_text(self._speech_text(chapter) or "")
                    chapter_payload = "\n".join(chunks)
                    if self.verbose:
                        print(f"🔍 [VERBOSE] Chapter {index} chunks: {len(chunks)}, payload: {len(chapter_payload)} chars")


                except Exception as e:
                    if self.verbose:
                        print(f"🔍 [VERBOSE] Chapter {index} chunk_text error: {e}")
                    raise
                self._cache_text(cache_dir, chapter, index, chapter_payload)
                status_holder["text"] = self.loc.t("status_synthesizing")
                self._announce_stage(index, chapter_label, status_holder["text"])

                # **UPDATED**: Estratégia de fallback e timeouts baseados em duração estimada
                char_count = len(chapter_payload or "")
                lang_tag_count = chapter_payload.lower().count("[[lang:") if chapter_payload else 0

                use_immediate_fallback = lang_tag_count > 50 or (lang_tag_count > 20 and char_count > 15000)

                if use_immediate_fallback:
                    if self.verbose:
                        print(
                            f"🔍 [VERBOSE] Chapter {index} muito complexo "
                            f"({lang_tag_count} tags, {char_count} chars) - usando fallback imediato"
                        )
                    try:
                        from ..language import LanguageMarkup
                        simplified = LanguageMarkup.strip(chapter_payload) if LanguageMarkup else chapter_payload
                        if self.verbose:
                            print(
                                f"🔍 [VERBOSE] Chapter {index} FALLBACK IMEDIATO: "
                                f"{char_count} → {len(simplified)} chars"
                            )
                        status_holder["text"] = f"🔄 Fallback: removendo {lang_tag_count} tags de idioma"
                        self._announce_stage(index, chapter_label, status_holder["text"])
                        chapter_payload = simplified
                    except ImportError:
                        if self.verbose:
                            print(f"🔍 [VERBOSE] Chapter {index} FALLBACK: LanguageMarkup não disponível")

                # Recalcular métricas após fallback
                char_count = len(chapter_payload or "")
                lang_tag_count = chapter_payload.lower().count("[[lang:") if chapter_payload else 0
                estimated_seconds = TextValidator.estimate_duration(chapter_payload)
                if estimated_seconds <= 0:
                    estimated_seconds = max(char_count / 25.0, 45.0)

                if use_immediate_fallback or lang_tag_count > 10:
                    base_timeout = estimated_seconds * 1.4 + 45.0
                    minimum_timeout = 150.0
                else:
                    base_timeout = estimated_seconds * 1.25 + 30.0
                    minimum_timeout = 90.0

                chapter_timeout = max(base_timeout, minimum_timeout)
                chapter_timeout = min(chapter_timeout, 900.0)

                if self.verbose:
                    print(
                        f"🔍 [VERBOSE] Chapter {index} timeout: {chapter_timeout:.0f}s "
                        f"(estimado {estimated_seconds:.0f}s, {char_count} chars, {lang_tag_count} tags)"
                    )

                # Try synthesis (already with fallback applied for complex chapters)
                synthesis_task = None
                temp_wav = None
                max_attempts = 1 if use_immediate_fallback else 2
                attempt = 1

                while attempt <= max_attempts and temp_wav is None:
                    # On second attempt for non-complex chapters, apply fallback
                    if attempt == 2 and not use_immediate_fallback:
                        try:
                            from ..language import LanguageMarkup
                            simplified_payload = LanguageMarkup.strip(chapter_payload) if LanguageMarkup else chapter_payload
                            original_count = chapter_payload.lower().count("[[lang:")
                            if self.verbose:
                                print(f"🔍 [VERBOSE] Chapter {index} FALLBACK: removendo {original_count} tags [[lang:]]")
                                print(f"🔍 [VERBOSE] Chapter {index} FALLBACK: {len(chapter_payload)} → {len(simplified_payload)} chars")
                            status_holder["text"] = f"🔄 Tentativa 2: removendo {original_count} tags de idioma"
                            self._announce_stage(index, chapter_label, status_holder["text"])
                            chapter_payload = simplified_payload
                        except ImportError:
                            if self.verbose:
                                print(f"🔍 [VERBOSE] Chapter {index} FALLBACK: LanguageMarkup não disponível")

                    try:
                        if self.verbose:
                            print(f"🔍 [VERBOSE] Chapter {index} tentativa {attempt}/{max_attempts}")

                        # Pass formatting segments only on first attempt with original payload
                        speech_text = self._speech_text(chapter)
                        chapter_formatting = (
                            getattr(chapter, 'formatting_segments', None)
                            if attempt == 1 and chapter_payload == speech_text
                            else None
                        )
                        synthesis_task = asyncio.create_task(
                            tts_engine.synthesize_async(
                                chapter_payload,
                                output_path.with_suffix(".wav"),
                                formatting_segments=chapter_formatting
                            )
                        )
                        temp_wav = await asyncio.wait_for(synthesis_task, timeout=chapter_timeout)

                        if temp_wav and (attempt == 2 or use_immediate_fallback):
                            if self.verbose:
                                print(f"🔍 [VERBOSE] Chapter {index} SUCESSO no fallback!")

                    except asyncio.TimeoutError:
                        if self.verbose:
                            print(f"🔍 [VERBOSE] Chapter {index} tentativa {attempt} timeout após {chapter_timeout}s")
                        if synthesis_task and not synthesis_task.done():
                            synthesis_task.cancel()
                            try:
                                await synthesis_task
                            except asyncio.CancelledError:
                                pass

                        if attempt == max_attempts:
                            temp_wav = None
                            if hasattr(tts_engine, 'last_error'):
                                tts_engine.last_error = "timeout_final"

                    except Exception as e:
                        if legacy_mode:
                            raise
                        if self.verbose:
                            print(f"🔍 [VERBOSE] Chapter {index} tentativa {attempt} erro: {e}")
                        if synthesis_task and not synthesis_task.done():
                            synthesis_task.cancel()

                        if attempt == max_attempts:
                            temp_wav = None
                            if hasattr(tts_engine, 'last_error'):
                                tts_engine.last_error = f"error: {e}"

                    attempt += 1

                if not temp_wav:
                    status_holder["text"] = self.loc.t("status_synthesis_failed")
                    last_error = getattr(tts_engine, "last_error", None)
                    detail = (
                        self.loc.t("status_synthesis_failed_detail", error=last_error)
                        if last_error
                        else status_holder["text"]
                    )
                    status_holder["text"] = detail
                    self._announce_stage(index, chapter_label, detail)
                    outcome = ChapterConversionOutcome(
                        index=index,
                        name=chapter_label,
                        path=None,
                        error=detail,
                        slowdown=self._should_flag_slowdown(last_error),
                    )
                    return None if legacy_mode else outcome

                status_holder["text"] = self.loc.t("status_convert_mp3")
                self._announce_stage(index, chapter_label, status_holder["text"])
                converted = await self.audio_processor.convert_to_mp3(
                    temp_wav, output_path, bitrate=config.bitrate
                )
                if converted is None:
                    status_holder["text"] = self.loc.t("status_mp3_failed")
                    self._announce_stage(index, chapter_label, status_holder["text"])
                    outcome = ChapterConversionOutcome(
                        index=index,
                        name=chapter_label,
                        path=None,
                        error=status_holder["text"],
                    )
                    return None if legacy_mode else outcome

                try:
                    file_size = converted.stat().st_size
                except OSError:
                    file_size = 0
                truncation_warning = self._detect_short_audio_output(
                    converted,
                    chapter_payload,
                    config,
                )
                if truncation_warning:
                    if self.verbose:
                        print(f"   ⚠️ {truncation_warning}")
                    try:
                        converted.unlink(missing_ok=True)
                    except OSError:
                        pass
                    status_holder["text"] = truncation_warning
                    self._announce_stage(index, chapter_label, status_holder["text"])
                    outcome = ChapterConversionOutcome(
                        index=index,
                        name=chapter_label,
                        path=None,
                        error=status_holder["text"],
                    )
                    return None if legacy_mode else outcome

                try:
                    if temp_wav.exists():
                        temp_wav.unlink()
                except OSError:
                    pass

                status_holder["text"] = self.loc.t("status_complete")
                self._announce_stage(index, chapter_label, status_holder["text"])
                if getattr(config, "listen", False):
                    status_holder["text"] = self.loc.t("status_playing")
                    self._announce_stage(index, chapter_label, status_holder["text"])
                    played = await self.audio_processor.play_audio(converted)
                    status_holder["text"] = self.loc.t("status_complete") if played else self.loc.t("status_play_unavailable")
                    self._announce_stage(index, chapter_label, status_holder["text"])
                self._cache_audio(cache_dir, converted, chapter, index, config)
                outcome = ChapterConversionOutcome(index=index, name=chapter_label, path=converted)
                return converted if legacy_mode else outcome
            finally:
                semaphore.release()
        except Exception as exc:
            if self.verbose:
                print(f"🔍 [VERBOSE] Chapter {index} exception: {type(exc).__name__}: {exc}")
                import traceback
                traceback.print_exc()
            if not status_holder["text"].startswith("❌"):
                status_holder["text"] = self.loc.t("status_internal_error")
                self._announce_stage(index, chapter_label, status_holder["text"])
            if legacy_mode:
                raise
            raise RuntimeError(f"chapter conversion failed: {type(exc).__name__}: {exc}") from exc
        finally:
            heartbeat_stop.set()
            heartbeat_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await heartbeat_task
            progress.complete_chapter(status_holder["text"])

    def _report_results(self, result: ConversionResult) -> None:
        print(self.loc.t("conversion_results_title"))
        print(self.loc.t("conversion_results_success", converted=result.converted_chapters, total=result.total_chapters))
        print(self.loc.t("conversion_results_files", files=len(result.output_files)))
        if result.errors:
            print(self.loc.t("conversion_results_errors", errors=len(result.errors)))
            for error in result.errors[:3]:
                print(f"    • {error}")

    def _cleanup_temp_audio(self, temp_dir: Path) -> None:
        temp_dir = Path(temp_dir)
        if not temp_dir.exists():
            return

        patterns = ("*.mp3", "*.wav", "*.ogg")
        for pattern in patterns:
            for candidate in temp_dir.glob(pattern):
                try:
                    candidate.unlink()
                except FileNotFoundError:
                    continue
                except OSError:
                    if self.verbose:
                        print(f"⚠️ Não foi possível remover arquivo temporário: {candidate}")

        audio_cache = temp_dir / "audio"
        if audio_cache.exists():
            try:
                shutil.rmtree(audio_cache, ignore_errors=True)
            except OSError:
                if self.verbose:
                    print(f"⚠️ Não foi possível limpar cache de áudio: {audio_cache}")

    @staticmethod
    def _cache_audio(
        cache_dir: Optional[Path],
        audio_path: Path,
        chapter: Chapter,
        index: int,
        config: ConversionConfig,
    ) -> None:
        if not cache_dir:
            return
        try:
            cache_dir = Path(cache_dir)
            model_bucket = AudioConverter._cache_model_bucket(config)
            target_dir = cache_dir / "audio"
            if model_bucket:
                target_dir /= model_bucket
            target_dir.mkdir(parents=True, exist_ok=True)
            chapter_name = getattr(chapter, "name", None) or f"Chapter {index}"
            safe_name = FileManager.sanitize_filename(chapter_name)
            target_path = target_dir / f"{index:03d}_{safe_name}.mp3"
            if not target_path.exists() or target_path.stat().st_mtime < audio_path.stat().st_mtime:
                shutil.copy2(audio_path, target_path)
        except OSError:
            pass

    @staticmethod
    def _cache_model_bucket(config: ConversionConfig) -> Optional[str]:
        engine = (getattr(config, "engine", "") or "unknown").lower()
        parts = [engine]

        voice = getattr(config, "voice", None)
        model_path = getattr(config, "model_path", None)

        if engine == "piper" and model_path:
            parts.append(Path(model_path).stem)
        elif engine == "coqui":
            if voice:
                parts.append(str(voice))
            elif model_path:
                parts.append(Path(model_path).stem)
        else:
            if voice:
                parts.append(str(voice))

        bucket_name = "__".join(part for part in parts if part)
        if not bucket_name:
            return None
        safe_bucket = FileManager.sanitize_filename(bucket_name, max_length=96)
        safe_bucket = safe_bucket.replace(" ", "_")
        return safe_bucket or None

    @staticmethod
    def _cache_text(
        cache_dir: Optional[Path],
        chapter: Chapter,
        index: int,
        text: str,
    ) -> None:
        if not cache_dir or not text:
            return
        try:
            cache_dir = Path(cache_dir)
            target_dir = cache_dir / "text"
            target_dir.mkdir(parents=True, exist_ok=True)
            chapter_name = getattr(chapter, "name", None) or f"Chapter {index}"
            safe_name = FileManager.sanitize_filename(chapter_name)
            safe_name = safe_name.replace(" ", "_")
            target_path = target_dir / f"{index:03d}_{safe_name}.txt"
            target_path.write_text(text, encoding="utf-8")
        except OSError:
            pass

    def _announce_stage(self, index: int, chapter_name: str, status: str) -> None:
        clean_status = status.strip()
        if not clean_status:
            return
        print(f"   → [{index}] {chapter_name}: {clean_status}", flush=True)

    @staticmethod
    def _should_reduce_parallel(outcome) -> bool:
        return isinstance(outcome, ChapterConversionOutcome) and bool(outcome.slowdown)

    @staticmethod
    def _should_flag_slowdown(error_msg: Optional[str]) -> bool:
        """Check if error indicates slowdown condition."""
        if not error_msg:
            return False
        try:
            error_lower = str(error_msg).lower()
        except Exception:
            return False
        return any(keyword in error_lower for keyword in ["timeout", "rate", "limit", "throttle", "quota"])


class ChapterProcessor:
    """Handles chapter-specific processing following SRP"""
    
    @staticmethod
    def chunk_text(text: str, max_size: int = 5000) -> List[str]:
        """Split text into manageable chunks for TTS engines."""
        if text is None:
            return [""]
        if len(text) <= max_size:
            return [text]

        import re

        sentence_splitter = re.compile(r"(?<=[.!?])\s+")
        sentences = sentence_splitter.split(text)
        chunks: List[str] = []
        current: List[str] = []
        current_len = 0

        for sentence in sentences:
            cleaned = sentence.strip()
            if not cleaned:
                continue
            if current_len + len(cleaned) + 1 > max_size and current:
                chunks.append(" ".join(current).strip())
                current = [cleaned]
                current_len = len(cleaned)
            else:
                current.append(cleaned)
                current_len += len(cleaned) + 1

        if current:
            chunks.append(" ".join(current).strip())

        return chunks or [text[:max_size]]
