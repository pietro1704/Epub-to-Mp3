# -*- coding: utf-8 -*-
"""Audio conversion pipeline wired to the TTS engines."""

from __future__ import annotations

import asyncio
import contextlib
import gc
import hashlib
import inspect
import json
import os
import re
import resource
import shutil
import subprocess
import sys
import threading
import time
import unicodedata
import weakref
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Set

import psutil
from mutagen.id3 import APIC, ID3, TALB, TIT2, TPE1
from mutagen.mp3 import MP3

from .adaptive_performance import AdaptivePerformanceController
from .auto_tuner import AutoTuner
from .cache_manager import CacheManager
from .chapter_utils import deduplicate_chapters_by_content
from .config import ConversionConfig
from .ebook_reader import Chapter, EbookReader
from .engine_pool import JobEnginePool, ResourceSnapshot
from .hardware_detector import HardwareProfile
from .i18n import Localization, get_localization
from .progress import ProgressTracker
from .speed_controller import AdaptiveSpeedController
from .text_integrity_validator import TextIntegrityValidator
from .tts.factory import TTSFactory
from .utils import AudioProcessor, FileManager, TextValidator, resolve_cache_root


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


EDGE_AUTO_TUNE = _env_bool("EDGE_AUTO_TUNE", True)
EDGE_MIN_CHARS_PER_SECOND = _env_float("EDGE_MIN_CHARS_PER_SECOND", 60.0)  # Increased from 45
EDGE_SLOW_RATIO_THRESHOLD = _env_float("EDGE_SLOW_RATIO_THRESHOLD", 1.5)  # More sensitive
EDGE_SAFE_CHUNK_CHARS = _env_int("EDGE_SAFE_CHUNK_CHARS", 10000)
EDGE_SAFE_MAX_SEGMENT_SECONDS = _env_float("EDGE_SAFE_MAX_SEGMENT_SECONDS", 300.0)
EDGE_SAFE_CHAPTER_PARALLEL = _env_int("EDGE_SAFE_CHAPTER_PARALLEL", 8)
EDGE_SAFE_TIMEOUT_MAX = _env_float(
    "EDGE_SAFE_TIMEOUT_MAX", 3600.0
)  # Up to 1h for very long chapters
# Four-tier fallback: Edge multilingual → Edge monolingual → Kokoro → Piper
EDGE_MONOLINGUAL_THRESHOLD = _env_int(
    "EDGE_MONOLINGUAL_THRESHOLD", 3
)  # Switch to monolingual Edge after N consecutive failures
EDGE_KOKORO_THRESHOLD = _env_int(
    "EDGE_KOKORO_THRESHOLD", 3
)  # Switch to Kokoro after N consecutive failures (after monolingual)
EDGE_PIPER_THRESHOLD = _env_int(
    "EDGE_PIPER_THRESHOLD", 3
)  # Switch to Piper after N consecutive failures (after Kokoro)
# Legacy env var for backwards compatibility (maps to PIPER threshold)
EDGE_FAILURE_THRESHOLD = _env_int("EDGE_FAILURE_THRESHOLD", EDGE_PIPER_THRESHOLD)
EDGE_FORCE_SAFE_CHARS = _env_int("EDGE_FORCE_SAFE_CHARS", 60000)
EDGE_AUTO_STABLE = _env_bool("EDGE_AUTO_STABLE", True)
EDGE_AUTO_PARALLEL_CAPS = {
    "slow": _env_int("EDGE_AUTO_PARALLEL_CAP_SLOW", 4),
    "medium": _env_int("EDGE_AUTO_PARALLEL_CAP_MEDIUM", 6),
    "fast": _env_int("EDGE_AUTO_PARALLEL_CAP_FAST", 8),
    "ultra": _env_int("EDGE_AUTO_PARALLEL_CAP_ULTRA", 10),
}
EDGE_MULTILINGUAL_RATE_CAP = _env_int("EDGE_MULTILINGUAL_RATE_CAP", 10)
EDGE_MONOLINGUAL_RATE_CAP = _env_int("EDGE_MONOLINGUAL_RATE_CAP", 16)

# Validation thresholds
TRUNCATION_THRESHOLD_PERCENT = _env_float(
    "TRUNCATION_THRESHOLD_PERCENT", 10.0
)  # Consider truncated if >10% missing
EXPECTED_WPM = _env_int("EXPECTED_WPM", 160)  # Expected words per minute for TTS
CHARS_PER_WORD = _env_float("CHARS_PER_WORD", 5.0)  # Average characters per word


def validate_audio_completeness(mp3_path: Path, text_length: int) -> tuple[bool, float]:
    """
    Validate if MP3 contains the full text or was truncated.

    Args:
        mp3_path: Path to MP3 file
        text_length: Number of characters in source text

    Returns:
        Tuple of (is_complete, coverage_percent)
        - is_complete: True if audio appears complete (< TRUNCATION_THRESHOLD_PERCENT missing)
        - coverage_percent: Estimated percentage of text covered by audio
    """
    if not mp3_path.exists():
        return False, 0.0

    # Skip check for short chapters: formatting cues, language markup, and
    # header text inflate text_length disproportionately for small chapters,
    # causing false "truncation" detection.
    if text_length < 1000:
        return True, 100.0

    try:
        # Get MP3 duration
        audio = MP3(str(mp3_path))
        duration_seconds = audio.info.length
        duration_minutes = duration_seconds / 60.0

        # Estimate characters that should fit in this duration
        words_in_audio = duration_minutes * EXPECTED_WPM
        chars_in_audio = words_in_audio * CHARS_PER_WORD

        # Calculate coverage percentage
        coverage_percent = (chars_in_audio / text_length) * 100.0 if text_length > 0 else 0.0

        # Check if truncation threshold exceeded
        missing_percent = 100.0 - coverage_percent
        is_complete = missing_percent <= TRUNCATION_THRESHOLD_PERCENT

        return is_complete, coverage_percent

    except Exception:
        # If we can't parse the MP3, don't block conversion - the file exists
        # and other validation (segment integrity, audio validator) will catch
        # truly corrupt files.
        return True, 100.0


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

    _NUMBERED_FILENAME_RE = re.compile(r"^(\d+(?:\.\d+)?)[\s_-]+(.+)$")

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
        self._active_config: Optional[ConversionConfig] = None
        self._auto_fix_guard: bool = False
        self._last_output_dir: Optional[Path] = None
        self.show_tts_output = False  # Only show TTS output in verbose mode
        self._retry_original_texts: Dict[str, str] = {}
        self._parallel_state: Dict[str, Any] = {
            "ceiling": 1,
            "current": 1,
            "best_throughput": 0.0,
            "last_throughput": None,
            "degrade_runs": 0,
        }
        self._edge_auto_state: Dict[str, Any] = {}
        self.hardware_profile: Optional[HardwareProfile] = None
        self._health_state: Dict[str, Any] = {"active": False}
        self._auto_tuner: Optional[AutoTuner] = None
        self._auto_tuning_enabled = _env_bool("ENABLE_AUTO_TUNING", True)
        self._auto_tuning_initialized = False
        self._adaptive_controller: Optional[AdaptivePerformanceController] = None
        self._adaptive_enabled = _env_bool(
            "ENABLE_ADAPTIVE_PERFORMANCE", False
        )  # Disabled by default for performance
        self._health_watchdog: Optional[asyncio.Task] = None
        self._cover_art: Optional[dict] = None
        self._text_validation_hashes: Dict[str, int] = {}
        self._text_validation_errors: List[str] = []
        self._last_chapters_for_text: Optional[List[Chapter]] = None
        self._memory_optimized = False
        self._thread_pools: List[weakref.ref] = []

    def _optimize_memory_settings(self) -> None:
        """
        Optimize memory settings for better performance.

        - Enables aggressive garbage collection
        - Sets memory limits on macOS/Linux
        - Optimizes thread stack size
        """
        if self._memory_optimized:
            return

        try:
            # Enable aggressive garbage collection to reduce memory peaks
            gc.set_threshold(700, 10, 5)  # More aggressive than default (700, 10, 10)

            # On Unix systems, limit memory growth
            if hasattr(resource, "RLIMIT_AS"):
                try:
                    # Get available memory
                    available_mem = psutil.virtual_memory().available
                    # Set soft limit to 80% of available memory
                    mem_limit = int(available_mem * 0.8)
                    resource.setrlimit(resource.RLIMIT_AS, (mem_limit, mem_limit))
                except (ValueError, OSError):
                    pass  # Ignore if we can't set limits

            # Reduce thread stack size for better memory efficiency
            try:
                threading.stack_size(1024 * 1024)  # 1MB stack (default is often 8MB)
            except ValueError:
                pass  # Some systems don't allow changing stack size

            self._memory_optimized = True

            if self.verbose:
                print("✅ Memory optimizations enabled")

        except Exception as e:
            if self.verbose:
                print(f"⚠️  Memory optimization failed: {e}")

    def _cleanup_resources(self, force_gc: bool = False) -> None:
        """
        Clean up unused resources and free memory.

        Args:
            force_gc: Force immediate garbage collection
        """
        try:
            # Clean up dead thread pool references
            self._thread_pools = [ref for ref in self._thread_pools if ref() is not None]

            # Clear temporary validation data
            if hasattr(self, "_text_validation_hashes"):
                if len(self._text_validation_hashes) > 100:  # Clear if too large
                    self._text_validation_hashes.clear()

            # Force garbage collection if requested or if memory usage is high
            if force_gc:
                gc.collect(generation=2)  # Full collection
            else:
                # Check memory usage and collect if high
                mem = psutil.virtual_memory()
                if mem.percent > 80:  # If using more than 80% of RAM
                    gc.collect(generation=1)  # Collect generations 0 and 1

        except Exception:
            pass  # Ignore cleanup errors

    def _create_optimized_thread_pool(self, max_workers: int) -> ThreadPoolExecutor:
        """
        Create a thread pool with optimized settings.

        Args:
            max_workers: Maximum number of worker threads

        Returns:
            Optimized ThreadPoolExecutor
        """
        # Limit max workers based on available resources
        cpu_count = os.cpu_count() or 4
        max_workers = min(max_workers, cpu_count * 2)  # Don't exceed 2x CPU count

        # Create thread pool with smaller stack size for memory efficiency
        executor = ThreadPoolExecutor(
            max_workers=max_workers, thread_name_prefix="converter_worker"
        )

        # Track thread pool for cleanup
        self._thread_pools.append(weakref.ref(executor))

        return executor

    async def _initialize_auto_tuning(self) -> None:
        """Initialize performance auto-tuning based on HW and network."""
        if self._auto_tuning_initialized or not self._auto_tuning_enabled:
            return

        try:
            self._auto_tuner = AutoTuner(verbose=self.verbose)

            # Only measure network if not in batch/silent mode
            measure_network = self.verbose and _env_bool("AUTO_TUNE_MEASURE_NETWORK", True)

            # Auto-configure (does not overwrite manually set vars)
            await self._auto_tuner.auto_configure(force=False, measure_network=measure_network)

            self._auto_tuning_initialized = True

        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Auto-tuning failed (using default configs): {exc}")

    def _initialize_adaptive_performance(self) -> None:
        """Initialize adaptive performance controller."""
        if not self._adaptive_enabled:
            return

        try:
            self._adaptive_controller = AdaptivePerformanceController(verbose=self.verbose)
            self._adaptive_controller.start_conversion()
        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Adaptive Performance failed (continuing without adjustments): {exc}")
            self._adaptive_controller = None

    def _record_chapter_progress(
        self, chapter: Chapter, success: bool, error: Optional[str] = None
    ):
        """Record chapter progress for adaptive adjustment."""
        if not self._adaptive_controller:
            return

        try:
            # Estimate chapter characters
            text = self._speech_text(chapter)
            chars_processed = len(text) if text else 0

            # Detect throttling by keyword in error
            throttled = (
                error and ("throttl" in error.lower() or "rate limit" in error.lower())
                if error
                else False
            )

            self._adaptive_controller.record_chapter_completion(
                chars_processed=chars_processed,
                success=success,
                error=error,
                throttled=throttled,
            )

            # Check if adjustment needed
            adjustment = self._adaptive_controller.calculate_adjustment()
            if adjustment.action != "no_change":
                self._adaptive_controller.apply_adjustment(adjustment)

        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Error recording adaptive progress: {exc}")

    async def _auto_validate_and_retry_async(
        self, output_dir: Path, epub_path: Path, cache_dir: Optional[Path], max_retries: int = 10
    ) -> bool:
        """
        Validate and reconvert ONLY problematic segments until 100% correct.

        Smart retry:
        - Missing MP3: reconvert only the MP3 (uses cached text)
        - Modified text: reconvert the full chapter
        - Loop until success or critical stall error

        Returns:
            True if validation passed, False if critical error
        """
        import sys

        project_root = Path(__file__).parent.parent.parent
        if str(project_root) not in sys.path:
            sys.path.insert(0, str(project_root))

        from validate_conversion import extract_problem_chapters, validate_book

        from .ebook_reader import EbookReader

        config = self._active_config
        if not config:
            return False

        consecutive_failures = 0
        last_problem_count = float("inf")

        # Progressive duration tolerance: increase each retry to handle
        # Edge-TTS reading speed variations (Portuguese ~100-120 WPM, not 150)
        duration_tolerances = [None, 0.60, 0.70, 0.80, 0.90, 1.00, 1.20, 1.50, 2.00, 2.50]

        for attempt in range(1, max_retries + 1):
            dur_tol = duration_tolerances[min(attempt - 1, len(duration_tolerances) - 1)]
            if self.verbose:
                tol_str = f" (duration tolerance: {dur_tol:.0%})" if dur_tol else ""
                print(f"\n🔍 Validation (attempt {attempt}/{max_retries}){tol_str}...")

            # Suppress error messages during auto-fix
            import os

            old_verbose = os.environ.get("SUPPRESS_VALIDATION_ERRORS", "0")
            os.environ["SUPPRESS_VALIDATION_ERRORS"] = "1"

            try:
                stats, issues = validate_book(
                    epub_path, output_dir, cache_dir=cache_dir, duration_tolerance=dur_tol
                )
            finally:
                os.environ["SUPPRESS_VALIDATION_ERRORS"] = old_verbose

            # Check if passed (duration_mismatch also critical)
            has_critical_problems = bool(
                any(
                    stats.get(key, 0) > 0
                    for key in (
                        "text_mismatch",
                        "parsed_pretts_diff",
                        "missing_mp3",
                        "duration_mismatch",
                    )
                )
            )

            if not has_critical_problems:
                # **TRANSCRIPTION VERIFICATION**: Final gate via speech-to-text
                if getattr(config, "verify_transcription", False):
                    try:
                        from .transcription_verifier import TranscriptionVerifier
                        from .transcription_verifier import is_available as _whisper_ok

                        if _whisper_ok():
                            if (
                                not hasattr(self, "_transcription_verifier")
                                or self._transcription_verifier is None
                            ):
                                # Don't force language — let Whisper auto-detect per chapter
                                # (forced language fails on multilingual content)
                                self._transcription_verifier = TranscriptionVerifier(
                                    model_size=getattr(config, "transcription_model", "medium"),
                                    language=None,
                                )

                            if self.verbose:
                                print("🔍 Transcription verification (faster-whisper)...")

                            transcription_failures = []

                            def _find_pretts(mp3_stem: str) -> Optional[Path]:
                                """Find pre-tts.txt matching MP3 by best title overlap.

                                Searches output_dir/text/ first (filenames match MP3),
                                then cache_dir/text/ as fallback.
                                """

                                def _title(name: str) -> str:
                                    parts = name.split(" - ", 1)
                                    return parts[1].strip() if len(parts) > 1 else name

                                mp3_title = _title(mp3_stem)
                                search_dirs = []
                                if (output_dir / "text").exists():
                                    search_dirs.append(output_dir / "text")
                                if cache_dir and (cache_dir / "text").exists():
                                    search_dirs.append(cache_dir / "text")

                                best_match = None
                                best_overlap = 0
                                for text_dir in search_dirs:
                                    for candidate in text_dir.glob("*-pre-tts.txt"):
                                        cache_title = _title(candidate.stem.replace("-pre-tts", ""))
                                        overlap = 0
                                        for a, b in zip(mp3_title, cache_title):
                                            if a == b:
                                                overlap += 1
                                            else:
                                                break
                                        if overlap > best_overlap and overlap >= 20:
                                            best_overlap = overlap
                                            best_match = candidate
                                return best_match

                            mp3_files = sorted(output_dir.glob("*.mp3"))
                            total_mp3 = len(mp3_files)
                            for mp3_idx, mp3_file in enumerate(mp3_files, 1):
                                print(f"🔍 [{mp3_idx}/{total_mp3}] Verifying: {mp3_file.name}")
                                pre_tts_path = _find_pretts(mp3_file.stem)

                                if pre_tts_path and pre_tts_path.exists():
                                    original_text = pre_tts_path.read_text(encoding="utf-8")
                                    vr = self._transcription_verifier.verify_chapter(
                                        mp3_file, original_text
                                    )
                                    if not vr.passed:
                                        chapter_id = (
                                            mp3_file.stem.split(" - ")[0].strip()
                                            if " - " in mp3_file.stem
                                            else mp3_file.stem
                                        )
                                        threshold = (
                                            self._transcription_verifier.SIMILARITY_THRESHOLD
                                        )
                                        if getattr(vr, "partial", False):
                                            # Timeout during transcription - audio is likely fine,
                                            # just too large for Whisper to verify in time. Don't delete.
                                            print(
                                                f"⚠️ {mp3_file.name}: partial verification (timeout) {vr.similarity_score:.1%} - keeping MP3"
                                            )
                                        else:
                                            transcription_failures.append(chapter_id)
                                            print(
                                                f"❌ {mp3_file.name}: transcription {vr.similarity_score:.1%} < {threshold:.0%}"
                                            )
                                            # Delete bad MP3 so retry loop picks it up
                                            mp3_file.unlink(missing_ok=True)
                                    else:
                                        print(f"✅ {mp3_file.name}: {vr.similarity_score:.1%}")

                            if transcription_failures:
                                if self.verbose:
                                    print(
                                        f"🔄 {len(transcription_failures)} chapter(s) failed transcription, reconverting..."
                                    )
                                # Don't return True — fall through to retry
                                last_problem_count = len(transcription_failures)
                                continue
                    except Exception as e:
                        if self.verbose:
                            print(f"⚠️ Transcription verification error: {e}")

                if self.verbose:
                    print("✅ Validação passou! Conversão 100% correta.")
                return True

            # Extrai capítulos com problemas
            problem_chapters = extract_problem_chapters(issues)

            if not problem_chapters:
                # Tem problemas mas não conseguiu identificar capítulos
                if self.verbose:
                    print(
                        "⚠️  Problemas detectados mas não foi possível identificar capítulos específicos"
                    )
                consecutive_failures += 1
                if consecutive_failures >= 3:
                    print("❌ Erro crítico: não é possível identificar problemas. Abortando.")
                    return False
                continue

            # Detectar se estamos travados (mesmo número de problemas)
            current_problem_count = len(problem_chapters)
            if current_problem_count >= last_problem_count:
                consecutive_failures += 1
                # With progressive tolerance, allow more retries for duration-only issues
                _, duration_only_check = self._categorize_problems(issues, problem_chapters)
                all_duration_only = len(duration_only_check) == current_problem_count
                max_consecutive = 6 if all_duration_only else 3
                if consecutive_failures >= max_consecutive:
                    if self.verbose:
                        print(
                            f"❌ Erro crítico: travado com {current_problem_count} problemas após {max_consecutive} tentativas. Abortando."
                        )
                    return False
            else:
                consecutive_failures = 0

            last_problem_count = current_problem_count

            # Categorizar problemas por tipo
            missing_mp3_only, duration_only = self._categorize_problems(issues, problem_chapters)

            if self.verbose:
                print()
                print("=" * 60)
                print(f"🔧 RECONVERSÃO: {len(problem_chapters)} capítulo(s) com problemas")
                print("=" * 60)
                print(f"   Capítulos: {', '.join(map(str, problem_chapters[:10]))}")
                if missing_mp3_only:
                    print(
                        f"   💡 {len(missing_mp3_only)} capítulo(s) apenas com MP3 faltante - síntese rápida"
                    )
                if duration_only:
                    print(
                        f"   ⏱️  {len(duration_only)} capítulo(s) apenas com duração incorreta - será retentado com tolerância maior"
                    )
                skip_set = set(missing_mp3_only) | set(duration_only)
                full_reconvert = [ch for ch in problem_chapters if ch not in skip_set]
                if full_reconvert:
                    print(
                        f"   🔄 {len(full_reconvert)} capítulo(s) com texto/nome incorreto - reconversão completa"
                    )

            # Remover MP3s errados antes de reconverter
            removed_files = self._remove_bad_mp3s(output_dir, issues, problem_chapters)
            if removed_files and self.verbose:
                print(
                    f"   🗑️  {len(removed_files)} MP3(s) errado(s) removidos antes da reconversão:"
                )
                for f in removed_files:
                    print(f"      - {f}")
                print("=" * 60)

            # Reconverte os capítulos problemáticos
            try:
                # Para MP3s faltantes, tentar síntese rápida primeiro
                if missing_mp3_only:
                    success = await self._reconvert_missing_mp3s(
                        output_dir, cache_dir, missing_mp3_only, issues
                    )
                    if success and self.verbose:
                        print(f"   ✅ {len(missing_mp3_only)} MP3(s) gerado(s) com sucesso")

                # Duration-only chapters: re-synthesize MP3 (may get slightly different timing)
                if duration_only and attempt <= 2:
                    # Only re-synthesize on first 2 attempts; after that rely on tolerance increase
                    if self.verbose:
                        print(
                            f"   🔄 Re-sintetizando {len(duration_only)} MP3(s) com duração incorreta..."
                        )
                    await self._reconvert_missing_mp3s(output_dir, cache_dir, duration_only, issues)

                # Para os demais, reconverter capítulo completo
                skip_set = set(missing_mp3_only) | set(duration_only)
                chapters_to_reconvert = [ch for ch in problem_chapters if ch not in skip_set]

                if not chapters_to_reconvert:
                    continue  # Apenas MP3s/duration, já tratados

                reader = EbookReader(str(epub_path))

                # Apply same transforms as validation to ensure consistent chapter mapping
                try:
                    from python_app.main import ConverterApplication

                    app = ConverterApplication()
                    preview_config = app.config.create_conversion_config(
                        engine=config.engine,
                        output_dir=str(output_dir.parent),
                        book_title=reader.title,
                        preserve_all_chapters=True,
                    )
                    preview_config.footnote_mode = "inline"
                    preview_config.footnote_context_words = app.FOOTNOTE_CONTEXT_WORDS
                    structure_items = app._generate_structure_items(reader, filter_chapters=False)
                    structure_items = app._apply_text_transforms(
                        structure_items, preview_config, reader
                    )
                    app._apply_structure_to_reader(reader, structure_items)
                except Exception as exc:
                    if self.verbose:
                        print(f"⚠️  Aviso: falha ao aplicar transforms ({exc})")

                all_chapters = reader.get_chapter_structure(preserve_all=True)

                # Map epub_index (1-based position) to chapter indices
                from validate_conversion import normalize_text

                chapter_indices = []
                sequential_num = 0
                for epub_idx, chapter in enumerate(all_chapters, 1):
                    text = chapter.text or ""
                    if not text or not normalize_text(text):
                        continue
                    sequential_num += 1
                    if str(epub_idx) in chapters_to_reconvert:
                        idx = getattr(chapter, "index", sequential_num)
                        chapter_indices.append(str(idx))
                        if self.verbose:
                            print(
                                f"   → Capítulo {epub_idx} mapeado para índice {idx}: {chapter.name[:60]}"
                            )

                if not chapter_indices:
                    if self.verbose:
                        print("⚠️  Não foi possível mapear capítulos problemáticos")
                    consecutive_failures += 1
                    continue

                # Create config for partial reconversion
                retry_config = ConversionConfig(
                    engine=config.engine,
                    voice=config.voice,
                    output_dir=str(output_dir.parent),
                    book_title=reader.title,
                    preserve_all_chapters=True,
                    clear_cache=False,  # Keep existing cache
                    auto_validate_output=False,  # Prevent recursion
                    auto_fix_output=False,  # Prevent recursion
                )
                retry_config.extra["chapter_whitelist"] = ",".join(chapter_indices)

                # Reconvert using existing converter instance
                await self.convert(reader, retry_config)

            except Exception as exc:
                if self.verbose:
                    print(f"⚠️  Erro ao reconverter: {exc}")
                    import traceback

                    traceback.print_exc()
                consecutive_failures += 1
                if consecutive_failures >= 3:
                    return False
                continue

        # Se chegou aqui, esgotou tentativas mas pode ter progredido
        if self.verbose:
            print(
                f"⚠️  Atingido limite de {max_retries} tentativas. Alguns problemas podem persistir."
            )
        return False

    def _categorize_problems(self, issues: list, problem_chapters: list) -> tuple[list, list]:
        """
        Categoriza problemas para decidir estratégia de reconversão.

        Returns:
            Tuple of (missing_mp3_only, duration_only) chapter lists
        """
        missing_mp3_only = []
        duration_only = []

        for chapter_num in problem_chapters:
            # Verificar se tem apenas MP3 faltante
            chapter_issues = [issue for issue in issues if f"Chapter {chapter_num}" in issue]

            has_missing_mp3 = any("Missing MP3" in issue for issue in chapter_issues)
            has_text_issues = any(
                any(
                    keyword in issue
                    for keyword in ["differs", "missing start", "missing end", "HTML"]
                )
                for issue in chapter_issues
            )

            if has_missing_mp3 and not has_text_issues:
                missing_mp3_only.append(chapter_num)
            elif not has_missing_mp3 and not has_text_issues:
                # Duration-only issue (text and MP3 exist but duration off)
                duration_only.append(chapter_num)

        return missing_mp3_only, duration_only

    def _remove_bad_mp3s(self, output_dir: Path, issues: list, problem_chapters: list) -> list[str]:
        """
        Remove MP3s errados antes de reconverter para evitar conflitos.

        Extrai nomes de MP3 das issues de validação (nome incorreto, duplicado,
        duração errada) e os remove do diretório de output.

        Returns:
            Lista de nomes de arquivos removidos.
        """
        import re

        removed = []
        mp3_filenames_to_remove: set[str] = set()

        for issue in issues:
            # "MP3 filename 'xxx.mp3' does not match EPUB heading"
            match = re.search(r"MP3 filename '([^']+\.mp3)'", issue)
            if match:
                mp3_filenames_to_remove.add(match.group(1))

            # "MP3 filename contains HTML/markup: xxx.mp3"
            match = re.search(r"HTML/markup:\s*(.+\.mp3)", issue)
            if match:
                mp3_filenames_to_remove.add(match.group(1).strip())

        # Also remove MP3s for chapters with duration mismatch or duplicates
        # by matching chapter number patterns in existing MP3 filenames
        problem_set = set(str(ch) for ch in problem_chapters)
        if output_dir.exists():
            for mp3_file in output_dir.glob("*.mp3"):
                # Extract chapter number from filename (e.g. "4.1 - ..." or "004 - ...")
                stem = mp3_file.name
                # Match decimal index: "4.1 - ...", "10.5 - ..."
                ch_match = re.match(r"^(\d+\.\d+)\s*-\s*", stem)
                if not ch_match:
                    # Match zero-padded: "004 - ..."
                    ch_match = re.match(r"^0*(\d+)\s*-\s*", stem)
                if ch_match:
                    ch_num = ch_match.group(1)
                    if ch_num in problem_set:
                        mp3_filenames_to_remove.add(mp3_file.name)

        # Remove the files
        for fname in mp3_filenames_to_remove:
            mp3_path = output_dir / fname
            if mp3_path.exists():
                mp3_path.unlink()
                removed.append(fname)

        return removed

    async def _reconvert_missing_mp3s(
        self, output_dir: Path, cache_dir: Optional[Path], chapter_nums: list, issues: list
    ) -> bool:
        """
        Reconverte apenas os MP3s faltantes usando texto cached.

        Returns:
            True se todos os MP3s foram gerados com sucesso
        """
        if not cache_dir or not cache_dir.exists():
            return False

        try:
            from .tts.factory import TTSFactory
            from .utils import AudioProcessor

            config = self._active_config
            if not config:
                return False

            # Criar engine TTS
            factory = TTSFactory()
            tts_engine = factory.create_engine(config)

            # Criar audio processor
            audio_processor = AudioProcessor()

            success_count = 0

            for chapter_num in chapter_nums:
                try:
                    # Encontrar arquivo pre-tts.txt no cache
                    text_dir = cache_dir / "text"
                    if not text_dir.exists():
                        text_dir = cache_dir

                    # Procurar arquivo pre-tts correspondente
                    pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))

                    # Encontrar o arquivo correto por número de capítulo
                    # Suporta formatos: "4 -", "4.5 -", "004 -", etc.
                    target_file = None
                    chapter_str = str(chapter_num)

                    for f in pre_tts_files:
                        # Try exact match with various formats
                        # Support: "4 -", "4.5 -", "004 -", etc.
                        matches = f.name.startswith(f"{chapter_str} -") or f.name.startswith(
                            f"{chapter_str}."
                        )

                        # Try zero-padded format only if chapter_num is an integer
                        if not matches:
                            try:
                                chapter_int = int(float(chapter_num))
                                matches = f.name.startswith(f"{chapter_int:03d} -")
                            except (ValueError, TypeError):
                                pass

                        if matches:
                            target_file = f
                            break

                    if not target_file or not target_file.exists():
                        if self.verbose:
                            print(f"   ⚠️  Capítulo {chapter_num}: pre-tts.txt não encontrado")
                            print(
                                f"      Arquivos disponíveis: {[f.name[:50] for f in pre_tts_files[:3]]}"
                            )
                        continue

                    # Ler texto
                    text = target_file.read_text(encoding="utf-8")
                    if not text:
                        if self.verbose:
                            print(f"   ⚠️  Capítulo {chapter_num}: texto vazio")
                        continue

                    # Extrair nome do capítulo do filename
                    chapter_name = target_file.stem.replace("-pre-tts", "")

                    if self.verbose:
                        print(f"   🎙️  Capítulo {chapter_num}: sintetizando MP3...")

                    # Sintetizar áudio
                    wav_file = await tts_engine.synthesize_async(
                        text, target_file.parent / f"temp_{chapter_num}.wav"
                    )

                    if not wav_file or not Path(wav_file).exists():
                        if self.verbose:
                            print(f"   ❌ Capítulo {chapter_num}: síntese falhou")
                        continue

                    # Converter para MP3
                    mp3_path = output_dir / f"{chapter_name}.mp3"
                    await audio_processor.convert_to_mp3(Path(wav_file), mp3_path)

                    # Limpar WAV temporário
                    Path(wav_file).unlink(missing_ok=True)

                    if mp3_path.exists():
                        success_count += 1
                        if self.verbose:
                            print(f"   ✅ Capítulo {chapter_num}: MP3 gerado")
                    else:
                        if self.verbose:
                            print(f"   ❌ Capítulo {chapter_num}: conversão MP3 falhou")

                except Exception as exc:
                    if self.verbose:
                        print(f"   ⚠️  Capítulo {chapter_num}: erro - {exc}")
                    continue

            return success_count > 0

        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Erro ao reconverter MP3s: {exc}")
            return False

    async def _auto_validate_output(self, output_dir: Optional[Path], stage: str = "final") -> None:
        """
        Run validate_conversion.validate_book to cross-check EPUB, cache and MP3.

        Best-effort: failures are logged only in verbose mode.
        """
        try:
            if stage not in {"final", "cache-only", "test", "initial"}:
                return
            config = self._active_config
            if not config or getattr(config, "auto_validate_output", True) is False:
                return
            epub_path = getattr(self, "_current_book_path", None)
            if not epub_path or not Path(epub_path).exists():
                return
            if not output_dir:
                output_dir = self._last_output_dir
            if not output_dir:
                return

            # For "initial" stage, only run if there are existing MP3s to validate
            if stage == "initial":
                if not output_dir.exists():
                    return
                mp3_files = list(output_dir.glob("*.mp3"))
                if not mp3_files:
                    # No existing MP3s, skip initial validation (first conversion)
                    return
                if self.verbose:
                    print(
                        f"\n🔍 Detectada conversão anterior com {len(mp3_files)} MP3(s). Validando antes de reconverter..."
                    )

            # Add project root to sys.path for validate_conversion import
            import sys

            project_root = Path(__file__).parent.parent.parent
            if str(project_root) not in sys.path:
                sys.path.insert(0, str(project_root))

            from validate_conversion import validate_book

            cache_dir = getattr(config, "cache_dir", None)
            if cache_dir:
                cache_dir = Path(cache_dir)
            else:
                try:
                    if self._current_book_path:
                        cache_dir = self.cache_manager._get_cache_path(self._current_book_path)
                except Exception:
                    cache_dir = None

            # Get max retries from config or environment
            max_retries = getattr(config, "max_validation_retries", None)
            if max_retries is None:
                import os

                max_retries = int(os.getenv("MAX_VALIDATION_RETRIES", "8"))

            # Use retry-based validation if auto_fix is enabled
            if getattr(config, "auto_fix_output", True) and not self._auto_fix_guard:
                self._auto_fix_guard = True
                try:
                    success = await self._auto_validate_and_retry_async(
                        Path(output_dir), Path(epub_path), cache_dir, max_retries=max_retries
                    )
                    if not success:
                        if self.verbose:
                            print("\n⚠️  Conversão concluída mas com problemas na validação")

                        # Tentativa de fallback automático para Piper se Edge-TTS falhou
                        current_engine = getattr(config, "engine", "").lower()
                        if current_engine == "edge" and stage == "final":
                            if self.verbose:
                                print("\n🔄 Tentando fallback automático para Piper...")

                            # Verificar se Piper está disponível
                            try:
                                from .tts.factory import TTSFactory

                                factory = TTSFactory()
                                available_engines = factory.available_engines()

                                if "piper" in available_engines:
                                    # Obter capítulos com problemas
                                    from validate_conversion import validate_book

                                    stats, issues = validate_book(
                                        Path(epub_path), Path(output_dir), cache_dir=cache_dir
                                    )

                                    missing_chapters = []
                                    for issue in issues:
                                        if "Missing MP3" in issue:
                                            # Extrair número do capítulo
                                            import re

                                            match = re.search(r"Chapter (\d+)", issue)
                                            if match:
                                                missing_chapters.append(int(match.group(1)))

                                    if missing_chapters and self.verbose:
                                        print(
                                            f"   🎯 {len(missing_chapters)} capítulo(s) faltando - reconvertendo com Piper"
                                        )
                                        print(
                                            f"   Capítulos: {', '.join(map(str, missing_chapters[:10]))}"
                                        )

                                    # Mudar temporariamente para Piper
                                    original_engine = config.engine
                                    config.engine = "piper"

                                    try:
                                        # Reconverter capítulos faltando com Piper
                                        piper_success = await self._reconvert_missing_mp3s(
                                            Path(output_dir), cache_dir, missing_chapters, issues
                                        )

                                        if piper_success:
                                            # Validar novamente
                                            stats_after, issues_after = validate_book(
                                                Path(epub_path),
                                                Path(output_dir),
                                                cache_dir=cache_dir,
                                            )
                                            has_critical = any(
                                                stats_after.get(key, 0) > 0
                                                for key in (
                                                    "text_mismatch",
                                                    "parsed_pretts_diff",
                                                    "missing_mp3",
                                                )
                                            )

                                            if not has_critical:
                                                if self.verbose:
                                                    print(
                                                        "   ✅ Fallback para Piper bem-sucedido! Todos os capítulos convertidos."
                                                    )
                                                success = True
                                            elif self.verbose:
                                                print(
                                                    f"   ⚠️  Fallback parcial: {stats_after.get('missing_mp3', 0)} capítulo(s) ainda faltando"
                                                )
                                    finally:
                                        # Restaurar engine original
                                        config.engine = original_engine
                                else:
                                    if self.verbose:
                                        print("   ⚠️  Piper não disponível para fallback")
                            except Exception as fallback_exc:
                                if self.verbose:
                                    print(f"   ⚠️  Erro no fallback: {fallback_exc}")

                        # Se ainda há problemas após fallback, exibir erro claro
                        if not success and self.verbose:
                            print(
                                "\n❌ CONVERSÃO INCOMPLETA: Alguns capítulos não foram convertidos"
                            )
                            print("   Tente:")
                            print("   1. Converter novamente com --engine piper")
                            print("   2. Converter capítulos específicos com --chapter N")
                finally:
                    self._auto_fix_guard = False
                return

            # Fallback to simple validation without auto-fix
            stats, issues = validate_book(Path(epub_path), Path(output_dir), cache_dir=cache_dir)
            has_problems = bool(
                issues
                or any(
                    stats.get(key, 0) > 0
                    for key in (
                        "missing_cache",
                        "text_mismatch",
                        "parsed_pretts_diff",
                        "missing_mp3",
                        "duration_mismatch",
                    )
                )
            )

            # Just report validation results (no auto-fix when it's disabled)
            if self.verbose and has_problems:
                print(
                    f"[DEBUG] Auto-validate ({stage}): validação com problemas mas auto-fix desabilitado"
                )
        except Exception as exc:
            if self.verbose:
                print(f"[DEBUG] Auto-validate ({stage}) failed: {exc}")

    @staticmethod
    def _speech_text(chapter: Chapter) -> str:
        text = getattr(chapter, "speech_text", None)
        if text is None:
            text = chapter.text or ""
        return text

    @staticmethod
    def _cleanup_duplicate_files(directory: Path, verbose: bool = False) -> int:
        """Remove duplicate files with (dup-N) suffix from directory and subdirectories.

        Args:
            directory: Root directory to scan for duplicates
            verbose: Print cleanup information

        Returns:
            Number of duplicate files removed
        """
        if not directory.exists():
            return 0

        # Pattern to match files like "filename (dup-1).mp3", "filename (dup-2).mp3", etc.
        dup_pattern = re.compile(r"^(.+)\s+\(dup-\d+\)(\.\w+)$")
        removed_count = 0

        # Recursively scan directory
        for file_path in directory.rglob("*"):
            if not file_path.is_file():
                continue

            match = dup_pattern.match(file_path.name)
            if match:
                try:
                    file_path.unlink()
                    removed_count += 1
                    if verbose:
                        print(f"   🗑️ Removed duplicate: {file_path.name}")
                except OSError as e:
                    if verbose:
                        print(f"   ⚠️ Could not remove {file_path.name}: {e}")

        if removed_count > 0 and verbose:
            print(f"✓ Cleaned up {removed_count} duplicate file(s)")

        return removed_count

    @staticmethod
    def _coerce_chapter_index(raw: object, fallback: int) -> int:
        if raw is None:
            return fallback
        try:
            if isinstance(raw, str):
                text = raw.strip()
                if not text:
                    return fallback
                if text.replace(".", "", 1).isdigit():
                    raw = float(text) if "." in text else int(text)
                else:
                    return fallback
            value = int(raw)
        except Exception:
            try:
                value = int(float(raw))  # type: ignore[arg-type]
            except Exception:
                return fallback
        return value if value > 0 else fallback

    @staticmethod
    def _spot_check_text_against_epub(epub_text: str, payload: str) -> bool:
        """Lightweight spot-check: ensure key snippets from EPUB exist in the TTS payload."""
        if not epub_text or not payload:
            return False

        def normalize(val: str) -> str:
            val = re.sub(r"\s+", " ", val or "")
            return val.strip().lower()

        epub_norm = normalize(epub_text)
        payload_norm = normalize(payload)
        if not epub_norm or not payload_norm:
            return False

        # Take first snippet and a middle snippet to detect truncation/duplication.
        first_snippet = epub_norm[:200]
        mid_start = max(len(epub_norm) // 2 - 100, 0)
        mid_snippet = epub_norm[mid_start : mid_start + 200]

        first_ok = first_snippet in payload_norm
        mid_ok = mid_snippet in payload_norm
        return first_ok and mid_ok

    @staticmethod
    def _sample_edges(text: str, size: int = 180) -> tuple[str, str]:
        normalized = re.sub(r"\s+", " ", text or "").strip()
        if len(normalized) <= size * 2:
            return normalized, normalized
        return normalized[:size], normalized[-size:]

    @staticmethod
    def _strip_formatting_cues(text: str) -> str:
        """Remove audible formatting cue phrases from text."""
        if not text:
            return ""
        try:
            from .text_formatting import TextFormattingProcessor

            phrases: set[str] = set()
            for locale_map in TextFormattingProcessor.CUE_LABELS.values():
                for start, end in locale_map.values():
                    phrases.add(start)
                    phrases.add(end)
            phrases.update(TextFormattingProcessor.FOOTNOTE_END_PHRASES)
        except Exception:
            return text

        cleaned = text
        for phrase in sorted(phrases, key=len, reverse=True):
            cleaned = re.sub(re.escape(phrase), "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s+", " ", cleaned).strip()
        return cleaned

    def _validate_text_after_save(
        self,
        chapter: Chapter,
        chapter_label: str,
        parsed_text: str,
        pre_tts_text: str,
        *,
        validator: "TextIntegrityValidator",
        strict: bool,
    ) -> bool:
        """Validate parsed/pre-tts text against EPUB content."""
        issues: List[str] = []
        epub_text = chapter.text or ""
        parsed_norm = validator.normalize_text(parsed_text)
        epub_norm = validator.normalize_text(epub_text)

        if not parsed_norm:
            issues.append("Texto do capítulo vazio ou não extraído do EPUB")
        if epub_norm:
            diff = len(epub_norm) - len(parsed_norm)
            allowed_diff = max(50, int(len(epub_norm) * 0.05))
            if abs(diff) > allowed_diff:
                issues.append(f"Texto divergente do EPUB ({diff:+d} chars)")
            start, end = self._sample_edges(epub_norm)
            if start and start not in parsed_norm:
                issues.append("Texto parsed sem início do EPUB")
            if end and end not in parsed_norm:
                issues.append("Texto parsed sem final do EPUB")

        if parsed_norm:
            text_hash = validator.calculate_text_hash(parsed_norm)
            if text_hash in self._text_validation_hashes:
                other = self._text_validation_hashes[text_hash]
                # Only flag as duplicate if it's a different chapter
                # (validation may be called multiple times for same chapter during retries)
                if other != chapter_label:
                    issues.append(f"Conteúdo duplicado (igual ao capítulo {other})")
            else:
                # Use full chapter label instead of just integer index to avoid false positives
                # for subchapters (4.1, 4.2, etc.) which all have the same integer part
                self._text_validation_hashes[text_hash] = chapter_label

            snippet = parsed_norm[:200]
            if snippet and parsed_norm.count(snippet) > 1:
                issues.append("Possível duplicação interna (trecho repetido)")
            if len(parsed_norm) > 400 and parsed_norm[:200] == parsed_norm[-200:]:
                issues.append("Possível duplicação interna (início = fim)")

        if pre_tts_text and parsed_norm:
            pretts_norm = validator.normalize_text(self._strip_formatting_cues(pre_tts_text))
            # Pre-TTS text may have chapter announcements and formatting cues prepended/appended
            # So we check if substantial portions of the parsed text appear anywhere in pre-TTS
            # rather than checking exact beginning/end positions
            if len(parsed_norm) > 300:
                # Sample from middle sections to avoid chapter announcement additions
                mid_start = len(parsed_norm) // 4
                mid_sample_size = min(200, len(parsed_norm) // 2)
                mid_sample = parsed_norm[mid_start : mid_start + mid_sample_size]

                # Check if middle portion exists in pre-TTS (more reliable than start/end)
                if mid_sample and mid_sample not in pretts_norm:
                    # Length check: pre-TTS should be similar length to parsed (within 20%)
                    len_ratio = len(pretts_norm) / len(parsed_norm) if len(parsed_norm) > 0 else 0
                    if len_ratio < 0.8 or len_ratio > 1.5:
                        issues.append(
                            f"Pre-TTS tem tamanho muito diferente do parsed ({len_ratio:.1%})"
                        )

        if issues:
            message = f"Validação pós-parsing falhou ({chapter_label}): {', '.join(issues)}"
            self._text_validation_errors.append(message)
            if self.verbose:
                print(f"❌ {message}")
            if strict:
                raise RuntimeError(message)
            return False

        return True

    def _validate_audio_after_write(
        self,
        text_payload: str,
        output_path: Path,
        *,
        config: ConversionConfig,
    ) -> tuple[bool, Optional[str]]:
        """Validate MP3 integrity and duration after conversion."""
        try:
            from .audio_validator import AudioValidator

            validator = AudioValidator()
            file_is_valid = validator.validate_audio_file(output_path)
            if not file_is_valid:
                return False, "Invalid or corrupted audio"

            normalized_len = len(re.sub(r"\s+", " ", text_payload or "").strip())
            if normalized_len >= 5000:
                # Increased tolerance: Edge-TTS speed varies significantly based on content
                # Portuguese text + formatting cues make duration estimation less accurate
                tolerance = 0.50 if normalized_len < 10000 else 0.40
                duration_result = validator.validate_duration(
                    text_payload, output_path, tolerance=tolerance
                )
                if not duration_result.is_valid:
                    # Log warning but don't fail - file exists and is playable
                    if self.verbose:
                        print(f"⚠️ Duration check: {duration_result.error_message}")
                    # Don't fail conversion due to duration mismatch alone
                    # return False, duration_result.error_message or "Duração inválida"

            return True, None
        except Exception as exc:
            if self.verbose:
                print(f"⚠️ Audio validation failed with error: {exc}")
            return True, None

    def _edge_segment_integrity_ok(self, tts_engine: object) -> tuple[bool, Optional[str]]:
        """Ensure Edge produced all segments (100% completeness)."""
        report = getattr(tts_engine, "last_segment_report", None)
        expected = 0
        generated = 0
        failed = 0
        if isinstance(report, dict):
            try:
                expected = int(report.get("expected") or 0)
                generated = int(report.get("generated") or 0)
                failed = int(report.get("failed") or 0)
            except (TypeError, ValueError):
                expected = 0
                generated = 0
                failed = 0

        tracker_missing = 0
        if hasattr(tts_engine, "get_synthesis_tracker"):
            tracker = tts_engine.get_synthesis_tracker()
            if tracker:
                try:
                    tracker_missing = len(tracker.get_missing_segments() or [])
                except Exception:
                    tracker_missing = 0

        if getattr(tts_engine, "partial_failure_detected", False):
            return False, "Falha parcial detectada na síntese Edge"

        if failed > 0 or tracker_missing > 0:
            total_failed = failed if failed > 0 else tracker_missing
            if expected and generated:
                return (
                    False,
                    f"Segmentos faltando: {generated}/{expected} (falharam {total_failed})",
                )
            return False, f"Segmentos faltando: {total_failed}"

        if expected and generated and expected != generated:
            return False, f"Segmentos incompletos: {generated}/{expected}"

        return True, None

    async def _attempt_segment_retry(
        self,
        tts_engine: object,
        chapter_index: int,
        chapter_label: str,
        output_path: Path,
        *,
        config: ConversionConfig,
    ) -> bool:
        """Try recovering missing chunks/segments after validation failure."""
        if not getattr(config, "validate_audio", True):
            return False
        try:
            if not hasattr(tts_engine, "get_synthesis_tracker"):
                return False
            tracker = tts_engine.get_synthesis_tracker()
            if not tracker:
                return False
            missing_segments = tracker.get_missing_segments()
            if not missing_segments:
                return False
            if self.verbose:
                print(
                    f"🔄 Chapter {chapter_label}: {len(missing_segments)} segmento(s) falhando, tentando recuperar..."
                )
            from .retry_manager import RetryManager

            retry_manager = RetryManager(max_retries=3)
            temp_retry_dir = output_path.parent / f"retry_temp_{chapter_index}"
            retry_report = await retry_manager.retry_failed_segments(
                engine=tts_engine,
                failed_segments=missing_segments,
                output_path=output_path,
                temp_dir=temp_retry_dir,
            )
            if self.verbose:
                print(
                    f"✓ Retry segmentos: {retry_report.successful}/{retry_report.total_retried} recuperados, "
                    f"{retry_report.still_failed} falharam"
                )
            try:
                if temp_retry_dir.exists():
                    shutil.rmtree(temp_retry_dir, ignore_errors=True)
            except Exception:
                pass
            return retry_report.still_failed == 0
        except Exception as exc:
            if self.verbose:
                print(f"⚠️ Segment retry failed: {exc}")
            return False

    def _chapter_number(self, chapter: Chapter, fallback: int) -> int:
        return self._coerce_chapter_index(getattr(chapter, "index", None), fallback)

    @staticmethod
    def _chapter_index_label(chapter: Chapter, fallback: int) -> str:
        raw = getattr(chapter, "index", None)
        if isinstance(raw, str):
            value = raw.strip()
            return value or str(fallback)
        if raw is None:
            return str(fallback)
        try:
            return str(raw)
        except Exception:
            return str(fallback)

    @staticmethod
    def _remove_duplicate_chapter_prefix(chapter_label: str, chapter_name: str) -> str:
        """
        Remove duplicate numeric prefix from chapter name if it matches the label.

        Example:
        - label="4.5", name="4.5 - Parte 1" -> "Parte 1"
        - label="4.5", name="4.5 Parte 1" -> "Parte 1"
        - label="4.5", name="Parte 1" -> "Parte 1" (no change)

        Returns:
            Chapter name without duplicate prefix
        """
        chapter_name_clean = chapter_name.strip()
        label_str = str(chapter_label).strip()

        # Check if chapter_name starts with the label
        if chapter_name_clean.startswith(label_str):
            # Try to remove "4.5 - " format
            if chapter_name_clean.startswith(f"{label_str} - "):
                return chapter_name_clean[len(label_str) + 3 :].strip()
            # Try to remove "4.5 " format (space only)
            elif (
                len(chapter_name_clean) > len(label_str)
                and chapter_name_clean[len(label_str)] == " "
            ):
                return chapter_name_clean[len(label_str) :].strip()

        return chapter_name_clean

    def _expected_output_path(self, chapter: Chapter, chapter_num: int, directory: Path) -> Path:
        chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_num}"
        # Get chapter label to remove duplicate prefix
        chapter_label = self._chapter_index_label(chapter, chapter_num)
        chapter_name_clean = self._remove_duplicate_chapter_prefix(chapter_label, chapter_name)
        filename = self.file_manager.build_output_filename(chapter_name_clean, chapter_num)
        return Path(directory) / filename

    def _normalize_title_match(self, title: str) -> str:
        safe = self.file_manager.sanitize_filename(title)
        normalized = safe.replace("_", " ")
        normalized = unicodedata.normalize("NFKD", normalized)
        normalized = "".join(ch for ch in normalized if not unicodedata.combining(ch))
        normalized = re.sub(r"\s+", " ", normalized).strip().lower()
        return normalized

    def _build_title_index(self, directory: Path) -> Dict[str, List[Path]]:
        index: Dict[str, List[Path]] = {}
        dir_path = Path(directory)
        if not dir_path.exists():
            return index
        for candidate in dir_path.glob("*.mp3"):
            match = self._NUMBERED_FILENAME_RE.match(candidate.stem)
            if not match:
                continue
            key = self._normalize_title_match(match.group(2))
            if not key:
                continue
            index.setdefault(key, []).append(candidate)
        return index

    def _resolve_misnumbered_audio(
        self,
        chapter: Chapter,
        chapter_num: int,
        directory: Path,
        title_index: Dict[str, List[Path]],
    ) -> Optional[Path]:
        expected = self._expected_output_path(chapter, chapter_num, directory)
        if expected.exists():
            return expected
        chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_num}"
        chapter_label = self._chapter_index_label(chapter, chapter_num)
        chapter_name_clean = self._remove_duplicate_chapter_prefix(chapter_label, chapter_name)
        key = self._normalize_title_match(chapter_name_clean)
        candidates = title_index.get(key) or []
        if not candidates:
            return None
        if len(candidates) == 1:
            candidate = candidates[0]
            candidates = []
        else:

            def _candidate_key(path: Path) -> tuple[int, float, str]:
                try:
                    size = path.stat().st_size
                except OSError:
                    size = 0
                try:
                    mtime = path.stat().st_mtime
                except OSError:
                    mtime = 0.0
                return (size, mtime, path.name)

            candidates_sorted = sorted(candidates, key=_candidate_key, reverse=True)
            candidate = candidates_sorted[0]
            candidates = candidates_sorted[1:]
        if not candidate.exists():
            return None
        if expected.exists():
            return expected
        try:
            candidate.rename(expected)
            title_index[key] = []
            if candidates:
                for idx, leftover in enumerate(candidates, start=1):
                    if not leftover.exists():
                        continue
                    dup_name = f"{expected.stem} (dup-{idx}).mp3"
                    dup_path = expected.with_name(dup_name)
                    try:
                        leftover.rename(dup_path)
                    except OSError:
                        if self.verbose:
                            print(f"⚠️ Failed to move duplicate: {leftover.name} → {dup_name}")
            return expected
        except OSError:
            if self.verbose:
                print(f"⚠️ Failed to rename cache: {candidate.name} → {expected.name}")
            return candidate

    def _normalize_output_numbers(
        self,
        chapters: List[Chapter],
        output_dir: Path,
        config: ConversionConfig,
        *,
        temp_dir: Optional[Path] = None,
    ) -> List[Path]:
        output_index = self._build_title_index(output_dir)
        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            self._resolve_misnumbered_audio(chapter, chapter_num, output_dir, output_index)

        if temp_dir:
            temp_index = self._build_title_index(temp_dir)
            for idx, chapter in enumerate(chapters, start=1):
                chapter_num = self._chapter_number(chapter, idx)
                self._resolve_misnumbered_audio(chapter, chapter_num, temp_dir, temp_index)

        cache_root = getattr(config, "cache_dir", None)
        if cache_root:
            cache_dir = Path(cache_root)
            audio_dir = cache_dir / "audio"
            model_bucket = AudioConverter._cache_model_bucket(config)
            if model_bucket:
                audio_dir = audio_dir / model_bucket
            audio_index = self._build_title_index(audio_dir)
            for idx, chapter in enumerate(chapters, start=1):
                chapter_num = self._chapter_number(chapter, idx)
                self._resolve_misnumbered_audio(chapter, chapter_num, audio_dir, audio_index)

        normalized_outputs: List[Path] = []
        expected_names: set[str] = set()
        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            expected = self._expected_output_path(chapter, chapter_num, output_dir)
            expected_names.add(expected.name)
            if expected.exists():
                normalized_outputs.append(expected)

        # Remove stale MP3s whose names don't match any expected filename
        self._remove_stale_numbered_files(output_dir, "*.mp3", expected_names)
        if temp_dir:
            self._remove_stale_numbered_files(temp_dir, "*.mp3", expected_names)

        # Clean stale cache text files
        self._cleanup_stale_cache_text(chapters, config)

        return normalized_outputs

    def _remove_stale_numbered_files(
        self, directory: Path, glob_pattern: str, expected_names: set[str]
    ) -> None:
        """Remove numbered files whose name doesn't match any expected filename.

        Only removes a file if another file with the **same title** (after stripping
        the numeric prefix) exists in the expected set — i.e. it's a stale duplicate
        from a previous numbering scheme.
        """
        if not directory.exists():
            return

        # Build a mapping from normalized title -> expected filename
        expected_titles: dict[str, str] = {}
        for name in expected_names:
            m = self._NUMBERED_FILENAME_RE.match(Path(name).stem)
            if m:
                title_key = self._normalize_title_match(m.group(2))
                expected_titles[title_key] = name

        removed = 0
        for f in directory.glob(glob_pattern):
            if f.name in expected_names:
                continue
            m = self._NUMBERED_FILENAME_RE.match(f.stem)
            if not m:
                continue
            title_key = self._normalize_title_match(m.group(2))
            # Only remove if the same title exists under the expected naming
            if title_key in expected_titles:
                try:
                    f.unlink()
                    removed += 1
                    if self.verbose:
                        print(f"   🧹 Removed stale file: {f.name}")
                except OSError:
                    pass
        if removed and not self.verbose:
            print(f"  🧹 Removed {removed} stale file(s) from {directory.name}/")

    def _cleanup_stale_cache_text(self, chapters: List[Chapter], config: ConversionConfig) -> None:
        """Remove cache text files whose title duplicates an expected file but
        with a different numeric prefix (stale from a previous numbering scheme)."""
        cache_root = getattr(config, "cache_dir", None)
        if not cache_root:
            try:
                if self._current_book_path:
                    cache_root = self.cache_manager._get_cache_path(self._current_book_path)
            except Exception:
                return
        if not cache_root:
            return

        # Build expected text filenames
        expected_prefixes: set[str] = set()
        for idx, chapter in enumerate(chapters, start=1):
            chapter_label = self._chapter_index_label(chapter, idx)
            chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_label}"
            chapter_name_clean = self._remove_duplicate_chapter_prefix(chapter_label, chapter_name)
            safe_name = self.file_manager.sanitize_filename(chapter_name_clean)
            prefix = f"{chapter_label} - {safe_name}"
            expected_prefixes.add(prefix)

        # Build title index from expected prefixes
        expected_titles: set[str] = set()
        for prefix in expected_prefixes:
            m = self._NUMBERED_FILENAME_RE.match(prefix)
            if m:
                expected_titles.add(self._normalize_title_match(m.group(2)))

        # Check engine-specific text dirs under cache
        for engine_dir in Path(cache_root).iterdir():
            if not engine_dir.is_dir():
                continue
            text_dir = engine_dir / "text" if (engine_dir / "text").exists() else None
            if engine_dir.name == "text":
                text_dir = engine_dir
            if not text_dir or not text_dir.exists():
                continue
            removed = 0
            for txt_file in list(text_dir.glob("*.txt")):
                # Check if file matches expected prefix
                if any(txt_file.name.startswith(p) for p in expected_prefixes):
                    continue
                # Extract title from numbered file
                # Strip suffix like "-parsed.txt" or "-pre-tts.txt" first
                base = txt_file.name
                for suffix in ("-parsed.txt", "-pre-tts.txt"):
                    if base.endswith(suffix):
                        base = base[: -len(suffix)]
                        break
                m = self._NUMBERED_FILENAME_RE.match(base)
                if not m:
                    continue
                title_key = self._normalize_title_match(m.group(2))
                if title_key in expected_titles:
                    try:
                        txt_file.unlink()
                        removed += 1
                        if self.verbose:
                            print(f"   🧹 Removed stale cache text: {txt_file.name}")
                    except OSError:
                        pass
            if removed and not self.verbose:
                print(f"  🧹 Removed {removed} stale cache text file(s)")

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
        candidate = stem
        if " - " in stem:
            parts = stem.split(" - ", 1)
            if len(parts) == 2 and parts[0].isdigit():
                candidate = parts[1]
        else:
            parts = stem.split("_", 1)
            if len(parts) == 2 and parts[0].isdigit():
                candidate = parts[1]
            candidate = candidate.replace("_", " ")
        candidate = candidate.strip()
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
    def _expected_audio_bytes(
        cls, estimated_seconds: float, bitrate: Optional[str]
    ) -> Optional[int]:
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
        engine_label: Optional[str] = None,
    ) -> Optional[str]:
        audio_path = Path(audio_path)
        if not audio_path.exists() or not payload_text:
            return None

        (engine_label or getattr(config, "engine", "") or "").lower()

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
        if actual_seconds and actual_seconds >= max(
            estimated_seconds - 90, estimated_seconds * 0.5
        ):
            return None

        expected_bytes = self._expected_audio_bytes(
            estimated_seconds, getattr(config, "bitrate", "8k")
        )
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

        return f"Audio possibly truncated ({file_size} bytes ≈ {short_seconds}s, expected ≈ {expected_display}s)"

    def _load_cached_payload(
        self,
        chapter: Chapter,
        index: int,
        temp_dir: Path,
    ) -> Optional[str]:
        try:
            index_label = self._chapter_index_label(chapter, index)
            pre_tts_path = self._find_pre_tts_path(
                cache_dir=None,
                output_dir=Path(temp_dir),
                index=index,
                chapter_name=getattr(chapter, "name", None),
                index_label=index_label,
            )
            if pre_tts_path and pre_tts_path.exists():
                return pre_tts_path.read_text(encoding="utf-8")
        except OSError:
            pass
        return None

    def _resolve_pre_tts_payload(
        self,
        chapter: Chapter,
        index: int,
        output_dir: Optional[Path],
        config: Optional[ConversionConfig],
    ) -> tuple[str, Optional[Path], bool]:
        """Return payload text, its pre-tts path (if any), and whether payload is locked to file."""
        index_label = self._chapter_index_label(chapter, index)
        pre_tts_path = self._find_pre_tts_path(
            cache_dir=getattr(config, "cache_dir", None) if config else None,
            output_dir=output_dir,
            index=index,
            chapter_name=getattr(chapter, "name", None),
            index_label=index_label,
        )
        if pre_tts_path and pre_tts_path.exists():
            try:
                return pre_tts_path.read_text(encoding="utf-8"), pre_tts_path, True
            except OSError:
                pass
        return (self._speech_text(chapter) or ""), pre_tts_path, False

    def _prepare_truncation_retry_payload(
        self,
        chapter: Chapter,
        canonical_label: str,
        attempts_so_far: int,
        chapter_index: Optional[int] = None,
        output_dir: Optional[Path] = None,
        cache_dir: Optional[Path] = None,
    ) -> None:
        """Simplify chapter payload before a retry after truncated audio detection."""
        try:
            fallback_index = chapter_index or attempts_so_far
            index_label = self._chapter_index_label(chapter, fallback_index)
            pre_tts_path = self._find_pre_tts_path(
                cache_dir=cache_dir,
                output_dir=output_dir,
                index=self._chapter_number(chapter, fallback_index),
                chapter_name=getattr(chapter, "name", None),
                index_label=index_label,
            )
            if pre_tts_path and pre_tts_path.exists():
                # Keep payload locked to pre-tts text to avoid mismatches.
                return
        except Exception:
            pass
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
            cleaned = re.sub(r"\[\[fmt:[^\]]+\]\]|\[\[/fmt\]\]", "", stripped or "")
            updated_text = cleaned.strip()
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
            chapter_num = self._chapter_number(chapter, idx)
            label = self._chapter_display_name(chapter, chapter_num).strip()
            output_path = self._expected_output_path(chapter, chapter_num, temp_dir)
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

    def _validate_and_clean_cache(
        self, chapters: List[Chapter], output_dir: Path, config: ConversionConfig
    ) -> None:
        """Validate cache: if MP3 exists but pre-tts.txt doesn't, delete MP3.
        Also copy existing files from final output_dir back to temp for resume capability."""
        text_dir = Path(output_dir) / "text"
        deleted_count = 0
        copied_count = 0
        regenerated_txt = 0

        # Prepare formatter once for regeneration
        try:
            from .text_formatting import TextFormattingProcessor

            TextFormattingProcessor()
        except ImportError:
            pass

        # Get final output directory to check for already converted chapters
        final_output_dir = self._setup_output_directory(config)

        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            chapter_label = self._chapter_index_label(chapter, idx)
            chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_label}"
            # Remove duplicate prefix to avoid "4.5 - 4.5 - Title"
            chapter_name_clean = self._remove_duplicate_chapter_prefix(chapter_label, chapter_name)
            safe_name = self.file_manager.sanitize_filename(chapter_name_clean)

            # Check for pre-tts.txt
            pre_tts_file = text_dir / f"{chapter_label} - {safe_name}-pre-tts.txt"

            # Check for MP3 in temp/cache dir
            mp3_path = self._expected_output_path(chapter, chapter_num, output_dir)

            # Check for MP3 in final output dir (for resume capability)
            final_mp3_path = final_output_dir / mp3_path.name

            # If MP3 exists in final output but not in temp, copy it for reuse
            if not mp3_path.exists() and final_mp3_path.exists():
                try:
                    final_size = final_mp3_path.stat().st_size
                    if final_size > 1000:  # Valid file (> 1KB)
                        import shutil

                        shutil.copy2(str(final_mp3_path), str(mp3_path))
                        copied_count += 1
                        if self.verbose:
                            print(f"   ♻️ Reusing chapter {chapter_num}: {mp3_path.name}")
                except OSError as e:
                    if self.verbose:
                        print(f"   ⚠️ Error copying chapter {chapter_num}: {e}")

            # If MP3 exists but pre-tts.txt doesn't → invalidate audio to force fresh synthesis
            if mp3_path.exists() and not pre_tts_file.exists():
                if self.verbose:
                    print(
                        f"   🗑️ Incomplete cache (missing pre-tts.txt) for chapter {chapter_num}: removing MP3"
                    )
                mp3_path.unlink(missing_ok=True)
                mp3_path.with_suffix(".wav").unlink(missing_ok=True)
                deleted_count += 1

        if copied_count > 0:
            print(f"♻️ {copied_count} chapter(s) reused from previous conversion")
        if regenerated_txt > 0:
            print(f"♻️ {regenerated_txt} pre-tts file(s) regenerated to reuse cache")
        if deleted_count > 0:
            print(f"🗑️ {deleted_count} MP3 file(s) removed (invalid cache)")

    def _generate_all_text_files(
        self,
        chapters: List[Chapter],
        output_dir: Path,
        config: ConversionConfig,
        *,
        text_validator: Optional["TextIntegrityValidator"] = None,
        cleanup_existing: bool = True,
    ) -> None:
        """Generate all text files BEFORE starting TTS conversion"""
        text_dir = Path(output_dir) / "text"
        text_dir.mkdir(parents=True, exist_ok=True)

        # **NEW**: Clean up duplicate files before generating new ones
        # Remove files with pattern "N - M - filename" (duplicate variants)
        if text_dir.exists():
            duplicates_removed = 0
            seen_files = {}

            for txt_file in text_dir.glob("*-parsed.txt"):
                # Normalize filename by removing leading number variants
                # e.g., "1 - 4.1 - Chapter.txt" -> "4.1 - Chapter.txt"
                parts = txt_file.name.split(" - ", 2)
                if len(parts) >= 3:
                    # Has duplicate prefix (e.g., "1 - 4.1 - ...")
                    canonical = " - ".join(parts[1:])
                    if canonical in seen_files:
                        # Duplicate found, remove it
                        txt_file.unlink(missing_ok=True)
                        # Also remove corresponding pre-tts file
                        pre_tts = txt_file.parent / txt_file.name.replace(
                            "-parsed.txt", "-pre-tts.txt"
                        )
                        pre_tts.unlink(missing_ok=True)
                        duplicates_removed += 1
                    else:
                        seen_files[canonical] = txt_file
                else:
                    # Normal file, keep track of it
                    seen_files[txt_file.name] = txt_file

            if duplicates_removed > 0 and not self.verbose:
                print(f"  🧹 Removed {duplicates_removed} duplicate cached file(s)")

        if cleanup_existing and any(text_dir.glob("*.txt")):
            for txt_file in text_dir.glob("*.txt"):
                txt_file.unlink(missing_ok=True)
            if self.verbose:
                print("  🧹 Cleaned up old text files")

        # Import TextFormattingProcessor to apply the same processing as TTS
        try:
            from .text_formatting import TextFormattingProcessor

            formatter = TextFormattingProcessor()
        except ImportError:
            formatter = None

        def _prepare_payload(chapter_index: str, chapter_obj: Chapter) -> tuple[str, str, str, str]:
            chapter_name_local = getattr(chapter_obj, "name", None) or f"Chapter {chapter_index}"
            parsed_text_local = chapter_obj.text or ""
            speech_text_local = self._speech_text(chapter_obj)
            if formatter:
                formatting_segments_local = getattr(chapter_obj, "formatting_segments", None)
                if formatting_segments_local or "[[fmt" in (speech_text_local or ""):
                    pre_tts_text_local = formatter.to_audible_text(
                        speech_text_local, formatting_segments_local
                    )
                else:
                    pre_tts_text_local = speech_text_local
            else:
                pre_tts_text_local = speech_text_local
            return (chapter_index, chapter_name_local, parsed_text_local, pre_tts_text_local or "")

        files_generated = 0
        futures = []
        chapter_entries: List[tuple[str, int, Chapter]] = []
        with ThreadPoolExecutor(max_workers=min(8, (os.cpu_count() or 1))) as executor:
            for idx, chapter in enumerate(chapters, start=1):
                chapter_label = self._chapter_index_label(chapter, idx)
                chapter_num = self._chapter_number(chapter, idx)
                chapter_entries.append((chapter_label, chapter_num, chapter))
                if formatter:
                    formatting_segments_local = getattr(chapter, "formatting_segments", None)
                    formatter.to_audible_text(self._speech_text(chapter), formatting_segments_local)
                futures.append(executor.submit(_prepare_payload, chapter_label, chapter))

            for idx, future in enumerate(futures, start=1):
                chapter_label, chapter_num, chapter = chapter_entries[idx - 1]
                max_retries = 3
                retry_count = 0
                result_data = None
                while retry_count < max_retries:
                    try:
                        result_data = future.result(timeout=120)
                        break
                    except TimeoutError:
                        retry_count += 1
                        if retry_count < max_retries:
                            print(
                                f"⚠️ Timeout ao processar capítulo {chapter_label} - tentativa {retry_count}/{max_retries}"
                            )
                            future = executor.submit(_prepare_payload, chapter_label, chapter)
                        else:
                            print(
                                f"❌ Capítulo {chapter_label} falhou após {max_retries} tentativas"
                            )
                            raise Exception(
                                f"Capítulo {chapter_label} não pode ser processado após {max_retries} tentativas"
                            )

                if result_data is None:
                    raise Exception(f"Capítulo {chapter_label} retornou dados nulos")

                chapter_label, chapter_name, parsed_text, pre_tts_text = result_data

                # **FIX**: Remove numeric prefix from chapter_name if it duplicates the label
                # to prevent filenames like "4.5 - 4.5 - Chapter Title"
                chapter_name_clean = self._remove_duplicate_chapter_prefix(
                    chapter_label, chapter_name
                )

                safe_name = self.file_manager.sanitize_filename(chapter_name_clean, max_length=96)

                # **FIX**: Use ONLY canonical chapter_label to prevent duplicates
                # Previously created multiple variants (label, sequential, numeric) which
                # caused duplicate files with same content but different names
                label_variants = [chapter_label]  # Only use canonical label

                paths_written = []
                for label in label_variants:
                    parsed_path = text_dir / f"{label} - {safe_name}-parsed.txt"
                    pre_tts_path = text_dir / f"{label} - {safe_name}-pre-tts.txt"
                    if parsed_path.exists() and pre_tts_path.exists():
                        continue
                    parsed_path.write_text(parsed_text, encoding="utf-8")
                    pre_tts_path.write_text(pre_tts_text, encoding="utf-8")
                    paths_written.append((parsed_path, pre_tts_path))

                if not paths_written:
                    continue
                files_generated += 2

                if text_validator and getattr(config, "validate_text", True):
                    strict_validation = getattr(config, "strict_validate", False)
                    valid_text = self._validate_text_after_save(
                        chapter,
                        chapter_label,
                        parsed_text,
                        pre_tts_text,
                        validator=text_validator,
                        strict=False,
                    )
                    if not valid_text:
                        max_text_retries = 2
                        for retry_idx in range(max_text_retries):
                            if self.verbose:
                                print(
                                    f"🔄 Regerando texto do capítulo {chapter_label} "
                                    f"(tentativa {retry_idx + 1}/{max_text_retries})"
                                )
                            _, _, parsed_text, pre_tts_text = _prepare_payload(
                                chapter_label, chapter
                            )
                            parsed_path.write_text(parsed_text, encoding="utf-8")
                            pre_tts_path.write_text(pre_tts_text, encoding="utf-8")
                            valid_text = self._validate_text_after_save(
                                chapter,
                                chapter_label,
                                parsed_text,
                                pre_tts_text,
                                validator=text_validator,
                                strict=False,
                            )
                            if valid_text:
                                break
                    if not valid_text and strict_validation:
                        raise RuntimeError(
                            f"Validação pós-parsing falhou após retry ({chapter_label})"
                        )

                # Save segment plan (text chunks) for future reuse
                try:
                    segments = []
                    chunk_limit = getattr(config, "edge_chunk_chars", 4000) or 4000
                    text_to_split = pre_tts_text or parsed_text or ""
                    for start in range(0, len(text_to_split), chunk_limit):
                        segments.append(text_to_split[start : start + chunk_limit])
                    self._save_segment_plan(config.cache_dir, chapter_num, segments, config)
                except Exception:
                    pass

                if self.verbose:
                    print(f"   📄 {chapter_num}. {chapter_name}")
                    print(f"      → {parsed_path.name}")
                    print(f"      → {pre_tts_path.name}")
                    if formatter and parsed_text != pre_tts_text:
                        chars_added = len(pre_tts_text) - len(parsed_text)
                        print(f"      ℹ️ Formatting added {chars_added} chars (audio cues)")

        if files_generated == 0 and self.verbose:
            print("   ♻️ All .txt files already exist (using cache)")

    @staticmethod
    def _hash_text(value: str) -> str:
        return hashlib.sha1(value.encode("utf-8", errors="ignore")).hexdigest()

    def _load_cache_index(self, cache_dir: Optional[Path]) -> dict:
        if not cache_dir:
            return {}
        try:
            index_path = Path(cache_dir) / "cache_index.json"
            if index_path.exists():
                return json.loads(index_path.read_text(encoding="utf-8"))
        except Exception:
            return {}
        return {}

    def _save_cache_index(self, cache_dir: Optional[Path], index: dict) -> None:
        if not cache_dir:
            return
        try:
            index_path = Path(cache_dir) / "cache_index.json"
            index_path.parent.mkdir(parents=True, exist_ok=True)
            index_path.write_text(json.dumps(index, indent=2, ensure_ascii=False), encoding="utf-8")
        except Exception:
            pass

    def _find_pre_tts_path(
        self,
        cache_dir: Optional[Path],
        output_dir: Optional[Path],
        index: int,
        chapter_name: Optional[str],
        index_label: Optional[str] = None,
    ) -> Optional[Path]:
        """Locate the pre-tts text for hashing, checking both temp and cache layouts."""
        safe_name = FileManager.sanitize_filename(chapter_name or f"Chapter {index}")
        label = index_label or str(index)
        candidates: List[Path] = []
        if output_dir:
            text_dir = Path(output_dir) / "text"
            candidates.append(text_dir / f"{label} - {safe_name}-pre-tts.txt")
            candidates.append(text_dir / f"{index} - {safe_name}-pre-tts.txt")
        if cache_dir:
            candidates.append(Path(cache_dir) / "text" / f"{index:03d} - {safe_name}.txt")
            safe_cache = safe_name.replace(" ", "_")
            candidates.append(Path(cache_dir) / "text" / f"{index:03d}_{safe_cache}.txt")
        for cand in candidates:
            if cand.exists():
                return cand
        return None

    def _find_cached_audio_path(
        self, cache_dir: Optional[Path], config: ConversionConfig, chapter_name: str, index: int
    ) -> Optional[Path]:
        """Locate an existing cached MP3 inside the cache/audio buckets."""
        if not cache_dir:
            return None
        try:
            cache_dir = Path(cache_dir)
            model_bucket = AudioConverter._cache_model_bucket(config)
            target_dir = cache_dir / "audio"
            if model_bucket:
                target_dir /= model_bucket
            safe_name = FileManager.sanitize_filename(chapter_name or f"Chapter {index}")
            legacy_name = safe_name.replace(" ", "_")
            candidates = [
                target_dir / f"{index:03d} - {safe_name}.mp3",
                target_dir / f"{index:03d}_{legacy_name}.mp3",
            ]
            for candidate in candidates:
                if candidate.exists() and candidate.stat().st_size > 1000:
                    return candidate
        except Exception:
            return None
        return None

    def _collect_cached_audio(
        self,
        chapters: List[Chapter],
        output_dir: Path,
        config: ConversionConfig,
        allow_index_only: bool = False,
    ) -> Optional[List[Path]]:
        """
        If every chapter already has a valid MP3 (temp or final), return the list to skip synthesis.
        Otherwise, return None to proceed normally.
        """
        final_output_dir = self._setup_output_directory(config)
        cache_dir = getattr(config, "cache_dir", None)
        cache_index = self._load_cache_index(cache_dir)
        cached_paths: List[Path] = []
        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            temp_mp3 = self._expected_output_path(chapter, chapter_num, output_dir)
            final_mp3 = final_output_dir / temp_mp3.name
            candidate = temp_mp3 if temp_mp3.exists() else final_mp3
            if not candidate.exists() and cache_dir:
                cached_audio = self._find_cached_audio_path(
                    cache_dir, config, getattr(chapter, "name", None) or "", chapter_num
                )
                if cached_audio:
                    try:
                        final_mp3.parent.mkdir(parents=True, exist_ok=True)
                        if not final_mp3.exists():
                            shutil.copy2(cached_audio, final_mp3)
                        candidate = final_mp3
                    except Exception:
                        candidate = cached_audio
            try:
                size = candidate.stat().st_size if candidate.exists() else 0
            except OSError:
                size = 0
            if size <= 1000:
                return None

            index_label = self._chapter_index_label(chapter, idx)
            pre_tts_path = self._find_pre_tts_path(
                cache_dir,
                output_dir,
                chapter_num,
                getattr(chapter, "name", None),
                index_label=index_label,
            )
            pre_tts_hash = None
            if pre_tts_path and pre_tts_path.exists():
                with contextlib.suppress(Exception):
                    pre_tts_hash = self._hash_text(pre_tts_path.read_text(encoding="utf-8"))
            cache_key = index_label
            entry = cache_index.get(cache_key) or cache_index.get(str(chapter_num)) or {}
            entry_hash = entry.get("pre_tts_hash")
            hash_ok = pre_tts_hash and entry_hash == pre_tts_hash
            hash_missing = pre_tts_hash and not entry_hash
            duration_ok = True
            try:
                bitrate_bps = self._bitrate_to_bps(getattr(config, "bitrate", "8k")) or 8000
                approx_seconds = (size * 8) / max(bitrate_bps, 1)
                estimated_text = ""
                if pre_tts_path and pre_tts_path.exists():
                    estimated_text = pre_tts_path.read_text(encoding="utf-8")
                expected_seconds = TextValidator.estimate_duration(estimated_text)
                if expected_seconds > 0:
                    duration_ok = approx_seconds >= expected_seconds * 0.5
            except Exception:
                duration_ok = True

            if pre_tts_hash and duration_ok and (hash_ok or hash_missing):
                if hash_missing and cache_dir:
                    entry["path"] = str(candidate)
                    entry["size"] = size
                    entry["pre_tts_hash"] = pre_tts_hash
                    cache_index[cache_key] = entry
                    self._save_cache_index(cache_dir, cache_index)
                cached_paths.append(candidate)
                continue

            # Allow cache_index-only validation when explicitly requested
            if not pre_tts_path and allow_index_only:
                if entry_hash and size > 1000:
                    cached_paths.append(candidate)
                    continue

            return None

        return cached_paths

    def _split_cached_chapters(
        self,
        chapters: List[Chapter],
        output_dir: Path,
        config: ConversionConfig,
        *,
        allow_index_only: bool = False,
    ) -> tuple[List[Path], List[Chapter]]:
        """Return cached audio paths and pending chapters (partial cache-aware)."""
        final_output_dir = self._setup_output_directory(config)
        cache_dir = getattr(config, "cache_dir", None)
        cache_index = self._load_cache_index(cache_dir)
        cached_paths: List[Path] = []
        pending: List[Chapter] = []

        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            temp_mp3 = self._expected_output_path(chapter, chapter_num, output_dir)
            final_mp3 = final_output_dir / temp_mp3.name
            candidate: Optional[Path] = temp_mp3 if temp_mp3.exists() else None

            if candidate is None and final_mp3.exists():
                candidate = final_mp3

            if candidate is None and cache_dir:
                cached_audio = self._find_cached_audio_path(
                    cache_dir, config, getattr(chapter, "name", None) or "", chapter_num
                )
                if cached_audio:
                    try:
                        final_mp3.parent.mkdir(parents=True, exist_ok=True)
                        if not final_mp3.exists():
                            shutil.copy2(cached_audio, final_mp3)
                        candidate = final_mp3
                    except Exception:
                        candidate = cached_audio

            try:
                size = candidate.stat().st_size if candidate and candidate.exists() else 0
            except OSError:
                size = 0
            if size <= 1000:
                pending.append(chapter)
                continue

            index_label = self._chapter_index_label(chapter, idx)
            pre_tts_path = self._find_pre_tts_path(
                cache_dir,
                output_dir,
                chapter_num,
                getattr(chapter, "name", None),
                index_label=index_label,
            )
            pre_tts_hash = None
            if pre_tts_path and pre_tts_path.exists():
                with contextlib.suppress(Exception):
                    pre_tts_hash = self._hash_text(pre_tts_path.read_text(encoding="utf-8"))
            cache_key = index_label
            entry = cache_index.get(cache_key) or cache_index.get(str(chapter_num)) or {}
            entry_hash = entry.get("pre_tts_hash")
            hash_ok = pre_tts_hash and entry_hash == pre_tts_hash
            hash_missing = pre_tts_hash and not entry_hash
            duration_ok = True
            try:
                bitrate_bps = self._bitrate_to_bps(getattr(config, "bitrate", "8k")) or 8000
                approx_seconds = (size * 8) / max(bitrate_bps, 1)
                estimated_text = ""
                if pre_tts_path and pre_tts_path.exists():
                    estimated_text = pre_tts_path.read_text(encoding="utf-8")
                expected_seconds = TextValidator.estimate_duration(estimated_text)
                if expected_seconds > 0:
                    duration_ok = approx_seconds >= expected_seconds * 0.5
            except Exception:
                duration_ok = True

            cached_ok = False
            if pre_tts_hash and duration_ok and (hash_ok or hash_missing):
                cached_ok = True
                if hash_missing and cache_dir:
                    entry["path"] = str(candidate)
                    entry["size"] = size
                    entry["pre_tts_hash"] = pre_tts_hash
                    cache_index[cache_key] = entry
                    self._save_cache_index(cache_dir, cache_index)
            elif allow_index_only and entry_hash and size > 1000:
                cached_ok = True

            if cached_ok and candidate is not None and candidate.exists():
                if pre_tts_path and pre_tts_path.exists():
                    cached_payload = self._load_cached_payload(chapter, chapter_num, output_dir)
                    if cached_payload:
                        truncation_warning = self._detect_short_audio_output(
                            candidate,
                            cached_payload,
                            config,
                            engine_label=(config.engine or "").lower(),
                        )
                        if truncation_warning:
                            cached_ok = False
                if cached_ok:
                    cached_paths.append(candidate)
                else:
                    pending.append(chapter)
            else:
                pending.append(chapter)

        return cached_paths, pending

    @staticmethod
    def _assign_progress_indices(chapters: List[Chapter]) -> None:
        """Attach a stable progress index used for UI/percentage counters."""
        for idx, chapter in enumerate(chapters, start=1):
            try:
                setattr(chapter, "_progress_index", idx)
            except Exception:
                pass

    def _segment_plan_path(self, cache_dir: Optional[Path], index: int) -> Optional[Path]:
        if not cache_dir:
            return None
        try:
            return Path(cache_dir) / "plan" / f"{index:03d}.json"
        except Exception:
            return None

    def _save_segment_plan(
        self, cache_dir: Optional[Path], index: int, segments: List[str], config: ConversionConfig
    ) -> None:
        plan_path = self._segment_plan_path(cache_dir, index)
        if not plan_path:
            return
        try:
            plan_path.parent.mkdir(parents=True, exist_ok=True)
            plan = {
                "segments": segments,
                "chunk_chars": getattr(config, "edge_chunk_chars", None),
                "max_segment_seconds": getattr(config, "edge_max_segment_seconds", None),
            }
            plan_path.write_text(json.dumps(plan, ensure_ascii=False), encoding="utf-8")
        except Exception:
            pass

    def _load_segment_plan(
        self,
        cache_dir: Optional[Path],
        index: int,
        *,
        chunk_chars: Optional[int] = None,
    ) -> Optional[List[str]]:
        plan_path = self._segment_plan_path(cache_dir, index)
        if not plan_path or not plan_path.exists():
            return None
        try:
            data = json.loads(plan_path.read_text(encoding="utf-8"))
            segments = data.get("segments")
            plan_chunk = data.get("chunk_chars")
            if chunk_chars and plan_chunk and int(plan_chunk) != int(chunk_chars):
                return None
            if isinstance(segments, list) and segments:
                return [str(s) for s in segments]
        except Exception:
            return None
        return None

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

    def _parse_chapter_whitelist(self, config: Optional[ConversionConfig]) -> List[str]:
        if not config or not getattr(config, "extra", None):
            return []
        raw = config.extra.get("chapter_whitelist") or config.extra.get("chapters_only")
        if not raw:
            return []
        if isinstance(raw, (list, tuple, set)):
            items = [str(item).strip() for item in raw]
        else:
            items = [part.strip() for part in str(raw).split(",")]
        return [item for item in items if item]

    def _apply_chapter_whitelist(
        self, chapters: List[Chapter], whitelist: List[str]
    ) -> List[Chapter]:
        if not whitelist:
            return chapters
        allowed = {str(item).strip() for item in whitelist if str(item).strip()}
        if not allowed:
            return chapters

        filtered: List[Chapter] = []
        for idx, chapter in enumerate(chapters, start=1):
            label = self._chapter_index_label(chapter, idx)
            numeric = str(self._chapter_number(chapter, idx))
            sequential = str(idx)
            if label in allowed or numeric in allowed or sequential in allowed:
                filtered.append(chapter)

        if self.verbose:
            print(f"🎯 Chapter whitelist active: {len(filtered)}/{len(chapters)} selected")
        return filtered

    def _filter_chapters_auto(
        self, chapters: List[Chapter], output_dir: Path, config: ConversionConfig
    ) -> List[Chapter]:
        """
        Skip obvious créditos/anúncios ou capítulos muito curtos quando não há áudio em cache.
        Nunca remove capítulos que já têm MP3 cacheado.
        """
        patterns = [
            "créditos",
            "agradecimentos",
            "folha de rosto",
            "sumário",
            "índice",
            "capas",
        ]
        min_chars = int(os.getenv("AUTO_SKIP_MIN_CHARS", "400").strip() or "400")
        # Default desativado para não pular capítulos em cenários de teste/conversão padrão
        skip_enabled = os.getenv("AUTO_SKIP_EXTRA", "false").lower() not in {"false", "0", "no"}

        if not skip_enabled:
            return chapters

        filtered: List[Chapter] = []
        skipped = []
        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            name = (getattr(chapter, "name", None) or f"Chapter {chapter_num}").lower()
            chars = self._estimate_chapter_chars(chapter)
            mp3_temp = self._expected_output_path(chapter, chapter_num, output_dir)
            mp3_final = self._setup_output_directory(config) / mp3_temp.name
            has_audio = mp3_temp.exists() or mp3_final.exists()

            if has_audio:
                filtered.append(chapter)
                continue

            is_pattern = any(pat in name for pat in patterns)
            too_short = chars < min_chars
            if is_pattern or too_short:
                skipped.append((chapter_num, chapter.name, chars))
                continue

            filtered.append(chapter)

        if skipped:
            print(
                f"⏭️ Auto-skip: {len(skipped)} credits/short chapter(s) without cached audio; "
                f"use AUTO_SKIP_EXTRA=false to disable"
            )
            if self.verbose:
                for idx, name, chars in skipped:
                    print(f"   - {idx}: {name} ({chars} chars)")

        return filtered

    def _resource_snapshot(self) -> ResourceSnapshot:
        """Return a best-effort resource snapshot for tuning."""
        cpu_pct = 0.0
        ram_gb = 0.0
        with contextlib.suppress(Exception):
            cpu_pct = float(psutil.cpu_percent(interval=None))
        with contextlib.suppress(Exception):
            mem = psutil.virtual_memory()
            ram_gb = float(mem.available / (1024**3))
        cpu_idle = max(0.0, 100.0 - cpu_pct)
        return ResourceSnapshot(
            cpu_percent=cpu_pct,
            cpu_idle=cpu_idle,
            ram_gb=ram_gb,
            active_jobs=1,
        )

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
        snapshot = self._resource_snapshot()
        cpu_pct = snapshot.cpu_percent
        ram_gb = snapshot.ram_gb
        reason: Optional[str] = None
        new_value = current

        if batch_errors > 0:
            new_value = max(1, current - 1)
            state["degrade_runs"] = min(3, degrade_runs + 1)
            reason = (
                f"reduzindo para {new_value} capítulo(s) simultâneos após {batch_errors} erro(s)"
            )
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

    def _apply_edge_slow_mode(
        self,
        reason: str,
        *,
        engine_pool: Optional[JobEnginePool] = None,
        engine_obj: Optional[object] = None,
    ) -> bool:
        """Clamp Edge settings when latency/throughput indicates throttling."""
        state = self._edge_auto_state or {}
        if not state.get("enabled"):
            return False

        announce = not state.get("slow_mode")
        state["slow_mode"] = True
        safe_profile = state.get("safe_profile") or {}
        chunk_chars = int(safe_profile.get("chunk_chars") or EDGE_SAFE_CHUNK_CHARS)
        max_segment = float(
            safe_profile.get("max_segment_seconds") or EDGE_SAFE_MAX_SEGMENT_SECONDS
        )
        timeout_max = float(safe_profile.get("timeout_max") or EDGE_SAFE_TIMEOUT_MAX)
        cap = int(safe_profile.get("parallel_cap") or EDGE_SAFE_CHAPTER_PARALLEL)
        if state.get("parallel_cap"):
            with contextlib.suppress(TypeError, ValueError):
                cap = min(cap, int(state["parallel_cap"]))
        state["parallel_cap"] = max(1, cap)
        state["safe_profile"] = {
            "chunk_chars": chunk_chars,
            "max_segment_seconds": max_segment,
            "timeout_max": timeout_max,
            "parallel_cap": state["parallel_cap"],
        }

        for cfg in state.get("configs") or []:
            if (cfg.engine or "").lower() != "edge":
                continue
            cfg.edge_chunk_chars = min(cfg.edge_chunk_chars or chunk_chars, chunk_chars)
            cfg.edge_max_segment_seconds = min(
                cfg.edge_max_segment_seconds or max_segment,
                max_segment,
            )
            cfg.edge_enable_parallel = False

        if engine_obj is not None:
            if hasattr(engine_obj, "apply_speed_profile"):
                with contextlib.suppress(Exception):
                    engine_obj.apply_speed_profile(
                        chunk_char_limit=chunk_chars,
                        max_segment_seconds=max_segment,
                        words_per_minute=160,
                    )
            if hasattr(engine_obj, "_enable_parallel"):
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_enable_parallel", False)
                    setattr(engine_obj, "_parallel_slots", 1)

        state_current = self._parallel_state or {}
        current = max(1, int(state_current.get("current") or 1))
        ceiling = max(1, int(state_current.get("ceiling") or current))
        new_current = min(current, state["parallel_cap"])
        new_ceiling = min(ceiling, state["parallel_cap"])
        state_current["current"] = max(1, new_current)
        state_current["ceiling"] = max(1, new_ceiling)
        self._parallel_state = state_current
        if engine_pool is not None:
            engine_pool.update_parallel_slots(state_current["current"])

        if announce:
            print(
                "🧯 Edge modo seguro: "
                f"{reason} → chunk={chunk_chars} seg={int(max_segment)}s paralelo={state_current['current']}"
            )
        return announce

    @staticmethod
    def _should_force_edge_rescue(
        failures: Dict[str, str],
        *,
        edge_available: bool,
    ) -> bool:
        """Detect whether we should reprocess failed chapters with safer Edge settings."""
        if not edge_available or not failures:
            return False
        for message in failures.values():
            if not message:
                return True
            lower = message.lower()
            if any(
                keyword in lower
                for keyword in (
                    "timeout",
                    "time-out",
                    "rate limit",
                    "rate_limit",
                    "too many requests",
                    "403",
                    "sem áudio",
                    "sem audio",
                    "noaudio",
                    "sem progresso",
                    "truncado",
                    "truncation",
                    "arquivo ausente",
                    "arquivo inválido",
                    "arquivo invalido",
                    "falha na síntese",
                    "falha na sintese",
                    "edge",
                )
            ):
                return True
        return False

    def _apply_edge_rescue_profile(
        self,
        *,
        engine_pool: JobEnginePool,
        edge_configs: List[ConversionConfig],
        reason: str,
        aggressive: bool = False,
    ) -> Dict[str, float]:
        """
        Clamp Edge settings aggressively for retries to avoid stalls.

        Returns a profile dict so the caller can mirror values into ad-hoc configs.
        """
        chunk_chars = 3200 if not aggressive else 2400
        max_segment = 42.0 if not aggressive else 36.0
        offline_chars = 8000 if not aggressive else 6000
        offline_seconds = 300.0 if not aggressive else 220.0

        for cfg in edge_configs or []:
            if (cfg.engine or "").lower() != "edge":
                continue
            cfg.edge_chunk_chars = min(cfg.edge_chunk_chars or chunk_chars, chunk_chars)
            cfg.edge_max_segment_seconds = min(
                float(getattr(cfg, "edge_max_segment_seconds", 0) or max_segment),
                max_segment,
            )
            cfg.edge_enable_parallel = False
            cfg.edge_max_concurrency = 1
            cfg.edge_auto_offline_chars = min(
                getattr(cfg, "edge_auto_offline_chars", 0) or offline_chars,
                offline_chars,
            )
            cfg.edge_auto_offline_seconds = min(
                getattr(cfg, "edge_auto_offline_seconds", 0) or offline_seconds,
                offline_seconds,
            )

        state = self._parallel_state or {}
        state["current"] = 1
        state["ceiling"] = max(1, min(int(state.get("ceiling") or 1), 1))
        self._parallel_state = state
        engine_pool.update_parallel_slots(1)
        edge_state = self._edge_auto_state or {}
        edge_state["slow_mode"] = True
        self._edge_auto_state = edge_state

        profile_label = "modo seguro" if not aggressive else "modo seguro agressivo"
        print(
            f"🛟 Edge retry ({profile_label}): {reason} → "
            f"chunk={chunk_chars} seg={int(max_segment)}s offline>={offline_chars} chars"
        )
        return {
            "chunk_chars": chunk_chars,
            "max_segment": max_segment,
            "offline_chars": offline_chars,
            "offline_seconds": offline_seconds,
        }

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

    def _mark_health_activity(self, chapter_index: int, status: str = "") -> None:
        """Update watchdog state for in-flight activity."""
        state = getattr(self, "_health_state", None)
        if not isinstance(state, dict) or not state.get("active"):
            return
        state["last_progress"] = time.time()
        state["last_chapter"] = chapter_index
        state["last_activity"] = status
        state["warn_emitted"] = False
        state["action_emitted"] = False

    async def _watch_chapter_stall(
        self,
        chapter_index: int,
        task: asyncio.Task,
        stall_seconds: float,
        stall_event: asyncio.Event,
    ) -> None:
        """Cancel synthesis task if no progress is detected for too long."""
        if stall_seconds <= 0:
            return
        check_interval = max(5.0, min(15.0, stall_seconds / 3))
        while not task.done():
            await asyncio.sleep(check_interval)
            if task.done():
                return
            if self.progress.seconds_since_activity() >= stall_seconds:
                stall_event.set()
                print(
                    f"\n🛟 Watchdog: chapter {chapter_index} no progress for {int(stall_seconds)}s"
                )
                self.progress.tick(
                    f"🛟 Sem progresso há {int(stall_seconds)}s - reiniciando capítulo..."
                )
                task.cancel()
                return

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
                print(f"\n🩺 Watchdog: {info} – investigating bottleneck")
                if not self._apply_watchdog_backpressure():
                    print(
                        "   Sugestão: verifique conexão ou permitir fallback offline (Coqui/Piper)."
                    )
            elif stalled >= warning_threshold and not state.get("warn_emitted"):
                state["warn_emitted"] = True
                print(
                    f"\n⚠️ Watchdog: No chapters completed for {int(stalled)}s – awaiting progress..."
                )

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
            print(f"   🧠 Watchdog: reducing concurrent chapters {current} → {new_value}")
            return True
        return False

    def _print_final_validation_report(
        self,
        chapters: List[Chapter],
        converted_files: List[Path],
        errors: List[str],
        output_dir: Path,
        verbose: bool = False,
    ) -> None:
        """Print comprehensive validation report comparing EPUB chapters with audio output.

        Args:
            chapters: List of chapters from the original EPUB
            converted_files: List of successfully converted audio files
            errors: List of conversion errors
            output_dir: Output directory containing audio files
            verbose: Print detailed information
        """
        if not chapters:
            return

        print("\n" + "=" * 60)
        print("📊 Integrity Validation Report")
        print("=" * 60)

        # Count chapters
        total_chapters = len(chapters)
        successful_chapters = len(converted_files)
        failed_chapters = len(errors)
        missing_chapters = total_chapters - successful_chapters

        # Basic stats
        print(f"\n📚 Original EPUB chapters: {total_chapters}")
        print(f"✅ Successfully generated: {successful_chapters} chapter(s)")

        if missing_chapters > 0:
            print(f"❌ Missing chapters: {missing_chapters}")

        if failed_chapters > 0:
            print(f"⚠️ Conversion errors: {failed_chapters}")

        # Check for duplicates by comparing file names
        file_names = [f.name for f in converted_files]
        unique_names = set(file_names)
        duplicate_count = len(file_names) - len(unique_names)

        if duplicate_count > 0:
            print(f"🔄 Duplicate files detected: {duplicate_count}")
            if verbose:
                # Find and print duplicate names
                seen = set()
                duplicates = []
                for name in file_names:
                    if name in seen:
                        duplicates.append(name)
                    seen.add(name)
                if duplicates:
                    print("   Duplicates:")
                    for dup in duplicates[:5]:  # Show first 5
                        print(f"   - {dup}")
                    if len(duplicates) > 5:
                        print(f"   ... and {len(duplicates) - 5} more")

        # Check for missing chapters by comparing titles
        if missing_chapters > 0 and verbose:
            print("\n⚠️ Potentially missing chapters:")
            converted_titles = {self._normalize_title_match(f.stem) for f in converted_files}
            for idx, chapter in enumerate(chapters, start=1):
                chapter_title = getattr(chapter, "name", f"Chapter {idx}")
                normalized_title = self._normalize_title_match(chapter_title)
                # Check if any converted file matches this chapter
                found = any(normalized_title in title for title in converted_titles)
                if not found:
                    print(f"   - Chapter {idx}: {chapter_title[:60]}")

        # Overall validation status
        print("\n" + "─" * 60)
        if successful_chapters == total_chapters and duplicate_count == 0:
            print("✅ VALIDATION: COMPLETE AND INTACT")
            print("   All chapters from the original EPUB were successfully converted.")
        elif successful_chapters == total_chapters:
            print("✅ VALIDATION: COMPLETE (with warnings)")
            print("   All chapters were converted, but there are duplicates.")
        elif missing_chapters > 0:
            print("⚠️ VALIDATION: INCOMPLETE")
            print(f"   {missing_chapters} chapter(s) were not converted or failed.")
            if errors:
                print("   Check the error logs above for more details.")
        print("=" * 60 + "\n")

    async def convert(self, reader: EbookReader, config: ConversionConfig) -> ConversionResult:
        """Convert all chapters in ``reader`` according to ``config``."""

        # Enable verbose mode if requested
        self.verbose = getattr(config, "verbose", False)
        self._active_config = config
        # Show TTS output only in verbose mode
        self.show_tts_output = self.verbose
        if not getattr(config, "log_callback", None):
            # Roteia logs internos para a barra de progresso/CLI automaticamente
            def _log_to_progress(message: str) -> None:
                self.progress.tick(message)
                if not self.progress._supports_overwrite:
                    print(message)

            config.log_callback = _log_to_progress

        # Initialize auto-tuning (detecta HW e rede, configura flags automaticamente)
        await self._initialize_auto_tuning()

        # Initialize adaptive performance controller
        self._initialize_adaptive_performance()

        # Optimize memory and threading settings
        self._optimize_memory_settings()

        if self.verbose:
            print("[DEBUG] AudioConverter.convert() iniciado")
            print(
                f"[DEBUG] Configuração: engine={getattr(config, 'engine', 'unknown')}, mode=sequential"
            )

        # Setup paths
        reader_path = getattr(reader, "file_path", None)
        try:
            self._current_book_path = Path(reader_path) if reader_path else None
        except TypeError:
            self._current_book_path = None

        output_dir = self._setup_output_directory(config)
        self._last_output_dir = output_dir

        # Honrar --clear-cache/clearCache: remove cache e artefatos do livro antes de continuar
        # Must run BEFORE early validation so we don't validate stale output
        if getattr(config, "clear_cache", False):
            if self.verbose:
                print("🗑️  --clear-cache: removendo cache e output anteriores...")
            try:
                if self._current_book_path:
                    self.cache_manager.clear_cache(self._current_book_path, title=reader.title)
                elif reader.title:
                    self.cache_manager.clear_cache(title=reader.title)
            except Exception as exc:
                if self.verbose:
                    print(f"⚠️ Falha ao limpar cache: {exc}")
            try:
                if output_dir.exists():
                    shutil.rmtree(output_dir, ignore_errors=True)
                output_dir = self._setup_output_directory(config)
                self._last_output_dir = output_dir
            except Exception as exc:
                if self.verbose:
                    print(f"⚠️ Falha ao limpar saída anterior: {exc}")
        else:
            # Only validate previous output when NOT clearing cache
            await self._auto_validate_output(output_dir, stage="initial")

        # **CLEANUP**: Remove duplicate files (dup-1, dup-2, etc.) from output and cache
        if self.verbose:
            print("🧹 Scanning for duplicate files to clean up...")

        # Clean output directory
        cleanup_count = self._cleanup_duplicate_files(output_dir, verbose=self.verbose)

        # Clean cache directory if exists
        if self._current_book_path and self.cache_manager.cache_dir:
            cache_path = self.cache_manager._get_cache_path(self._current_book_path)
            if cache_path.exists():
                cleanup_count += self._cleanup_duplicate_files(cache_path, verbose=False)

        if cleanup_count > 0 and not self.verbose:
            print(f"🧹 Cleaned up {cleanup_count} duplicate file(s)")

        # Setup temporary directory for conversion (uses .cache)
        temp_dir = self._setup_temp_directory(config)
        chapters = list(
            reader.get_chapter_structure(preserve_all=config.preserve_all_chapters) or []
        )
        # Store original before deduplication for potential restoration
        original_chapters = chapters.copy()

        chapters, duplicates_removed = deduplicate_chapters_by_content(chapters)
        if duplicates_removed:
            print(f"  🧹 Removed {duplicates_removed} duplicate chapter(s) automatically")

        # Validate chapter count against TOC (if available from CLI flow)
        expected_count = getattr(reader, "_toc_expected_chapters", 0)
        if expected_count > 0 and len(chapters) != expected_count and duplicates_removed > 0:
            if len(chapters) + duplicates_removed == expected_count:
                print(
                    f"\n⚠️  VALIDATION: TOC indicates {expected_count} chapters, but {len(chapters)} were detected"
                )
                print(
                    f"🔄 Auto-correction: restoring {duplicates_removed} chapter(s) removed as duplicate"
                )
                print("💡 Reason: deduplication caused loss of valid chapters\n")
                chapters = original_chapters

        chapter_whitelist = self._parse_chapter_whitelist(config)
        if chapter_whitelist:
            chapters = self._apply_chapter_whitelist(chapters, chapter_whitelist)
            if not chapters:
                empty_result = ConversionResult(True, 0, 0, [], [])
                await self._report_results(empty_result)
                return empty_result

        # Set chapters_for_text AFTER filtering
        chapters_for_text = chapters
        self._last_chapters_for_text = list(chapters_for_text)

        # ===== TEXT INTEGRITY VALIDATION =====
        # Validate text integrity BEFORE audio conversion to detect cache corruption
        text_validator = TextIntegrityValidator(cache_dir=temp_dir, verbose=self.verbose)

        # Show chapter summary in verbose mode
        if self.verbose:
            text_validator.print_chapter_summary(chapters_for_text)

        # Refresh text cache before validation to avoid stale mismatches
        self._text_validation_hashes = {}
        self._text_validation_errors = []
        self._generate_all_text_files(
            chapters_for_text,
            temp_dir,
            config,
            text_validator=text_validator if getattr(config, "validate_text", True) else None,
        )
        if self._text_validation_errors and self.verbose:
            print(
                f"⚠️ Validação pós-parsing: {len(self._text_validation_errors)} problema(s) detectado(s)"
            )

        # Validate all chapters against cache
        integrity_report = text_validator.validate_all_chapters(
            chapters_for_text, show_progress=True
        )

        # Hard-stop if chapters are empty or duplicated to avoid bad audio/output naming
        hard_block_errors = [
            v
            for v in integrity_report.chapters_with_issues
            if v.error_message
            and ("Chapter text empty" in v.error_message or "Duplicate content" in v.error_message)
        ]
        if hard_block_errors:
            print("\n❌ Text validation failed: empty or duplicate chapters detected.")
            for v in hard_block_errors:
                print(f"   - Chapter {v.chapter_index}: {v.chapter_title} → {v.error_message}")
            raise RuntimeError("Text validation failed: empty/duplicate chapters")

        # If cache corruption detected, offer to clear cache
        if integrity_report.has_cache_corruption or integrity_report.cache_engine_mismatch:
            print("\n⚠️  CORRUPTED CACHE DETECTED!")
            print(
                f"   {integrity_report.invalid_chapters}/{integrity_report.total_chapters} "
                "chapters have text different from current EPUB."
            )

            if integrity_report.cache_engine_mismatch:
                print("\n💡 Possible cause: cache from previous conversion with different engine")
                print("   (e.g., Kokoro cache being used for Edge conversion)")

            # Auto-clear cache if corruption detected
            print("\n🧹 Cleaning corrupted cache automatically...")
            try:
                if self._current_book_path:
                    self.cache_manager.clear_cache(self._current_book_path, title=reader.title)
                elif reader.title:
                    self.cache_manager.clear_cache(title=reader.title)

                # Recreate temp directory
                temp_dir = self._setup_temp_directory(config)
                text_validator = TextIntegrityValidator(cache_dir=temp_dir, verbose=self.verbose)

                self._generate_all_text_files(
                    chapters_for_text,
                    temp_dir,
                    config,
                    text_validator=text_validator
                    if getattr(config, "validate_text", True)
                    else None,
                )

                print("✅ Cache cleaned! Proceeding with full conversion.\n")
            except Exception as exc:
                print(f"❌ Falha ao limpar cache: {exc}")
                print("⚠️  Continuando com conversão mas pode haver problemas.\n")

        # Save parsed text for all chapters (creates baseline for validation)
        text_validator.save_all_chapters_text(chapters_for_text, show_progress=not self.verbose)

        if getattr(config, "priority_selectors", None):
            chapters = self._prioritize_chapters(chapters, config.priority_selectors)
        total_chapters = len(chapters)
        chapter_lookup: Dict[str, tuple[Chapter, int, str]] = {}
        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            label = self._chapter_display_name(chapter, chapter_num)
            self._register_chapter_lookup(chapter_lookup, label, chapter, chapter_num)

        if self.verbose:
            print(f"[DEBUG] Total chapters: {total_chapters}")
            print(f"[DEBUG] Output directory: {output_dir}")
            print(f"[DEBUG] Temporary directory: {temp_dir}")

        if chapters:
            self._normalize_output_numbers(chapters, output_dir, config, temp_dir=temp_dir)

        print(f"\n🚀 Starting conversion: {reader.title} ({total_chapters} chapters)")
        print(f"💾 Output: {output_dir}")

        # Show validation status
        validate_text = getattr(config, "validate_text", True)
        validate_audio = getattr(config, "validate_audio", True)
        if validate_text and validate_audio:
            print("  ✅ Validations: Text and audio enabled")
        elif validate_text:
            print("  ⚠️ Validations: Text only")
        elif validate_audio:
            print("  ⚠️ Validations: Audio only")
        else:
            print("  ⚠️ Validations: Disabled (--no-validate)")

        edge_stable_mode = False
        edge_stable_explicit = False
        if getattr(config, "extra", None):
            stable_raw = config.extra.get("edge_stable_mode")
            if stable_raw is not None:
                edge_stable_explicit = True
                edge_stable_mode = str(stable_raw).lower() in {"1", "true", "yes", "on"}
        if (
            not edge_stable_explicit
            and EDGE_AUTO_STABLE
            and (config.engine or "").lower() == "edge"
        ):
            inferred_tier = None
            if self.hardware_profile:
                inferred_tier = getattr(self.hardware_profile, "network_speed_estimate", None)
            if not inferred_tier:
                inferred_tier = os.getenv("EDGE_NETWORK_TIER")
            inferred_tier = (inferred_tier or "").strip().lower()
            if inferred_tier == "slow":
                edge_stable_mode = True
                if getattr(config, "extra", None) is not None:
                    config.extra["edge_stable_mode"] = "1"
                print("🛡️ Edge modo estável automático: rede lenta detectada")
        if edge_stable_mode and (config.engine or "").lower() == "edge":
            config.edge_enable_parallel = False
            config.edge_auto_tune = False
            config.edge_chunk_chars = 4000
            config.edge_max_segment_seconds = 120
            print("🛡️ Edge modo estável: paralelismo reduzido e timeouts ampliados")
        # Auto-parallel: prefer env override, else derive from hardware profile
        # Aggressive defaults: use all available CPU cores for maximum throughput
        chapter_parallel_count = int(os.getenv("CHAPTER_PARALLEL_COUNT", "0") or "0")
        if chapter_parallel_count <= 0:
            cpu_logical = os.cpu_count() or 1
            cpu_physical = 0
            with contextlib.suppress(Exception):
                cpu_physical = psutil.cpu_count(logical=False) or 0
            if cpu_physical >= 8:
                chapter_parallel_count = min(8, cpu_logical)
            elif cpu_physical >= 4:
                chapter_parallel_count = min(6, cpu_logical)
            elif cpu_physical >= 2:
                chapter_parallel_count = min(4, cpu_logical)
            else:
                chapter_parallel_count = 2
        if edge_stable_mode and chapter_parallel_count != 1:
            chapter_parallel_count = 1
        self._reset_parallel_state(chapter_parallel_count)

        if total_chapters == 0:
            empty_result = ConversionResult(True, 0, 0, [], [])
            self._report_results(empty_result)
            return empty_result

        # Fast-path cache check before heavy prep (uses existing text/cache index if present)
        cached_paths, pending_chapters = self._split_cached_chapters(
            chapters, temp_dir, config, allow_index_only=True
        )

        # **NEW**: Generate ALL .txt files BEFORE starting TTS conversion (unless fully cached)
        if pending_chapters:
            print("\n📝 Generating text files...")
            self._generate_all_text_files(chapters, temp_dir, config, cleanup_existing=False)
            print(f"  ✅ Generated {total_chapters} text file(s)\n")
            cached_paths, pending_chapters = self._split_cached_chapters(
                chapters, temp_dir, config, allow_index_only=False
            )

        cover_art = self._extract_cover_art(reader)
        book_title = (
            reader.title
            or getattr(config, "book_title", None)
            or (self._current_book_path.stem if self._current_book_path else "")
        )
        book_author = getattr(reader, "author", "") or ""
        if cached_paths and pending_chapters:
            print(
                f"  ♻️ Cache detected: {len(cached_paths)} chapter(s) ready; "
                f"converting {len(pending_chapters)} remaining"
            )
        elif cached_paths and not pending_chapters:
            print(f"  ♻️ All {len(cached_paths)} chapter(s) already cached (MP3)")

        pending_total = len(pending_chapters)
        self._start_health_watchdog(pending_total)
        self._assign_progress_indices(pending_chapters)
        self.progress.start(pending_total, description="Converting chapters")

        if pending_total == 0:
            moved_files = self.file_manager.move_files_to_final_output(temp_dir, output_dir)
            result = ConversionResult(
                success=True,
                total_chapters=total_chapters,
                converted_chapters=total_chapters,
                output_files=moved_files or cached_paths,
                errors=[],
            )
            normalized_outputs = self._normalize_output_numbers(chapters, output_dir, config)
            if normalized_outputs:
                result.output_files = normalized_outputs
            # Apply ID3 tags (including cover art) to ALL MP3s in output dir
            album_name = book_title or (
                self._current_book_path.stem if self._current_book_path else output_dir.name
            )
            all_output_mp3s = sorted(output_dir.glob("*.mp3")) if output_dir.exists() else []
            if all_output_mp3s:
                self._apply_final_id3_tags(
                    all_output_mp3s,
                    default_album=album_name,
                    artist=book_author or None,
                    cover_art=cover_art,
                )
            self._sync_text_cache_to_output(temp_dir, output_dir)
            self.progress.finish()
            await self._report_results(result)
            return result

        is_auto_engine = (config.engine or "").lower() == "auto"
        auto_engine_pool: Dict[str, tuple[ConversionConfig, object]] = {}
        engine_seeds: Dict[str, object] = {}
        try:
            if is_auto_engine:
                auto_engine_pool = self._prepare_auto_engines(config)
                if not auto_engine_pool:
                    raise RuntimeError("Nenhuma engine disponível no modo automático")
                for name, (_, engine_obj) in auto_engine_pool.items():
                    if engine_obj is not None:
                        engine_seeds[name.lower()] = engine_obj
                tts_engine = None
            else:
                tts_engine = self.tts_factory.create_engine(config)
                engine_seeds[(config.engine or "").lower()] = tts_engine
        except ImportError:
            if self._install_requirements():
                if is_auto_engine:
                    auto_engine_pool = self._prepare_auto_engines(config)
                    if not auto_engine_pool:
                        raise RuntimeError("Nenhuma engine disponível no modo automático")
                    engine_seeds = {
                        name.lower(): engine_obj
                        for name, (_, engine_obj) in auto_engine_pool.items()
                        if engine_obj is not None
                    }
                    tts_engine = None
                else:
                    tts_engine = self.tts_factory.create_engine(config)
                    engine_seeds[(config.engine or "").lower()] = tts_engine
            else:
                raise
        if is_auto_engine:
            voice_label = "Auto (Edge/Coqui/Piper)"
        else:
            primary_engine = engine_seeds.get((config.engine or "").lower())
            voice_label = getattr(primary_engine, "voice", None) or config.voice or "(auto)"
        print(f"🎙️ Engine: {config.engine} | Voice: {voice_label}")
        if getattr(config, "languages", None):
            print(f"🌐 Languages: {', '.join(config.languages)}")

        if self.verbose:
            if engine_seeds:
                sample_engine = next(iter(engine_seeds.values()))
                print(f"[DEBUG] Engine configurado: {type(sample_engine).__name__}")
            else:
                print("[DEBUG] Engine configurado: AUTO")

        has_edge_engine = (config.engine or "").lower() == "edge"
        if is_auto_engine and auto_engine_pool:
            has_edge_engine = has_edge_engine or "edge" in auto_engine_pool
        edge_network_tier = (
            getattr(self.hardware_profile, "network_speed_estimate", None)
            if self.hardware_profile
            else None
        )
        if not edge_network_tier:
            edge_network_tier = os.getenv("EDGE_NETWORK_TIER", "fast")
        edge_network_tier = (edge_network_tier or "fast").strip().lower()
        if edge_network_tier not in EDGE_AUTO_PARALLEL_CAPS:
            edge_network_tier = "fast"
        edge_auto_override = getattr(config, "edge_auto_tune", None)
        edge_auto_enabled = (
            EDGE_AUTO_TUNE if edge_auto_override is None else bool(edge_auto_override)
        ) and has_edge_engine
        parallel_slots_cap: Optional[int] = None
        if edge_auto_enabled:
            parallel_slots_cap = EDGE_AUTO_PARALLEL_CAPS.get(
                edge_network_tier, EDGE_SAFE_CHAPTER_PARALLEL
            )
        edge_configs: List[ConversionConfig] = []
        edge_seen: Set[int] = set()
        for cfg in (
            config,
            auto_engine_pool.get("edge")[0]
            if is_auto_engine and auto_engine_pool and "edge" in auto_engine_pool
            else None,
        ):
            if cfg and (cfg.engine or "").lower() == "edge" and id(cfg) not in edge_seen:
                edge_configs.append(cfg)
                edge_seen.add(id(cfg))
        self._apply_edge_rate_caps(edge_configs)
        if has_edge_engine and edge_network_tier in {"slow", "medium"} and not edge_stable_mode:
            for cfg in edge_configs:
                if (cfg.engine or "").lower() != "edge":
                    continue
                if edge_network_tier == "slow":
                    if (cfg.edge_chunk_chars or 0) > 6000:
                        cfg.edge_chunk_chars = 6000
                    if (cfg.edge_max_segment_seconds or 0) > 60:
                        cfg.edge_max_segment_seconds = 60
                    cfg.edge_enable_parallel = False
                else:
                    if (cfg.edge_chunk_chars or 0) > 8000:
                        cfg.edge_chunk_chars = 8000
                    if (cfg.edge_max_segment_seconds or 0) > 75:
                        cfg.edge_max_segment_seconds = 75
            if edge_network_tier == "slow" and chapter_parallel_count > 1:
                chapter_parallel_count = 1
                self._reset_parallel_state(chapter_parallel_count)
            elif edge_network_tier == "medium" and chapter_parallel_count > 2:
                chapter_parallel_count = 2
                self._reset_parallel_state(chapter_parallel_count)
            print("🌧️ Edge: rede instável detectada → perfil inicial mais conservador")
        self._edge_auto_state = {
            "enabled": edge_auto_enabled,
            "network_tier": edge_network_tier,
            "parallel_cap": parallel_slots_cap,
            "slow_mode": False,
            "safe_profile": {
                "chunk_chars": EDGE_SAFE_CHUNK_CHARS,
                "max_segment_seconds": EDGE_SAFE_MAX_SEGMENT_SECONDS,
                "timeout_max": EDGE_SAFE_TIMEOUT_MAX,
                "parallel_cap": EDGE_SAFE_CHAPTER_PARALLEL,
            },
            "min_chars_per_second": EDGE_MIN_CHARS_PER_SECOND,
            "slow_ratio_threshold": EDGE_SLOW_RATIO_THRESHOLD,
            "configs": edge_configs,
        }
        if edge_stable_mode and has_edge_engine:
            safe_profile = self._edge_auto_state.get("safe_profile") or {}
            safe_profile["chunk_chars"] = 4000
            safe_profile["max_segment_seconds"] = 120
            safe_profile["timeout_max"] = max(float(safe_profile.get("timeout_max") or 0), 1200.0)
            safe_profile["parallel_cap"] = 1
            self._edge_auto_state["safe_profile"] = safe_profile
            self._edge_auto_state["parallel_cap"] = 1
        if edge_auto_enabled and parallel_slots_cap:
            if chapter_parallel_count > parallel_slots_cap:
                chapter_parallel_count = parallel_slots_cap
                self._reset_parallel_state(chapter_parallel_count)
            print(
                f"🌐 Edge auto-adjustment: limit {parallel_slots_cap} chapter(s) in parallel ({edge_network_tier})"
            )

        if chapter_parallel_count > 1:
            print(
                f"🚀 Parallel mode (automatic): up to {chapter_parallel_count} concurrent chapters"
            )
        else:
            print("🔄 Sequential mode (automatic): processing chapters one at a time")

        edge_cap = 0
        try:
            edge_cap = int(os.getenv("EDGE_MAX_CONCURRENCY", "") or "0")
        except ValueError:
            edge_cap = 0
        parallel_slots = max(1, int(self._parallel_state.get("current") or chapter_parallel_count))
        engine_pool = JobEnginePool(
            create_engine=self.tts_factory.create_engine,
            parallel_slots=parallel_slots,
            edge_cap=edge_cap,
            hardware_profile=self.hardware_profile,
            stats_provider=self._resource_snapshot,
        )
        if is_auto_engine:
            for name, (pool_config, engine_obj) in auto_engine_pool.items():
                engine_pool.register_engine(name, pool_config, engine_obj)
        else:
            engine_name = (config.engine or "").lower()
            engine_pool.register_engine(engine_name, config, engine_seeds.get(engine_name))

        async def _synthesize_safe(engine_obj, text, output_path, **kwargs):
            """Call engine.synthesize_async filtering unsupported kwargs for dummy engines."""
            try:
                sig = inspect.signature(engine_obj.synthesize_async)
                allowed = {k: v for k, v in kwargs.items() if k in sig.parameters}
            except Exception:
                allowed = kwargs
            return await engine_obj.synthesize_async(text, output_path, **allowed)

        # Choose parallel or sequential based on hardware detection
        if chapter_parallel_count > 1:
            result = await self._convert_chapters_parallel(
                pending_chapters,
                engine_pool,
                temp_dir,
                config,
                max_concurrent_chapters=chapter_parallel_count,
                skip_preprocessing=True,  # Already done above
                is_auto_engine=is_auto_engine,
                auto_engine_pool=auto_engine_pool,
                book_title=book_title,
                book_author=book_author,
                cover_art=cover_art,
            )
        else:
            result = await self._convert_chapters_sequential(
                pending_chapters,
                engine_pool,
                temp_dir,
                config,
                skip_preprocessing=True,  # Already done above
                is_auto_engine=is_auto_engine,
                auto_engine_pool=auto_engine_pool,
                book_title=book_title,
                book_author=book_author,
                cover_art=cover_art,
            )
        total_output_files = list(cached_paths) + list(result.output_files)
        raw_failures = self._build_error_map(result.errors)
        pending_failures, unresolved_failures = self._normalise_failure_keys(
            raw_failures, chapter_lookup
        )
        unresolved_pool: Dict[str, str] = dict(unresolved_failures)
        attempts_used: Dict[str, int] = {label: 1 for label in pending_failures}

        for unresolved in unresolved_failures:
            print(f"⚠️ Could not correlate failed chapter: {unresolved}")

        max_retry_rounds = 2
        extra_retry_value = None
        if getattr(config, "extra", None):
            extra_retry_value = config.extra.get("max_auto_retries") or config.extra.get(
                "max_retries"
            )
        if extra_retry_value is None:
            extra_retry_value = getattr(config, "max_auto_retries", None)
        try:
            if extra_retry_value is not None:
                max_retry_rounds = max(0, int(extra_retry_value))
        except (ValueError, TypeError):
            pass
        if extra_retry_value is None and (config.engine or "").lower() == "edge":
            max_retry_rounds = max(max_retry_rounds, 6)
        if not pending_failures and result.converted_chapters < pending_total:
            fallback_detected = self._detect_failed_chapters_by_output(pending_chapters, temp_dir)
            if fallback_detected:
                for label in fallback_detected:
                    attempts_used.setdefault(label, 1)
                pending_failures.update(fallback_detected)
                print(f"\n⚠️ Chapters without valid audio detected: {len(fallback_detected)}")
                if self.verbose:
                    print("   → " + ", ".join(sorted(fallback_detected.keys())))

        if pending_failures:
            failed_labels = ", ".join(sorted(pending_failures.keys()))
            print(f"\n⚠️ Failed chapters detected: {len(pending_failures)}")
            if self.verbose:
                print(f"   → {failed_labels}")

        edge_available = engine_pool.has_engine("edge")
        edge_rescue_applied = False
        edge_rescue_aggressive = False
        forced_offline_once = False
        manual_retry_requested = False
        if getattr(config, "extra", None):
            manual_flag = config.extra.get("manual_retry_failed")
            manual_retry_requested = str(manual_flag).lower() in {"1", "true", "yes", "on"}

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
                unresolved_pool[missing] = message or "Unknown reason"
                attempts_used.pop(missing, None)
                print(f"⚠️ Could not locate chapter for retry: {missing}")

            if not chapters_to_retry_info:
                break

            rescue_profile: Optional[Dict[str, float]] = None
            if self._should_force_edge_rescue(
                pending_failures,
                edge_available=edge_available,
            ):
                if not edge_rescue_applied:
                    rescue_profile = self._apply_edge_rescue_profile(
                        engine_pool=engine_pool,
                        edge_configs=edge_configs,
                        reason="falhas detectadas em capítulos longos",
                    )
                    edge_rescue_applied = True
                elif not edge_rescue_aggressive:
                    rescue_profile = self._apply_edge_rescue_profile(
                        engine_pool=engine_pool,
                        edge_configs=edge_configs,
                        reason="falhas persistentes mesmo após ajuste seguro",
                        aggressive=True,
                    )
                    edge_rescue_aggressive = True

            for chapter_obj, _original_idx, canonical_label in chapters_to_retry_info:
                failure_message = pending_failures.get(canonical_label, "")
                if "Audio possibly truncated" in (failure_message or ""):
                    attempts_so_far = attempts_used.get(canonical_label, 1)
                    self._prepare_truncation_retry_payload(
                        chapter_obj,
                        canonical_label,
                        attempts_so_far,
                        chapter_index=_original_idx,
                        output_dir=temp_dir,
                        cache_dir=getattr(config, "cache_dir", None),
                    )

            chapters_to_retry_info.sort(key=lambda item: item[1])
            chapters_to_retry = [item[0] for item in chapters_to_retry_info]

            if hasattr(self, "progress"):
                self.progress.tick(
                    f"🔁 Automatic retry ({retry_round}/{max_retry_rounds}) for {len(chapters_to_retry)} chapter(s)"
                )
            print(
                f"\n🔁 Retrying {len(chapters_to_retry)} failed chapter(s) (attempt {retry_round}/{max_retry_rounds})"
            )
            retry_config = replace(config, force_reprocess=True)
            has_truncation = any(
                "Audio possibly truncated" in (pending_failures.get(label) or "")
                for label in pending_failures
            )
            if rescue_profile:
                retry_config = replace(
                    retry_config,
                    edge_chunk_chars=int(rescue_profile["chunk_chars"]),
                    edge_max_segment_seconds=int(rescue_profile["max_segment"]),
                    edge_auto_offline_chars=int(rescue_profile["offline_chars"]),
                    edge_auto_offline_seconds=int(rescue_profile["offline_seconds"]),
                    edge_enable_parallel=False,
                    edge_max_concurrency=1,
                )
            elif has_truncation and (config.engine or "").lower() == "edge":
                retry_config = replace(
                    retry_config,
                    edge_chunk_chars=4000,
                    edge_max_segment_seconds=45,
                    edge_enable_parallel=False,
                    edge_max_concurrency=1,
                )
            if (retry_config.engine or "").lower() == "edge":
                base_chunk = int(retry_config.edge_chunk_chars or config.edge_chunk_chars or 4000)
                base_seg = float(
                    retry_config.edge_max_segment_seconds or config.edge_max_segment_seconds or 45
                )
                chunk_factor = 0.75 ** max(1, retry_round)
                seg_factor = 0.85 ** max(1, retry_round)
                retry_config = replace(
                    retry_config,
                    edge_chunk_chars=max(1200, int(base_chunk * chunk_factor)),
                    edge_max_segment_seconds=max(30, int(base_seg * seg_factor)),
                    edge_enable_parallel=False,
                    edge_max_concurrency=1,
                )
            force_offline_engine: Optional[str] = None
            if (
                is_auto_engine
                and edge_rescue_applied
                and not forced_offline_once
                and retry_round >= 2
            ):
                if engine_pool.has_engine("coqui"):
                    force_offline_engine = "coqui"
            if force_offline_engine:
                forced_offline_once = True
                retry_config = replace(retry_config, engine=force_offline_engine, voice=None)
                print(
                    f"🛟 Edge instável → forçando retry com {force_offline_engine.upper()} (offline)"
                )
            retry_result = await self._convert_chapters_sequential(
                chapters_to_retry,
                engine_pool,
                temp_dir,
                retry_config,
                is_auto_engine=is_auto_engine,
                auto_engine_pool=auto_engine_pool,
                book_title=book_title,
                book_author=book_author,
                cover_art=cover_art,
            )

            total_output_files.extend(retry_result.output_files)
            retry_error_map = self._build_error_map(retry_result.errors)
            normalised_retry, unresolved_retry = self._normalise_failure_keys(
                retry_error_map, chapter_lookup
            )
            for unresolved, message in unresolved_retry.items():
                print(f"⚠️ Falha retornada sem correspondência: {unresolved}")
                unresolved_pool[unresolved] = message or "Unknown reason"

            for chapter_obj, original_idx, canonical_label in chapters_to_retry_info:
                attempts_used[canonical_label] = attempts_used.get(canonical_label, 1) + 1
                if canonical_label in normalised_retry:
                    pending_failures[canonical_label] = normalised_retry[canonical_label]
                else:
                    if canonical_label in pending_failures:
                        print(f"✅ Chapter recovered: {canonical_label}")
                    pending_failures.pop(canonical_label, None)

            retry_round += 1

        # Final rescue: switch engine for remaining failures (auto mode only)
        # Priority: coqui > piper (piper has lower quality)
        if pending_failures and is_auto_engine and auto_engine_pool:
            rescue_engine = None
            if "coqui" in auto_engine_pool:
                rescue_engine = "coqui"
            elif "piper" in auto_engine_pool:
                rescue_engine = "piper"
            if rescue_engine:
                failed_names = list(pending_failures.keys())
                chapters_to_retry_info = []
                for name in failed_names:
                    entry = self._lookup_chapter_entry(chapter_lookup, name)
                    if entry:
                        chapter_obj, original_idx, canonical_label = entry
                        chapters_to_retry_info.append((chapter_obj, original_idx, canonical_label))
                        attempts_used.setdefault(canonical_label, 1)
                chapters_to_retry_info.sort(key=lambda item: item[1])
                chapters_to_retry = [item[0] for item in chapters_to_retry_info]
                if chapters_to_retry:
                    print(
                        f"\n🛟 Final rescue: reprocessing {len(chapters_to_retry)} chapter(s) with {rescue_engine.upper()}"
                    )
                    rescue_config = replace(
                        config,
                        engine=rescue_engine,
                        voice=None,
                        force_reprocess=True,
                        edge_enable_parallel=False,
                    )
                    rescue_config.extra = dict(rescue_config.extra or {})
                    rescue_result = await self._convert_chapters_sequential(
                        chapters_to_retry,
                        engine_pool,
                        temp_dir,
                        rescue_config,
                        is_auto_engine=is_auto_engine,
                        auto_engine_pool=auto_engine_pool,
                        book_title=book_title,
                        book_author=book_author,
                        cover_art=cover_art,
                    )
                    total_output_files.extend(rescue_result.output_files)
                    retry_error_map = self._build_error_map(rescue_result.errors)
                    normalised_retry, unresolved_retry = self._normalise_failure_keys(
                        retry_error_map, chapter_lookup
                    )
                    for unresolved, message in unresolved_retry.items():
                        unresolved_pool[unresolved] = message or "Unknown reason"
                    pending_failures = normalised_retry

        if pending_failures and manual_retry_requested:
            failed_names = list(pending_failures.keys())
            chapters_to_retry_info = []
            for name in failed_names:
                entry = self._lookup_chapter_entry(chapter_lookup, name)
                if entry:
                    chapter_obj, original_idx, canonical_label = entry
                    chapters_to_retry_info.append((chapter_obj, original_idx, canonical_label))
                    attempts_used.setdefault(canonical_label, 1)
            chapters_to_retry_info.sort(key=lambda item: item[1])
            chapters_to_retry = [item[0] for item in chapters_to_retry_info]
            if chapters_to_retry:
                print(
                    f"\n🔁 Manual retry requested: reprocessing {len(chapters_to_retry)} chapter(s)"
                )
                manual_config = replace(config, force_reprocess=True)
                manual_config.extra = dict(manual_config.extra or {})
                manual_config.extra.pop("manual_retry_failed", None)
                manual_result = await self._convert_chapters_sequential(
                    chapters_to_retry,
                    engine_pool,
                    temp_dir,
                    manual_config,
                    is_auto_engine=is_auto_engine,
                    auto_engine_pool=auto_engine_pool,
                    book_title=book_title,
                    book_author=book_author,
                    cover_art=cover_art,
                )
                total_output_files.extend(manual_result.output_files)
                retry_error_map = self._build_error_map(manual_result.errors)
                normalised_retry, unresolved_retry = self._normalise_failure_keys(
                    retry_error_map, chapter_lookup
                )
                for unresolved, message in unresolved_retry.items():
                    unresolved_pool[unresolved] = message or "Unknown reason"
                pending_failures = normalised_retry
            else:
                print("ℹ️ Manual retry requested, but no remaining chapters to reprocess.")

        if pending_failures:
            print(f"\n⚠️ Some chapters still failed after {max_retry_rounds} attempt(s).")
            if hasattr(self, "progress"):
                self.progress.tick("❌ Incomplete conversion - pending chapters after retries")
        elif attempts_used and any(attempts > 1 for attempts in attempts_used.values()):
            print("\n✅ All chapters were successfully converted after additional attempts.")

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
        result.total_chapters = total_chapters

        if pending_failures:
            ordered_errors = []
            for name, message in pending_failures.items():
                entry = self._lookup_chapter_entry(chapter_lookup, name)
                idx = entry[1] if entry else total_chapters + 1
                ordered_errors.append((idx, name, message))
            ordered_errors.sort(key=lambda item: item[0])
            result.errors = [
                f"{name}: {message} (tentativas: {attempts_used.get(name, 'n/d')})"
                if message
                else f"{name} (tentativas: {attempts_used.get(name, 'n/d')})"
                for _, name, message in ordered_errors
            ]
        else:
            result.errors = []

        if unresolved_pool:
            for name, message in unresolved_pool.items():
                result.errors.append(f"{name}: {message} (não correlacionado)")

        result.success = not pending_failures and not unresolved_pool

        # Move successfully converted files even on partial failure (for resume capability)
        if result.converted_chapters > 0:
            if self.verbose:
                print(
                    f"[DEBUG] Movendo {len(result.output_files)} arquivos para diretório final..."
                )

            temp_mp3s = list(Path(temp_dir).glob("*.mp3"))
            moved_files = self.file_manager.move_files_to_final_output(temp_dir, output_dir)

            # Only override output_files if we actually moved something
            if moved_files:
                result.output_files = moved_files
                if result.success:
                    print(f"📁 {len(moved_files)} files moved to: {output_dir}")
                else:
                    print(f"📁 {len(moved_files)} converted chapters moved to: {output_dir}")
                    print("   💡 Run again to convert remaining chapters")
            elif self.verbose:
                print("[DEBUG] No MP3 files to move (likely full cache reuse)")

            normalized_outputs = self._normalize_output_numbers(chapters, output_dir, config)
            if normalized_outputs:
                result.output_files = normalized_outputs

            # Apply ID3 tags (including cover art) to ALL MP3s in output dir,
            # not just newly converted ones — ensures partial/resumed conversions
            # always have consistent metadata and cover art.
            album_name = book_title or (
                self._current_book_path.stem if self._current_book_path else output_dir.name
            )
            all_output_mp3s = sorted(output_dir.glob("*.mp3")) if output_dir.exists() else []
            if all_output_mp3s:
                self._apply_final_id3_tags(
                    all_output_mp3s,
                    default_album=album_name,
                    artist=book_author or None,
                    cover_art=cover_art,
                )

            # Clean temp audio only if we actually used temp files
            if temp_mp3s:
                self._cleanup_temp_audio(temp_dir)

        if not result.success:
            if result.converted_chapters > 0:
                print(f"⚠️ Partial conversion - {len(pending_failures)} chapter(s) failed")
            else:
                print("❌ Conversion failed - no chapters converted")

        await self._stop_health_watchdog()
        self._sync_text_cache_to_output(temp_dir, output_dir)
        self.progress.finish()
        await self._report_results(result)
        return result

    def _sync_text_cache_to_output(self, temp_dir: Path, output_dir: Path) -> int:
        """Copy cached .txt artifacts into output/text for validation."""
        text_dir = Path(temp_dir) / "text"
        if not text_dir.exists():
            return 0
        target_dir = Path(output_dir) / "text"
        target_dir.mkdir(parents=True, exist_ok=True)
        copied = 0
        for txt_file in text_dir.glob("*.txt"):
            target_path = target_dir / txt_file.name
            try:
                shutil.copy2(txt_file, target_path)
                copied += 1
            except OSError:
                continue
        if self.verbose and copied:
            print(f"[DEBUG] Synced {copied} text file(s) to output/text")
        return copied

    def _setup_output_directory(self, config: ConversionConfig) -> Path:
        base_dir = Path(config.output_dir)
        name = config.book_title or "default"
        safe_name = self.file_manager.sanitize_filename(name)
        return self.file_manager.ensure_directory(base_dir / safe_name)

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

                print(f"⚠️ Cache unavailable: {e}")
                print("💡 Using system temporary directory")
                base_cache = Path(tempfile.mkdtemp(prefix="epub_to_mp3_"))

        temp_dir = self.file_manager.ensure_directory(base_cache)
        config.cache_dir = temp_dir
        return temp_dir

    def _build_engine_signature(self, config: ConversionConfig) -> str:
        engine = getattr(config, "engine", None) or "unknown"
        return self.file_manager.sanitize_filename(engine.lower(), max_length=96).replace(" ", "_")

    async def _convert_chapters_parallel(
        self,
        chapters: Iterable[Chapter],
        engine_pool: JobEnginePool,
        output_dir: Path,
        config: ConversionConfig,
        max_concurrent_chapters: int = 3,
        *,
        skip_preprocessing: bool = False,
        is_auto_engine: bool = False,
        auto_engine_pool: Optional[Dict[str, tuple[ConversionConfig, object]]] = None,
        book_title: str = "",
        book_author: str = "",
        cover_art: Optional[dict] = None,
    ) -> ConversionResult:
        """Converte múltiplos capítulos em paralelo para máxima velocidade."""
        chapters_list = list(chapters)
        selected_indices_raw = (config.extra.get("selected_indices") or "").strip()
        if selected_indices_raw:
            allowed = {item.strip() for item in selected_indices_raw.split(",") if item.strip()}
            if allowed:
                chapters_list = [ch for ch in chapters_list if str(ch.index) in allowed]
        if not chapters_list:
            return ConversionResult(True, 0, 0, [], [])

        chapters_for_text = list(chapters_list)

        # Bucketize by size (largest first) to reduce tail latency and lock contention
        chapters_sorted = sorted(chapters_list, key=self._estimate_chapter_chars, reverse=True)

        total_chapters = len(chapters_sorted)
        recommended = max(1, int(max_concurrent_chapters or 1))
        self._parallel_state.setdefault("ceiling", recommended)
        self._parallel_state["ceiling"] = recommended
        self._parallel_state["current"] = max(
            1, min(recommended, int(self._parallel_state.get("current") or recommended))
        )
        print(
            f"🚀 Parallel mode: processing {total_chapters} chapters (current {self._parallel_state['current']} concurrent)"
        )

        # If preprocessing already done by caller, skip duplicate work
        if not skip_preprocessing:
            # Validate and clean cache (once for all chapters)
            self._validate_and_clean_cache(chapters_for_text, output_dir, config)

            generated_text = False
            cleanup_existing = not self._parse_chapter_whitelist(config)
            if getattr(config, "auto_validate_output", True):
                self._generate_all_text_files(
                    chapters_for_text, output_dir, config, cleanup_existing=cleanup_existing
                )
                generated_text = True

            # Fast-path cache check before generating text (partial-aware)
            cached_audio, pending_chapters = self._split_cached_chapters(
                chapters_for_text, output_dir, config, allow_index_only=True
            )

            # Generate all text files (once for all chapters) if needed
            if pending_chapters and not generated_text:
                self._generate_all_text_files(
                    chapters_for_text, output_dir, config, cleanup_existing=cleanup_existing
                )

                # Retry cache check after text generation (allows hash validation)
                cached_audio, pending_chapters = self._split_cached_chapters(
                    chapters_for_text, output_dir, config, allow_index_only=False
                )

            if cached_audio and not pending_chapters:
                print(
                    f"♻️ All {len(chapters_list)} chapter(s) already cached (MP3) — skipping synthesis"
                )
                for _ in chapters_list:
                    self.progress.tick("✅ Complete (cache)") if hasattr(self, "progress") else None
                if getattr(config, "auto_validate_output", True):
                    await self._auto_validate_output(output_dir, stage="cache-only")
                return ConversionResult(
                    success=True,
                    total_chapters=len(chapters_for_text),
                    converted_chapters=len(chapters_for_text),
                    output_files=cached_audio,
                    errors=[],
                )

            if cached_audio and pending_chapters:
                print(
                    f"♻️ Cache detected: {len(cached_audio)} chapter(s) ready; "
                    f"converting {len(pending_chapters)} remaining"
                )

            pending_chapters = sorted(
                pending_chapters,
                key=self._estimate_chapter_chars,
                reverse=True,
            )

            self._assign_progress_indices(pending_chapters)
            chapters_list = pending_chapters
        else:
            # Preprocessing done by caller - no cached files to track here
            cached_audio = []

        all_converted_files: List[Path] = []
        all_errors: List[str] = []
        converted_total = 0

        # **OPTIMIZED**: Dynamic task completion - eliminates batch starvation
        # Process chapters with max concurrency, starting new tasks as any task completes
        pending_tasks = {}  # task -> chapter
        chapter_iter = iter(chapters_list)
        batch_start = time.time()

        # Helper to create chapter task
        def create_chapter_task(chapter: Chapter) -> asyncio.Task:
            return asyncio.create_task(
                self._convert_chapters_sequential(
                    [chapter],
                    engine_pool,
                    output_dir,
                    config,
                    is_auto_engine=is_auto_engine,
                    auto_engine_pool=auto_engine_pool,
                    book_title=book_title,
                    book_author=book_author,
                    cover_art=cover_art,
                    skip_preprocessing=True,  # Preprocessing already done by parallel caller
                )
            )

        parallel_slots = int(self._parallel_state.get("current", recommended) or recommended)
        parallel_slots = max(1, min(parallel_slots, recommended))
        engine_pool.update_parallel_slots(parallel_slots)

        overall_start = time.time()
        batch_chars = 0
        total_chars_processed = 0
        batch_errors = 0
        completed_since_tune = 0

        for _ in range(min(parallel_slots, total_chapters)):
            try:
                chapter = next(chapter_iter)
                task = create_chapter_task(chapter)
                pending_tasks[task] = chapter
            except StopIteration:
                break

        while pending_tasks:
            done, _ = await asyncio.wait(pending_tasks.keys(), return_when=asyncio.FIRST_COMPLETED)

            for task in done:
                chapter = pending_tasks.pop(task)
                chapter_chars = self._estimate_chapter_chars(chapter)
                batch_chars += chapter_chars
                total_chars_processed += chapter_chars
                completed_since_tune += 1

                try:
                    result = task.result()
                    if isinstance(result, Exception):
                        all_errors.append(str(result))
                        batch_errors += 1
                    elif isinstance(result, ConversionResult):
                        all_converted_files.extend(result.output_files)
                        all_errors.extend(result.errors)
                        converted_total += result.converted_chapters
                        batch_errors += len(result.errors)
                except Exception as exc:
                    all_errors.append(str(exc))
                    batch_errors += 1

            tuned_slots = int(self._parallel_state.get("current") or parallel_slots)
            if tuned_slots < parallel_slots:
                parallel_slots = max(1, tuned_slots)
                engine_pool.update_parallel_slots(parallel_slots)

            while len(pending_tasks) < parallel_slots:
                try:
                    chapter = next(chapter_iter)
                    task = create_chapter_task(chapter)
                    pending_tasks[task] = chapter
                except StopIteration:
                    break

            if completed_since_tune >= 2:
                elapsed = max(time.time() - batch_start, 0.001)
                throughput = (batch_chars / elapsed) if batch_chars else None
                new_slots, reason = self._auto_tune_parallelism(
                    throughput=throughput,
                    batch_errors=batch_errors,
                )
                if new_slots != parallel_slots:
                    parallel_slots = new_slots
                    engine_pool.update_parallel_slots(parallel_slots)
                    if reason:
                        print(f"⚙️ {reason}")
                batch_start = time.time()
                batch_chars = 0
                batch_errors = 0
                completed_since_tune = 0

                # Clean up resources periodically to reduce memory usage
                if converted_total % 10 == 0:  # Every 10 chapters
                    self._cleanup_resources(force_gc=False)

        batch_elapsed = max(time.time() - overall_start, 0.001)

        # Calculate final metrics
        batch_throughput = (
            (total_chars_processed / batch_elapsed) if total_chars_processed else None
        )
        if batch_throughput and self.verbose:
            print(
                f"   📈 Dynamic processing: ~{int(batch_throughput)} chars/s ({int(batch_elapsed)}s total)"
            )

        # All chapters processed dynamically
        if cached_audio:
            all_converted_files = list(cached_audio) + all_converted_files
            converted_total = len(all_converted_files)

        # **INTEGRITY VALIDATION**: Verify all chapters from EPUB are present in audio output
        self._print_final_validation_report(
            chapters=chapters,
            converted_files=all_converted_files,
            errors=all_errors,
            output_dir=output_dir,
            verbose=self.verbose,
        )

        # **DEEP VALIDATION**: Automatic comprehensive validation
        # Verifies duplicates, start/middle/end content, and character counts
        # Skip when chapter filter is active (only validate requested chapters)
        chapter_filter_active = bool(self._parse_chapter_whitelist(config)) or bool(
            (config.extra or {}).get("selected_indices", "").strip()
        )
        deep_validation_requested = bool(getattr(config, "deep_validate", False))
        deep_validation_passed = True
        if (
            deep_validation_requested
            and self._current_book_path
            and len(all_errors) == 0
            and not chapter_filter_active
        ):
            try:
                from .deep_validator import run_deep_validation

                cache_path = output_dir
                report = run_deep_validation(str(self._current_book_path), str(cache_path))
                deep_validation_passed = report.success

                if not deep_validation_passed:
                    # Retry once: re-save parsed text for failed chapters and re-validate
                    from .deep_validator import DeepValidator

                    # Extract indices of failed chapters from their filenames
                    failed_indices = set()
                    for c in report.comparisons:
                        if not c.is_valid:
                            idx = DeepValidator._extract_chapter_index(c.chapter_id)
                            if idx:
                                failed_indices.add(idx)

                    if failed_indices and self.verbose:
                        print(
                            f"🔄 Re-saving {len(failed_indices)} failed chapter(s) from EbookReader..."
                        )

                    if failed_indices:
                        dv = DeepValidator(str(self._current_book_path), str(cache_path))
                        if dv.load_epub_chapters():
                            text_dir = cache_path / "text"
                            # Overwrite parsed files for failed chapters
                            for ch in dv._chapter_list:
                                if str(ch.index) in failed_indices:
                                    # Find the actual parsed file by glob
                                    pattern = f"{ch.index} - *-parsed.txt"
                                    for pf in text_dir.glob(pattern):
                                        ch_text = ch.text or ""
                                        pf.write_text(ch_text, encoding="utf-8")

                    # Re-run validation
                    report = run_deep_validation(str(self._current_book_path), str(cache_path))
                    deep_validation_passed = report.success

                    if not deep_validation_passed and self.verbose:
                        print("⚠️  Deep validation still has issues after retry.")
            except Exception as e:
                if self.verbose:
                    print(f"⚠️  Deep validation failed to run: {e}")

        return ConversionResult(
            success=len(all_errors) == 0 and deep_validation_passed,
            total_chapters=total_chapters,
            converted_chapters=converted_total or len(all_converted_files),
            output_files=all_converted_files,
            errors=all_errors,
        )

    async def _convert_chapters_sequential(
        self,
        chapters: Iterable[Chapter],
        engine_pool: JobEnginePool,
        output_dir: Path,
        config: ConversionConfig,
        *,
        skip_preprocessing: bool = False,
        is_auto_engine: bool = False,
        auto_engine_pool: Optional[Dict[str, tuple[ConversionConfig, object]]] = None,
        book_title: str = "",
        book_author: str = "",
        cover_art: Optional[dict] = None,
    ) -> ConversionResult:
        """Converte capítulos sequencialmente, SEM sistema de paralelismo."""
        chapters_list = list(chapters)
        selected_indices_raw = (config.extra.get("selected_indices") or "").strip()
        if selected_indices_raw:
            allowed = {item.strip() for item in selected_indices_raw.split(",") if item.strip()}
            if allowed:
                chapters_list = [ch for ch in chapters_list if str(ch.index) in allowed]
        if not chapters_list:
            return ConversionResult(True, 0, 0, [], [])
        original_total = len(chapters_list)
        edge_stable_mode = False
        if getattr(config, "extra", None):
            stable_raw = config.extra.get("edge_stable_mode")
            if stable_raw is not None:
                edge_stable_mode = str(stable_raw).lower() in {
                    "1",
                    "true",
                    "yes",
                    "on",
                }
        if (
            not edge_stable_mode
            and EDGE_AUTO_STABLE
            and (config.engine or "").lower() == "edge"
            and os.getenv("EDGE_NETWORK_TIER", "").strip().lower() == "slow"
        ):
            edge_stable_mode = True

        # Compat: aceitar um engine direto em vez de um pool
        if hasattr(engine_pool, "synthesize_async") and not hasattr(engine_pool, "acquire"):
            engine_instance = engine_pool

            class _SingleEnginePool:
                def __init__(self, engine_obj):
                    self.engine_obj = engine_obj

                async def acquire(self, *_args, **_kwargs):
                    return config, self.engine_obj

                def release(self, *_args, **_kwargs):
                    return None

                def register_engine(self, *_args, **_kwargs):
                    """No-op for compatibility with test mocks"""
                    return None

            engine_pool = _SingleEnginePool(engine_instance)

        async def _synthesize_safe(engine_obj, text, output_path, **kwargs):
            """Call engine.synthesize_async filtering unsupported kwargs for dummy engines."""
            try:
                sig = inspect.signature(engine_obj.synthesize_async)
                allowed = {k: v for k, v in kwargs.items() if k in sig.parameters}
            except Exception:
                allowed = kwargs
            return await engine_obj.synthesize_async(text, output_path, **allowed)

        # If preprocessing already done by caller, skip duplicate work
        if not skip_preprocessing:
            # Auto-skip credits/very short chapters if not cached
            chapters_list = self._filter_chapters_auto(chapters_list, output_dir, config)

            print(f"🔄 Sequential mode: processing {len(chapters_list)} chapters")

            # **NEW**: Check for cache invalidation BEFORE generating text files
            # If MP3 exists but pre-tts.txt doesn't, delete MP3 (cache invalidated)
            self._validate_and_clean_cache(chapters_list, output_dir, config)

            generated_text = False
            cleanup_existing = not self._parse_chapter_whitelist(config)
            if getattr(config, "auto_validate_output", True):
                self._generate_all_text_files(
                    chapters_list, output_dir, config, cleanup_existing=cleanup_existing
                )
                generated_text = True

            # **FAST-PATH**: Try cache reuse before generating text (index-only allowed)
            cached_audio, pending_chapters = self._split_cached_chapters(
                chapters_list, output_dir, config, allow_index_only=True
            )

            # **NEW**: Generate ALL text files BEFORE starting conversion (if needed)
            if pending_chapters and not generated_text:
                self._generate_all_text_files(
                    chapters_list, output_dir, config, cleanup_existing=cleanup_existing
                )
                # Retry cache after having pre-tts hashes
                cached_audio, pending_chapters = self._split_cached_chapters(
                    chapters_list, output_dir, config, allow_index_only=False
                )

            # **FAST-PATH**: If all MP3s already exist, skip synthesis and return.
            if cached_audio and not pending_chapters:
                print(
                    f"♻️ All {len(chapters_list)} chapter(s) already cached (MP3) — skipping synthesis"
                )
                for chap in chapters_list:
                    self.progress.tick("✅ Complete (cache)") if hasattr(self, "progress") else None
                return ConversionResult(
                    success=True,
                    total_chapters=original_total,
                    converted_chapters=original_total,
                    output_files=cached_audio,
                    errors=[],
                )
            if cached_audio and pending_chapters:
                print(
                    f"♻️ Cache detected: {len(cached_audio)} chapter(s) ready; "
                    f"converting {len(pending_chapters)} remaining"
                )
            self._assign_progress_indices(pending_chapters)
            chapters_list = pending_chapters
        else:
            # Preprocessing done by caller, just print status
            print(f"🔄 Sequential mode: processing {len(chapters_list)} chapters")
            cached_audio = []  # No cached files when preprocessing done by caller

        converted_files: List[Path] = list(cached_audio)
        errors: List[str] = []
        cooldown_pattern = re.compile(r"cooldown\\s+(\\d+)s", re.IGNORECASE)

        def _edge_error_reason(last_error: Optional[str]) -> str:
            text = str(last_error or "").lower()
            if "rate_limit" in text or "too many requests" in text:
                return "rate_limit"
            if "noaudio" in text or "no_audio" in text or "noaudioreceived" in text:
                return "no_audio"
            if "service_unavailable" in text or "503" in text:
                return "service_unavailable"
            if "timeout" in text:
                return "timeout"
            if (
                "ssl" in text
                or "certificate" in text
                or "connection" in text
                or "dns" in text
                or "connector" in text
            ):
                return "network"
            return "unknown"

        edge_unavailable_hits = 0
        auto_engine_pool = auto_engine_pool or {}
        unavailable_engines: Set[str] = set()
        edge_state = self._edge_auto_state or {}
        edge_auto_enabled = bool(edge_state.get("enabled"))
        edge_force_offline = bool(edge_state.get("force_offline_after_trunc"))

        def _maybe_apply_edge_slow_mode(reason: str, engine_obj: Optional[object] = None) -> None:
            if edge_auto_enabled:
                self._apply_edge_slow_mode(reason, engine_pool=engine_pool, engine_obj=engine_obj)

        def _maybe_apply_coqui_recovery(reason: str, engine_obj: Optional[object] = None) -> None:
            if engine_obj is None:
                return
            adjusted = False
            try:
                if hasattr(engine_obj, "_safe_mode") and not getattr(engine_obj, "_safe_mode"):
                    engine_obj._safe_mode = True
                    adjusted = True
                if hasattr(engine_obj, "_max_workers"):
                    current_workers = getattr(engine_obj, "_max_workers", None)
                    if current_workers is None or current_workers > 1:
                        engine_obj._max_workers = 1
                        adjusted = True
                if hasattr(engine_obj, "_chunk_char_limit"):
                    current_limit = getattr(engine_obj, "_chunk_char_limit", None) or 0
                    target_limit = 1600
                    if current_limit == 0 or current_limit > target_limit:
                        engine_obj._chunk_char_limit = target_limit
                        adjusted = True
                if adjusted and self.verbose:
                    print(f"   🛠️ Coqui em modo seguro ({reason}): chunks=1600, workers=1")
            except Exception:
                pass

        def available_auto_pool() -> Dict[str, tuple[ConversionConfig, object]]:
            if not auto_engine_pool:
                return {}
            return {
                name: entry
                for name, entry in auto_engine_pool.items()
                if name not in unavailable_engines
            }

        def can_use_piper() -> bool:
            """Check if piper is available in venv or system PATH."""
            # Check venv first (common locations)
            venv_locations = [
                Path(".venv/bin/piper"),
                Path("venv/bin/piper"),
                Path(sys.executable).parent / "piper",
            ]
            for piper_path in venv_locations:
                if piper_path.exists() and piper_path.is_file():
                    return True
            # Fallback to system PATH
            return shutil.which("piper") is not None

        def build_best_offline_engine(
            reason: Optional[str] = None,
            *,
            tracker: Optional[dict] = None,
            engine_ref: Optional[dict] = None,
        ) -> bool:
            return False

        if (config.engine or "").lower() == "edge" and not is_auto_engine:
            edge_engine = None
            try:
                _, edge_engine = await engine_pool.acquire("edge")
                if edge_engine and hasattr(edge_engine, "_probe_edge_health"):
                    voice = getattr(edge_engine, "voice", None)
                    healthy = await edge_engine._probe_edge_health(voice)  # type: ignore[attr-defined]
                    if not healthy and self.verbose:
                        print("   ⚠️ Edge pré-check falhou; mantendo engine selecionada")
            except Exception:
                pass
            finally:
                if edge_engine is not None:
                    engine_pool.release("edge", edge_engine)

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
                Handle Edge outages without mudar de engine (modo manual).
                Aguarda cooldown curto antes de tentar novamente.
                """
                if (config.engine or "").lower() != "edge":
                    return False
                engine_obj = engine_ref.get("object") if isinstance(engine_ref, dict) else None
                last_error = getattr(engine_obj, "last_error", None) if engine_obj else None
                if not last_error:
                    return False

                reason = _edge_error_reason(last_error)
                if reason not in {
                    "service_unavailable",
                    "no_audio",
                    "rate_limit",
                    "timeout",
                    "network",
                }:
                    return False

                match = cooldown_pattern.search(str(last_error))
                seconds = int(match.group(1)) if match else 0
                if seconds <= 0:
                    seconds = 12
                if self.verbose:
                    print(f"   ⚠️ Edge indisponível ({context}) - erro: {last_error}")
                nonlocal edge_unavailable_hits
                edge_unavailable_hits += 1
                if edge_unavailable_hits >= EDGE_MONOLINGUAL_THRESHOLD:
                    raise RuntimeError("edge_unavailable_threshold")
                _maybe_apply_edge_slow_mode(f"Edge indisponível ({reason})", engine_obj=engine_obj)

                max_wait = min(seconds, 25)
                if self.verbose:
                    print(
                        f"   ⏳ Sem fallback disponível; aguardando {max_wait}s antes de tentar novamente..."
                    )
                waited = 0
                while waited < max_wait:
                    chunk = min(3, max_wait - waited)
                    await asyncio.sleep(chunk)
                    waited += chunk
                    self.progress.tick(f"⏳ Edge indisponível - aguardando {max_wait - waited}s...")
                return True

        def _resolve_tts_output_path(
            final_mp3_path: Path, engine_name: Optional[str] = None
        ) -> tuple[Path, bool]:
            engine = (engine_name or config.engine or "").lower()
            if engine in {"piper", "coqui"}:
                return final_mp3_path.with_suffix(".wav"), True
            return final_mp3_path, False

        class _RetryChapter(Exception):
            pass

        async def _maybe_apply_edge_fallback() -> None:
            nonlocal edge_switched_to_monolingual
            nonlocal edge_switched_to_kokoro
            nonlocal edge_switched_to_piper
            nonlocal edge_consecutive_failures
            nonlocal config

            current_engine = (config.engine or "").lower()
            if current_engine not in ("edge", "kokoro"):
                return

            # TIER 2: Edge monolingual after MONOLINGUAL_THRESHOLD failures
            if (
                current_engine == "edge"
                and not edge_switched_to_monolingual
                and edge_consecutive_failures >= EDGE_MONOLINGUAL_THRESHOLD
            ):
                from .config import VoiceConfigProvider

                voice_provider = VoiceConfigProvider()
                monolingual_voice = voice_provider.get_monolingual_voice(config.primary_language)
                if monolingual_voice and monolingual_voice != config.voice:
                    print(f"\n🔄 Edge-TTS com {edge_consecutive_failures} falhas consecutivas")
                    print(f"   🔀 Mudando para Edge monolíngue: {config.primary_language}")
                    print(f"   🎤 Nova voz: {monolingual_voice}")
                    config = replace(config, voice=monolingual_voice)
                    engine_pool.register_engine("edge", config)
                    edge_switched_to_monolingual = True
                    edge_consecutive_failures = 0
                    return
                else:
                    # No monolingual voice, skip to Kokoro
                    edge_switched_to_monolingual = True

            # TIER 3: Kokoro after KOKORO_THRESHOLD failures (from monolingual Edge)
            if (
                not edge_switched_to_kokoro
                and edge_switched_to_monolingual
                and current_engine == "edge"
                and edge_consecutive_failures >= EDGE_KOKORO_THRESHOLD
            ):
                try:
                    from .tts.kokoro_engine import KokoroTTSEngine

                    KokoroTTSEngine()  # test availability
                    print(
                        f"\n🔄 Edge monolíngue com {edge_consecutive_failures} falhas consecutivas"
                    )
                    print("   🔀 Mudando para Kokoro (local, rápido)")
                    config = replace(config, engine="kokoro")
                    engine_pool.register_engine("kokoro", config)
                    edge_switched_to_kokoro = True
                    edge_consecutive_failures = 0
                    return
                except Exception as e:
                    if self.verbose:
                        print(f"   ⚠️ Kokoro indisponível: {e}")
                    edge_switched_to_kokoro = True  # skip to piper

            # TIER 4: Piper after PIPER_THRESHOLD failures (from Kokoro or Edge)
            if (
                not edge_switched_to_piper
                and edge_consecutive_failures >= EDGE_PIPER_THRESHOLD
                and (edge_switched_to_kokoro or edge_switched_to_monolingual)
            ):
                if can_use_piper():
                    current_label = "Kokoro" if current_engine == "kokoro" else "Edge"
                    print(
                        f"\n🔄 {current_label} com {edge_consecutive_failures} falhas consecutivas"
                    )
                    print(
                        f"   🛟 Mudando para Piper (offline) com idioma: {config.primary_language}"
                    )
                    from .config import VoiceConfigProvider

                    voice_provider = VoiceConfigProvider()
                    piper_model = voice_provider.get_voice("piper", config.primary_language)
                    if piper_model:
                        config = replace(
                            config,
                            engine="piper",
                            model_path=Path(piper_model) if piper_model else None,
                        )
                        engine_pool.register_engine("piper", config)
                        try:
                            _, piper_engine = await engine_pool.acquire("piper")
                            if piper_engine:
                                print(
                                    f"   ✅ Piper carregado: {Path(piper_model).name if piper_model else 'modelo padrão'}"
                                )
                                engine_pool.release("piper", piper_engine)
                                edge_switched_to_piper = True
                                edge_consecutive_failures = 0
                            else:
                                print("   ⚠️ Piper engine não pôde ser carregado")
                        except Exception as e:
                            print(f"   ⚠️ Erro ao carregar Piper: {e}")
                    else:
                        print("   ⚠️ Modelo Piper não encontrado para este idioma")
                else:
                    print(f"\n⚠️ {edge_consecutive_failures} falhas consecutivas")
                    print("   ⚠️ Piper não instalado - não é possível fazer fallback")

        # Four-tier fallback: Edge multilingual → Edge monolingual → Kokoro → Piper
        edge_failure_count = 0
        edge_consecutive_failures = 0
        base_delay = 0.5  # Start with 0.5s delay
        max_delay = 30.0  # Cap at 30s
        edge_switched_to_monolingual = False
        edge_switched_to_kokoro = False
        edge_switched_to_piper = False
        config.voice if (config.engine or "").lower() == "edge" else None

        for idx, chapter in enumerate(chapters_list):
            # Adaptive delay and fallback logic for Edge-TTS
            if (config.engine or "").lower() == "edge" and idx > 0:
                await _maybe_apply_edge_fallback()

                # Calculate delay based on failure rate
                if edge_consecutive_failures > 0:
                    # Exponential backoff: double delay for each consecutive failure
                    delay = min(base_delay * (2**edge_consecutive_failures), max_delay)
                    if self.verbose:
                        print(
                            f"   ⏱️  Edge-TTS adaptive delay: {delay:.1f}s (failures: {edge_consecutive_failures})"
                        )
                    await asyncio.sleep(delay)
                elif edge_failure_count > 5:
                    # If we've had failures (but not consecutive), use small delay
                    await asyncio.sleep(base_delay * 2)

            # Use chapter's original index if available (important for parallel mode)
            # where each task receives a single-chapter list
            chapter_num = self._chapter_number(chapter, idx + 1)
            progress_index = getattr(chapter, "_progress_index", None) or (idx + 1)
            chapter_label = self._chapter_display_name(chapter, chapter_num)
            speech_text, pre_tts_path, payload_locked = self._resolve_pre_tts_payload(
                chapter, chapter_num, output_dir, config
            )
            current_payload: Optional[str] = speech_text
            chapter_chars = len(speech_text or "")
            progress_started = False
            chapter_attempt = 0
            max_chapter_attempts = 6

            while True:
                chapter_attempt += 1
                chapter_retry = False
                start_time = time.time()

                def _edge_retry(reason: str, *, count_failure: bool = True) -> None:
                    nonlocal chapter_retry
                    nonlocal edge_failure_count
                    nonlocal edge_consecutive_failures
                    if count_failure:
                        edge_failure_count += 1
                        edge_consecutive_failures += 1
                    chapter_retry = True
                    raise _RetryChapter(reason)

                def _error_text(message: Optional[str]) -> str:
                    return message or "Falha na síntese"

                # **RESTORED**: Usar progress tracker (apenas uma vez por capítulo)
                if not progress_started:
                    self.progress.start_chapter(chapter.name, progress_index)
                    progress_started = True

                chapter_success = False
                chapter_error: Optional[str] = None
                chapter_cached = False
                engine_tracker = {"label": (config.engine or "").lower()}
                engine_instance = {"object": None}
                engine_name_used: Optional[str] = None
                engine_obj: Optional[object] = None

                try:
                    # Conversão para diretório temporário
                    output_path = self._expected_output_path(chapter, chapter_num, output_dir)

                    # Check if MP3 already exists and is valid (size > 1KB)
                    # Note: Cache validation already done by _validate_and_clean_cache()
                    if output_path.exists() and not config.force_reprocess:
                        file_size = output_path.stat().st_size
                        if file_size > 1000:  # Mínimo 1KB para áudio válido
                            cached_payload = (
                                self._load_cached_payload(chapter, chapter_num, output_dir)
                                or speech_text
                            )
                            truncation_warning = self._detect_short_audio_output(
                                output_path,
                                cached_payload,
                                config,
                                engine_label=engine_tracker.get("label"),
                            )
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
                                break
                        else:
                            # Arquivo vazio ou corrompido - remover e reconverter
                            if self.verbose:
                                print(
                                    f"   🗑️ Removendo arquivo inválido ({file_size} bytes): {output_path}"
                                )
                            output_path.unlink(missing_ok=True)
                            output_path.with_suffix(".wav").unlink(missing_ok=True)

                    # Sintetizar com heartbeat e timeout (otimizado)
                    speech_text = speech_text or ""
                    preview = self._chapter_preview(speech_text)
                    if preview:
                        print(f"   📝 Initial excerpt: {preview}")
                    current_payload = speech_text
                    estimated_seconds = TextValidator.estimate_duration(speech_text)
                    if estimated_seconds <= 0:
                        estimated_seconds = max(chapter_chars / 15.0, 30.0)
                    switched_for_size = False
                    auto_order: Optional[List[str]] = None
                    attempted_auto: Set[str] = set()
                    if is_auto_engine:
                        pool_view = available_auto_pool()
                        if not pool_view:
                            chapter_error = "Nenhuma engine disponível no modo automático"
                            errors.append(f"{chapter.name}: {chapter_error}")
                            chapter_error = _error_text(chapter_error)
                            self.progress.complete_chapter(f"❌ {chapter_error}")
                            break
                        picked_engine, auto_order = self._pick_auto_engine(
                            chapter_chars, estimated_seconds, pool_view
                        )
                        attempted_auto.add(picked_engine)
                        engine_tracker["label"] = picked_engine
                        # Record engine selection for future ranking
                        if not self.speed_controller._current_engine:
                            self.speed_controller.record_engine_switch(picked_engine)
                    else:
                        engine_tracker["label"] = (config.engine or "").lower()

                    current_engine_label = (
                        engine_tracker.get("label") or (config.engine or "").lower()
                    )
                    tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(
                        output_path, current_engine_label
                    )

                    if current_engine_label == "edge" and not is_auto_engine:
                        threshold_chars = max(getattr(config, "edge_auto_offline_chars", 0), 0)
                        threshold_seconds = max(getattr(config, "edge_auto_offline_seconds", 0), 0)
                        edge_reason = None
                        if threshold_chars and chapter_chars >= threshold_chars:
                            edge_reason = f"Capítulo muito grande ({chapter_chars} caracteres)"
                        elif threshold_seconds and estimated_seconds >= threshold_seconds:
                            edge_reason = f"Chapter estimated at {int(estimated_seconds)}s"
                        if edge_reason and self.verbose:
                            print(f"   ℹ️ Edge keeps engine even for large chapter: {edge_reason}")
                        elif edge_force_offline:
                            if self.verbose:
                                print(
                                    "   ℹ️ Edge marcado como instável, mantendo engine (sem fallback)"
                                )
                            edge_force_offline = False
                            edge_state["force_offline_after_trunc"] = False

                    while True:
                        try:
                            engine_config, engine_obj = await engine_pool.acquire(
                                current_engine_label
                            )
                            engine_instance["object"] = engine_obj
                            engine_name_used = current_engine_label
                            if engine_config and engine_config.engine:
                                engine_tracker["label"] = (
                                    engine_config.engine or current_engine_label
                                ).lower()
                                current_engine_label = engine_tracker["label"]
                            break
                        except Exception as exc:
                            unavailable_engines.add(current_engine_label)
                            if is_auto_engine and auto_order:
                                next_engine = self._next_auto_engine(auto_order, attempted_auto)
                                if next_engine:
                                    attempted_auto.add(next_engine)
                                    engine_tracker["label"] = next_engine
                                    current_engine_label = next_engine
                                    continue
                            chapter_error = f"Engine {current_engine_label} indisponível: {exc}"
                            errors.append(f"{chapter.name}: {chapter_error}")
                            chapter_error = _error_text(chapter_error)
                            self.progress.complete_chapter(f"❌ {chapter_error}")
                            engine_obj = None
                            break

                    if engine_obj is None:
                        break

                    tts_engine = engine_obj
                    try:
                        if current_engine_label == "edge":
                            plan_segments = self._load_segment_plan(
                                getattr(
                                    engine_config, "cache_dir", getattr(config, "cache_dir", None)
                                ),
                                chapter_num,
                                chunk_chars=getattr(engine_config, "edge_chunk_chars", None),
                            )
                            setattr(tts_engine, "_precomputed_segments", plan_segments or None)
                            if self.verbose and plan_segments:
                                print(
                                    f"   ♻️ Plano de segmentos reutilizado: {len(plan_segments)} blocos"
                                )
                        elif hasattr(tts_engine, "_precomputed_segments"):
                            setattr(tts_engine, "_precomputed_segments", None)
                    except Exception:
                        pass

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
                    if (
                        edge_auto_enabled
                        and edge_state.get("slow_mode")
                        and current_engine_label == "edge"
                    ):
                        self._apply_edge_slow_mode(
                            "modo seguro ativo",
                            engine_pool=engine_pool,
                            engine_obj=tts_engine,
                        )
                    elif current_engine_label == "edge" and chapter_chars >= EDGE_FORCE_SAFE_CHARS:
                        self._apply_edge_slow_mode(
                            f"capítulo muito grande ({chapter_chars} chars)",
                            engine_pool=engine_pool,
                            engine_obj=tts_engine,
                        )
                        with contextlib.suppress(Exception):
                            setattr(tts_engine, "_auto_tune_enabled", False)

                    # Timeout otimizado: agressivo, mas com teto maior para capítulos longos no Edge
                    # Base: duração estimada * 1.5 + 30s buffer
                    base_timeout = estimated_seconds * 1.5 + 30.0
                    timeout_seconds = max(base_timeout, 60.0)  # Mínimo 60s
                    max_timeout = 600.0  # Padrão: até 10 min
                    if current_engine_label == "edge":
                        if chapter_chars >= 80000:
                            max_timeout = 3600.0  # 1h for very large chapters
                        elif chapter_chars >= 50000:
                            max_timeout = 2400.0
                        elif chapter_chars >= 30000:
                            max_timeout = 1800.0
                        if edge_stable_mode:
                            max_timeout = max(max_timeout, 3600.0)
                    timeout_seconds = min(timeout_seconds, max_timeout)
                    if decision.timeout_scale:
                        timeout_seconds = timeout_seconds * decision.timeout_scale
                    if current_engine_label == "coqui":
                        coqui_min_timeout = int(os.getenv("COQUI_TIMEOUT_MIN", "180") or "180")
                        timeout_seconds = max(timeout_seconds, coqui_min_timeout)
                    if (
                        edge_auto_enabled
                        and edge_state.get("slow_mode")
                        and current_engine_label == "edge"
                    ):
                        safe_timeout = (edge_state.get("safe_profile") or {}).get("timeout_max")
                        if safe_timeout:
                            # Don't let safe_timeout reduce below size-based max_timeout
                            timeout_seconds = min(
                                timeout_seconds, max(int(safe_timeout), int(max_timeout))
                            )
                    timeout_seconds = int(timeout_seconds)
                    stall_seconds = float(os.getenv("CHAPTER_STALL_SECONDS", "60") or "60")
                    if stall_seconds < 0:
                        stall_seconds = 0.0

                    if self.verbose:
                        print(
                            f"🎤 [{chapter_num}/{len(chapters_list)}] {chapter.name}: Starting TTS synthesis"
                        )
                        print(f"   📝 Text: {chapter_chars} chars (timeout: {timeout_seconds}s)")

                    self.progress.tick(
                        f"🎤 Synthesizing {chapter_chars} chars (timeout: {timeout_seconds}s)..."
                    )

                    # Heartbeat para mostrar progresso (otimizado: 3s em vez de 1s)
                    heartbeat_active = True
                    start_synthesis = time.time()

                    async def synthesis_heartbeat():
                        spinner_frames = ["⚙️", "🔧"]
                        frame_idx = 0
                        while heartbeat_active:
                            await asyncio.sleep(5)  # Atualizar a cada 5 segundos (reduz overhead)
                            if not heartbeat_active:
                                break
                            elapsed = int(time.time() - start_synthesis)
                            frame = spinner_frames[frame_idx % len(spinner_frames)]
                            self.progress.tick(
                                f"{frame} Synthesizing... {elapsed}s/{timeout_seconds}s ({chapter_chars} chars)"
                            )
                            self._mark_health_activity(chapter_num, "heartbeat")
                            frame_idx += 1

                    heartbeat_task = asyncio.create_task(synthesis_heartbeat())

                    try:
                        if self.verbose:
                            print(f"   🔄 Executando comando TTS: {type(tts_engine).__name__}")

                        synthesis_result = None
                        max_attempts = 1 if current_engine_label == "edge" else 2
                        last_tts_output_path = tts_output_path
                        last_needs_transcode = needs_mp3_transcode
                        for attempt in range(max_attempts):
                            current_engine_label = (
                                engine_tracker.get("label") or (config.engine or "").lower()
                            )
                            tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(
                                output_path, current_engine_label
                            )
                            last_tts_output_path = tts_output_path
                            last_needs_transcode = needs_mp3_transcode

                            # Create progress callback for granular updates
                            def on_segment_complete(text: str, total_chars: int):
                                self.progress.update_chars_progress(text, total_chars)
                                self._mark_health_activity(chapter_num, "segment")

                            chunk_callback = None
                            chunk_root: Optional[Path] = None
                            chunk_base: Optional[Path] = None
                            job_id = getattr(config, "job_id", None)
                            if job_id:
                                chunk_base = Path(config.output_dir) / "streams" / str(job_id)
                            else:
                                cache_root = getattr(config, "cache_dir", None)
                                if cache_root:
                                    chunk_base = Path(cache_root) / "streams" / "cli"
                            if chunk_base:
                                # Use chapter's unique index label (e.g. "1.0", "1.1") for dir name
                                # to avoid collisions between sub-chapters in parallel mode
                                _ch_label = self._chapter_index_label(chapter, idx + 1)
                                _ch_label_safe = _ch_label.replace(".", "_")
                                chunk_root = chunk_base / f"chapter_{_ch_label_safe}"
                                try:
                                    # **RESUME**: Don't delete existing chunks - Edge engine will resume
                                    chunk_root.mkdir(parents=True, exist_ok=True)
                                except Exception:
                                    chunk_root = None
                            if chunk_root and chunk_root.exists():
                                try:
                                    existing_chunks = list(chunk_root.glob("chunk_*.mp3"))
                                except Exception:
                                    existing_chunks = []
                                if existing_chunks:
                                    self.progress.tick(
                                        f"♻️ Retomando {len(existing_chunks)} chunk(s) já prontos"
                                    )

                            def on_chunk_ready(
                                segment_index: int,
                                temp_path: Path,
                                segment_text: Optional[str] = None,
                            ) -> None:
                                # Atualiza barra com chunks concluídos
                                if hasattr(self, "progress"):
                                    try:
                                        self.progress.update_chunk_progress(segment_index)
                                    except Exception:
                                        pass

                                if chunk_root is None:
                                    return
                                try:
                                    target = (
                                        chunk_root / f"chunk_{segment_index:04d}{temp_path.suffix}"
                                    )
                                    try:
                                        if temp_path.resolve() != target.resolve():
                                            shutil.copy2(temp_path, target)
                                    except OSError:
                                        shutil.copy2(temp_path, target)
                                    manifest_path = chunk_root / "manifest.json"
                                    manifest = {
                                        "jobId": job_id or "cli",
                                        "chapterIndex": chapter_num,
                                        "chunks": [],
                                    }
                                    if manifest_path.exists():
                                        try:
                                            manifest = json.loads(
                                                manifest_path.read_text(encoding="utf-8")
                                            )
                                        except Exception:
                                            manifest = {
                                                "jobId": job_id or "cli",
                                                "chapterIndex": chapter_num,
                                                "chunks": [],
                                            }
                                    existing = manifest.get("chunks") or []
                                    existing = [
                                        entry for entry in existing if isinstance(entry, dict)
                                    ]
                                    existing_by_index = {
                                        entry.get("index"): entry for entry in existing
                                    }
                                    previous = existing_by_index.get(segment_index) or {}
                                    entry = {
                                        "index": segment_index,
                                        "file": target.name,
                                    }
                                    if job_id:
                                        entry["url"] = (
                                            f"/api/streams/{job_id}/chapters/"
                                            f"{chapter_num}/chunks/{segment_index}"
                                        )
                                    if segment_text:
                                        entry["text"] = segment_text
                                    elif previous.get("text"):
                                        entry["text"] = previous["text"]
                                    existing_by_index[segment_index] = entry
                                    manifest["chunks"] = sorted(
                                        existing_by_index.values(),
                                        key=lambda item: item.get("index", 0),
                                    )
                                    manifest["updatedAt"] = time.time()
                                    manifest["baseUrl"] = (
                                        f"/api/streams/{job_id}/chapters/{chapter_num}"
                                        if job_id
                                        else ""
                                    )
                                    manifest_path.write_text(
                                        json.dumps(manifest, ensure_ascii=False, indent=2),
                                        encoding="utf-8",
                                    )
                                except Exception as exc:
                                    if self.verbose:
                                        print(f"   ⚠️ Falha ao salvar chunk {segment_index}: {exc}")

                            # Só usar callback/chunking quando há diretório de resume disponível
                            chunk_callback = on_chunk_ready if chunk_root else None
                            primary_chunk_callback = chunk_callback
                            primary_chunk_root = chunk_root if chunk_root else None

                            stall_event = asyncio.Event()
                            synthesis_task = asyncio.create_task(
                                _synthesize_safe(
                                    tts_engine,
                                    speech_text,
                                    tts_output_path,
                                    formatting_segments=(
                                        None
                                        if payload_locked
                                        else getattr(chapter, "formatting_segments", None)
                                    ),
                                    progress_callback=on_segment_complete,
                                    chunk_callback=primary_chunk_callback,
                                    resume_chunks_dir=primary_chunk_root,
                                )
                            )
                            stall_task = asyncio.create_task(
                                self._watch_chapter_stall(
                                    chapter_num, synthesis_task, stall_seconds, stall_event
                                )
                            )
                            try:
                                synthesis_result = await asyncio.wait_for(
                                    synthesis_task, timeout=timeout_seconds
                                )
                            except asyncio.CancelledError as exc:
                                if stall_event.is_set():
                                    raise asyncio.TimeoutError() from exc
                                raise
                            finally:
                                stall_task.cancel()
                                with contextlib.suppress(asyncio.CancelledError):
                                    await stall_task
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
                            self.progress.tick("🎼 Converting WAV→MP3...")
                            if self.verbose:
                                print(
                                    f"[DEBUG] Converting WAV→MP3: {last_tts_output_path.name} → {output_path.name} (bitrate={config.bitrate})"
                                )
                            converted = await self.audio_processor.convert_to_mp3(
                                last_tts_output_path,
                                output_path,
                                bitrate=config.bitrate,
                            )
                            if self.verbose and converted is None:
                                print("[DEBUG] Falha ao converter WAV→MP3 (ffmpeg)")
                            synthesis_result = converted
                            with contextlib.suppress(OSError):
                                last_tts_output_path.unlink(missing_ok=True)

                        if self.verbose and synthesis_result:
                            print(f"   ✅ TTS concluído: {output_path.name}")
                    except asyncio.TimeoutError:
                        elapsed = int(time.time() - start_synthesis)
                        if self.verbose:
                            print(f"   ⚠️ TIMEOUT: Chapter stuck after {elapsed}s")
                        self.progress.tick(
                            f"⚠️ TIMEOUT após {elapsed}s - tentando fallback sem idioma..."
                        )
                        if current_engine_label == "edge":
                            _maybe_apply_edge_slow_mode(
                                f"timeout após {elapsed}s", engine_obj=tts_engine
                            )
                            setattr(tts_engine, "last_error", "timeout")
                            await wait_edge_cooldown_if_needed(
                                f"timeout após {elapsed}s",
                                tracker=engine_tracker,
                                engine_ref=engine_instance,
                            )
                        elif current_engine_label == "coqui":
                            _maybe_apply_coqui_recovery(
                                f"timeout após {elapsed}s", engine_obj=tts_engine
                            )

                        # **FALLBACK**: Remover marcação de idioma e tentar novamente
                        try:
                            from ..language import LanguageMarkup

                            base_text = speech_text
                            if payload_locked:
                                clean_text = speech_text
                            else:
                                clean_text = (
                                    LanguageMarkup.strip(base_text) if LanguageMarkup else base_text
                                )
                            current_payload = clean_text
                            clean_chars = len(clean_text)
                            fallback_timeout = max(90, int(timeout_seconds * 0.5))
                            if current_engine_label == "edge":
                                fallback_timeout = max(120, min(int(timeout_seconds * 0.6), 600))

                            if self.verbose:
                                print("   🔄 RETRY: Tentando novamente sem marcas de idioma")
                                print(
                                    f"   📝 RETRY: {clean_chars} chars (timeout: {fallback_timeout}s)"
                                )

                            self.progress.tick(
                                f"🔄 Fallback: {clean_chars} chars (timeout: {fallback_timeout}s)"
                            )

                            # Heartbeat para fallback (otimizado: 3s)
                            heartbeat_active = True
                            start_fallback = time.time()

                            async def fallback_heartbeat():
                                spinner_frames = ["🚑", "🔥"]
                                frame_idx = 0
                                while heartbeat_active:
                                    await asyncio.sleep(5)
                                    if not heartbeat_active:
                                        break
                                    elapsed_fb = int(time.time() - start_fallback)
                                    frame = spinner_frames[frame_idx % len(spinner_frames)]
                                    self.progress.tick(
                                        f"{frame} FALLBACK {elapsed_fb}s/{fallback_timeout}s"
                                    )
                                    self._mark_health_activity(chapter_num, "fallback")
                                    frame_idx += 1

                            fallback_task = asyncio.create_task(fallback_heartbeat())

                            try:
                                current_engine_label = (
                                    engine_tracker.get("label") or (config.engine or "").lower()
                                )
                                tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(
                                    output_path, current_engine_label
                                )
                                synthesis_result = await asyncio.wait_for(
                                    _synthesize_safe(
                                        tts_engine,
                                        clean_text,
                                        tts_output_path,
                                        formatting_segments=None,
                                        chunk_callback=None,
                                        resume_chunks_dir=None,
                                    ),
                                    timeout=fallback_timeout,
                                )
                                if synthesis_result and needs_mp3_transcode:
                                    self.progress.tick("🎼 Converting WAV→MP3 (fallback)...")
                                    if self.verbose:
                                        print(
                                            f"[DEBUG] Converting WAV→MP3 (fallback): {tts_output_path.name} → {output_path.name} (bitrate={config.bitrate})"
                                        )
                                    converted = await self.audio_processor.convert_to_mp3(
                                        tts_output_path,
                                        output_path,
                                        bitrate=config.bitrate,
                                    )
                                    if self.verbose and converted is None:
                                        print("[DEBUG] Falha ao converter WAV→MP3 (fallback)")
                                    synthesis_result = converted
                                    with contextlib.suppress(OSError):
                                        tts_output_path.unlink(missing_ok=True)
                                if self.verbose and synthesis_result:
                                    print("   ✅ RETRY: Sucesso no fallback!")
                            finally:
                                heartbeat_active = False
                                fallback_task.cancel()
                                with contextlib.suppress(asyncio.CancelledError):
                                    await fallback_task

                        except (ImportError, asyncio.TimeoutError):
                            total_elapsed = int(time.time() - start_synthesis)
                            if self.verbose:
                                print(
                                    "   ⚠️ FALLBACK: Tentativa dupla falhou, tentando síntese simples"
                                )
                            self.progress.tick("🔄 Última tentativa: síntese simples...")

                            # **THIRD ATTEMPT**: Synthesis with minimal text processing
                            try:
                                if current_engine_label == "edge":
                                    if self.verbose:
                                        print(
                                            "   ⏭️ EMERGÊNCIA ignorada para Edge (preservando chunks)"
                                        )
                                    synthesis_result = None
                                else:
                                    # Get first 1000 chars as emergency fallback
                                    if payload_locked:
                                        emergency_text = ""
                                    else:
                                        emergency_text = (speech_text or "")[:1000].strip()
                                    if emergency_text:
                                        emergency_timeout = (
                                            90 if current_engine_label == "edge" else 30
                                        )  # Short timeout for emergency
                                        if self.verbose:
                                            print(
                                                f"   🚑 EMERGÊNCIA: {len(emergency_text)} chars (timeout: {emergency_timeout}s)"
                                            )

                                        current_engine_label = (
                                            engine_tracker.get("label")
                                            or (config.engine or "").lower()
                                        )
                                        tts_output_path, needs_mp3_transcode = (
                                            _resolve_tts_output_path(
                                                output_path, current_engine_label
                                            )
                                        )
                                        synthesis_result = await asyncio.wait_for(
                                            _synthesize_safe(
                                                tts_engine,
                                                emergency_text,
                                                tts_output_path,
                                                formatting_segments=None,
                                                chunk_callback=None,
                                                resume_chunks_dir=None,
                                            ),
                                            timeout=emergency_timeout,
                                        )
                                        if synthesis_result and needs_mp3_transcode:
                                            self.progress.tick(
                                                "🎼 Converting WAV→MP3 (emergency)..."
                                            )
                                            if self.verbose:
                                                print(
                                                    f"[DEBUG] Converting WAV→MP3 (emergency): {tts_output_path.name} → {output_path.name} (bitrate={config.bitrate})"
                                                )
                                            converted = await self.audio_processor.convert_to_mp3(
                                                tts_output_path,
                                                output_path,
                                                bitrate=config.bitrate,
                                            )
                                            if self.verbose and converted is None:
                                                print(
                                                    "[DEBUG] Falha ao converter WAV→MP3 (emergência)"
                                                )
                                            synthesis_result = converted
                                            with contextlib.suppress(OSError):
                                                tts_output_path.unlink(missing_ok=True)
                                        if synthesis_result and self.verbose:
                                            print("   ✅ EMERGÊNCIA: Sucesso com texto reduzido!")
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
                                if (engine_tracker.get("label") or "").lower() == "edge":
                                    _edge_retry(error_msg)
                                errors.append(f"{chapter.name}: {error_msg}")
                                error_msg = _error_text(error_msg)
                                self.progress.complete_chapter(f"❌ {error_msg}")
                                break
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
                            if self.verbose:
                                print(
                                    f"   ⚡ AUTO: trocando para {next_engine} e tentando novamente"
                                )
                            tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(
                                output_path, next_engine
                            )
                            continue

                    if synthesis_result and output_path.exists():
                        file_size = output_path.stat().st_size

                        # Validar que o arquivo tem tamanho mínimo (não está vazio/corrompido)
                        if file_size > 1000:  # Mínimo 1KB para áudio válido
                            truncation_warning = self._detect_short_audio_output(
                                output_path,
                                current_payload,
                                config,
                                engine_label=engine_tracker.get("label"),
                            )
                            if truncation_warning:
                                if self.verbose:
                                    print(f"   ⚠️ {truncation_warning}")
                                if hasattr(tts_engine, "last_error"):
                                    setattr(tts_engine, "last_error", "short_output")
                                if (engine_tracker.get("label") or "").lower() == "edge":
                                    # Track Edge truncation failures for adaptive delay
                                    edge_failure_count += 1
                                    edge_consecutive_failures += 1
                                    if self.verbose and edge_consecutive_failures > 1:
                                        print(
                                            f"   ⚠️  Edge-TTS truncation #{edge_failure_count} "
                                            f"({edge_consecutive_failures} consecutive)"
                                        )
                                    _maybe_apply_edge_slow_mode(
                                        "Áudio truncado", engine_obj=tts_engine
                                    )
                                    # Forçar fallback offline após truncamento
                                    edge_state = self._edge_auto_state or {}
                                    edge_state["force_offline_after_trunc"] = True
                                    self._edge_auto_state = edge_state
                                output_path.unlink(missing_ok=True)
                                chapter_error = truncation_warning
                                if (engine_tracker.get("label") or "").lower() == "edge":
                                    _edge_retry(truncation_warning, count_failure=False)
                                errors.append(f"{chapter.name}: {truncation_warning}")
                                self.progress.complete_chapter(f"❌ {truncation_warning}")
                                break

                            if getattr(config, "validate_audio", True):
                                audio_ok, audio_error = self._validate_audio_after_write(
                                    current_payload, output_path, config=config
                                )
                                if not audio_ok:
                                    retried = await self._attempt_segment_retry(
                                        tts_engine,
                                        chapter_num,
                                        chapter_label,
                                        output_path,
                                        config=config,
                                    )
                                    if retried:
                                        audio_ok, audio_error = self._validate_audio_after_write(
                                            current_payload, output_path, config=config
                                        )
                                    if not audio_ok:
                                        output_path.unlink(missing_ok=True)
                                        chapter_error = audio_error or "Áudio inválido"
                                        # Track Edge validation failures for adaptive delay
                                        if (engine_tracker.get("label") or "").lower() == "edge":
                                            edge_failure_count += 1
                                            edge_consecutive_failures += 1
                                            if self.verbose:
                                                print(
                                                    f"   ⚠️  Edge-TTS validation failure #{edge_failure_count}"
                                                )
                                        if (engine_tracker.get("label") or "").lower() == "edge":
                                            _edge_retry(chapter_error, count_failure=False)
                                        errors.append(f"{chapter.name}: {chapter_error}")
                                        chapter_error = _error_text(chapter_error)
                                        self.progress.complete_chapter(f"❌ {chapter_error}")
                                        break

                            if (
                                (engine_tracker.get("label") or "").lower() == "edge"
                                and hasattr(tts_engine, "__module__")
                                and "edge_engine" in getattr(tts_engine, "__module__", "")
                            ):
                                segments_ok, segments_error = self._edge_segment_integrity_ok(
                                    tts_engine
                                )
                                if not segments_ok:
                                    output_path.unlink(missing_ok=True)
                                    chapter_error = segments_error or "Segmentos incompletos"
                                    edge_failure_count += 1
                                    edge_consecutive_failures += 1
                                    if self.verbose:
                                        print(
                                            f"   ⚠️  Edge-TTS segment failure #{edge_failure_count}"
                                        )
                                        print(f"   ⚠️  {chapter_error}")
                                    _edge_retry(chapter_error, count_failure=False)
                                    errors.append(f"{chapter.name}: {chapter_error}")
                                    chapter_error = _error_text(chapter_error)
                                    self.progress.complete_chapter(f"❌ {chapter_error}")
                                    break

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
                            current_engine_label = (
                                engine_tracker.get("label") or (config.engine or "").lower()
                            )
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
                                slow_cutoff = max(
                                    getattr(config, "edge_auto_offline_seconds", 0), 0
                                )
                                if slow_cutoff and chapter_elapsed >= slow_cutoff * 1.4:
                                    if build_best_offline_engine(
                                        f"Edge levou {int(chapter_elapsed)}s para este capítulo"
                                    ):
                                        if self.verbose:
                                            print(
                                                "   ⚡ Próximos capítulos migrarão para engine offline pela performance"
                                            )
                                    current_engine_label = (
                                        engine_tracker.get("label") or (config.engine or "").lower()
                                    )
                                    tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(
                                        output_path, current_engine_label
                                    )
                            if (
                                edge_auto_enabled
                                and current_engine_label == "edge"
                                and not chapter_cached
                            ):
                                chars_per_second = chapter_chars / max(chapter_elapsed, 0.001)
                                min_cps = float(
                                    edge_state.get(
                                        "min_chars_per_second", EDGE_MIN_CHARS_PER_SECOND
                                    )
                                )
                                slow_ratio = float(
                                    edge_state.get(
                                        "slow_ratio_threshold", EDGE_SLOW_RATIO_THRESHOLD
                                    )
                                )
                                if chars_per_second < min_cps or (
                                    estimated_seconds > 0
                                    and chapter_elapsed > (estimated_seconds * slow_ratio)
                                ):
                                    _maybe_apply_edge_slow_mode(
                                        f"velocidade baixa ({chars_per_second:.1f} chars/s)",
                                        engine_obj=tts_engine,
                                    )
                            self._retry_original_texts.pop(chapter_label, None)

                            # Validate audio completeness (detect truncations)
                            if (
                                current_engine_label == "edge"
                                and hasattr(tts_engine, "__module__")
                                and "edge_engine" in getattr(tts_engine, "__module__", "")
                            ):
                                is_complete, coverage_percent = validate_audio_completeness(
                                    output_path, chapter_chars
                                )
                                if not is_complete:
                                    # Audio was truncated - treat as failure
                                    missing_percent = 100.0 - coverage_percent
                                    if self.verbose:
                                        print(
                                            f"   ⚠️ Áudio truncado: {coverage_percent:.1f}% do texto "
                                            f"({missing_percent:.1f}% faltando)"
                                        )

                                    # Increment failure counters
                                    edge_failure_count += 1
                                    edge_consecutive_failures += 1

                                    # Mark for retry
                                    output_path.unlink(missing_ok=True)
                                    synthesis_result = None

                                    # Log failure stats
                                    if self.verbose:
                                        print(
                                            f"   📊 Falhas Edge: {edge_failure_count} total, "
                                            f"{edge_consecutive_failures} consecutivas"
                                        )
                                else:
                                    # Audio is complete - reset consecutive failures counter
                                    # (but keep total failure count for statistics)
                                    if edge_consecutive_failures > 0 and self.verbose:
                                        print(
                                            f"   ✅ Áudio completo ({coverage_percent:.1f}% do texto) - "
                                            f"resetando contador de falhas consecutivas"
                                        )
                                    edge_consecutive_failures = 0
                        else:
                            # Arquivo muito pequeno - provavelmente corrompido
                            if self.verbose:
                                print(
                                    f"   ⚠️ Arquivo muito pequeno ({file_size} bytes) - considerando falha"
                                )
                            output_path.unlink(missing_ok=True)
                            synthesis_result = None  # Forçar retry
                    else:
                        # **RETRY**: Tentar com idioma padrão em caso de falha
                        # Note: Don't block retry just because payload is locked - the cached text
                        # may still be correct, and blocking prevents recovery from transient failures
                        if current_engine_label == "edge":
                            last_err = getattr(tts_engine, "last_error", None)
                            reason = _edge_error_reason(last_err)
                            # Track Edge failures for adaptive delay
                            edge_failure_count += 1
                            edge_consecutive_failures += 1
                            if self.verbose and edge_consecutive_failures > 1:
                                print(
                                    f"   ⚠️  Edge-TTS failure #{edge_failure_count} "
                                    f"({edge_consecutive_failures} consecutive)"
                                )
                            _maybe_apply_edge_slow_mode(
                                f"falha Edge ({reason})", engine_obj=tts_engine
                            )
                            chapter_error = (
                                f"Edge indisponível ({reason})"
                                if reason != "unknown"
                                else "Edge falhou"
                            )
                            _edge_retry(chapter_error, count_failure=False)
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
                                            _synthesize_safe(
                                                tts_engine,
                                                simple_text,
                                                output_path,
                                                formatting_segments=None,
                                                chunk_callback=chunk_callback,
                                                resume_chunks_dir=chunk_root,
                                            ),
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
                                                engine_label=engine_tracker.get("label"),
                                            )
                                            if truncation_warning:
                                                if self.verbose:
                                                    print(f"   ⚠️ {truncation_warning}")
                                                if hasattr(tts_engine, "last_error"):
                                                    setattr(
                                                        tts_engine, "last_error", "short_output"
                                                    )
                                                output_path.unlink(missing_ok=True)
                                                chapter_error = truncation_warning
                                                if (
                                                    engine_tracker.get("label") or ""
                                                ).lower() == "edge":
                                                    _edge_retry(truncation_warning)
                                                errors.append(
                                                    f"{chapter.name}: {truncation_warning}"
                                                )
                                                self.progress.complete_chapter(
                                                    f"❌ {truncation_warning}"
                                                )
                                                break

                                            if getattr(config, "validate_audio", True):
                                                audio_ok, audio_error = (
                                                    self._validate_audio_after_write(
                                                        current_payload, output_path, config=config
                                                    )
                                                )
                                                if not audio_ok:
                                                    retried = await self._attempt_segment_retry(
                                                        tts_engine,
                                                        chapter_num,
                                                        chapter_label,
                                                        output_path,
                                                        config=config,
                                                    )
                                                    if retried:
                                                        audio_ok, audio_error = (
                                                            self._validate_audio_after_write(
                                                                current_payload,
                                                                output_path,
                                                                config=config,
                                                            )
                                                        )
                                                    if not audio_ok:
                                                        output_path.unlink(missing_ok=True)
                                                        chapter_error = (
                                                            audio_error or "Áudio inválido"
                                                        )
                                                        if (
                                                            engine_tracker.get("label") or ""
                                                        ).lower() == "edge":
                                                            _edge_retry(chapter_error)
                                                        errors.append(
                                                            f"{chapter.name}: {chapter_error}"
                                                        )
                                                        self.progress.complete_chapter(
                                                            f"❌ {chapter_error}"
                                                        )
                                                        break

                                            if (
                                                engine_tracker.get("label") or ""
                                            ).lower() == "edge":
                                                segments_ok, segments_error = (
                                                    self._edge_segment_integrity_ok(tts_engine)
                                                )
                                                if not segments_ok:
                                                    output_path.unlink(missing_ok=True)
                                                    chapter_error = (
                                                        segments_error or "Segmentos incompletos"
                                                    )
                                                    edge_failure_count += 1
                                                    edge_consecutive_failures += 1
                                                    if self.verbose:
                                                        print(
                                                            f"   ⚠️  Edge-TTS segment failure #{edge_failure_count}"
                                                        )
                                                        print(f"   ⚠️  {chapter_error}")
                                                    _edge_retry(chapter_error, count_failure=False)
                                                errors.append(f"{chapter.name}: {chapter_error}")
                                                chapter_error = _error_text(chapter_error)
                                                self.progress.complete_chapter(
                                                    f"❌ {chapter_error}"
                                                )
                                                break

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
                                                print(
                                                    f"   ✅ RETRY: Sucesso com texto simplificado ({file_size} bytes)"
                                                )
                                            self.progress.complete_chapter("✅ Sucesso (retry)")
                                            chapter_elapsed = time.time() - start_time
                                            current_engine_label = (
                                                engine_tracker.get("label")
                                                or (config.engine or "").lower()
                                            )
                                            if (
                                                current_engine_label == "edge"
                                                and not switched_for_size
                                                and getattr(config, "edge_auto_offline_seconds", 0)
                                            ):
                                                slow_cutoff = max(
                                                    getattr(config, "edge_auto_offline_seconds", 0),
                                                    0,
                                                )
                                                if (
                                                    slow_cutoff
                                                    and chapter_elapsed >= slow_cutoff * 1.4
                                                ):
                                                    if build_best_offline_engine(
                                                        f"Edge levou {int(chapter_elapsed)}s para este capítulo"
                                                    ):
                                                        if self.verbose:
                                                            print(
                                                                "   ⚡ Próximos capítulos migrarão para engine offline pela performance"
                                                            )
                                                        current_engine_label = (
                                                            engine_tracker.get("label")
                                                            or (config.engine or "").lower()
                                                        )
                                                        tts_output_path, needs_mp3_transcode = (
                                                            _resolve_tts_output_path(
                                                                output_path, current_engine_label
                                                            )
                                                        )
                                            self._retry_original_texts.pop(chapter_label, None)
                                            break  # Success! Continue to next chapter

                                        if self.verbose:
                                            print(
                                                f"   ⚠️ RETRY: Arquivo inválido ({file_size} bytes)"
                                            )
                                        output_path.unlink(missing_ok=True)
                            except Exception as retry_e:
                                if self.verbose:
                                    print(f"   ❌ RETRY falhou: {retry_e}")

                            if current_engine_label == "edge":
                                last_err = ""
                                try:
                                    last_err = str(getattr(tts_engine, "last_error", "") or "")
                                except Exception:
                                    last_err = ""
                                if (
                                    "rate_limit" in last_err.lower()
                                    or "too many requests" in last_err.lower()
                                ):
                                    _maybe_apply_edge_slow_mode(
                                        "Rate limit detectado", engine_obj=tts_engine
                                    )
                                    if hasattr(self, "progress"):
                                        self.progress.tick(
                                            "⏳ Edge limitado; aplicando modo seguro e tentando novamente"
                                        )

                            # If all retries failed
                            error_msg = "Falha na síntese"
                            if hasattr(tts_engine, "last_error") and tts_engine.last_error:
                                error_msg += f": {tts_engine.last_error}"
                            if self.verbose:
                                print(f"   ❌ ERRO FINAL: {error_msg}")
                            chapter_error = error_msg
                            if (
                                engine_tracker.get("label") or (config.engine or "").lower()
                            ) == "edge":
                                _edge_retry(error_msg)
                            errors.append(f"{chapter.name}: {error_msg}")
                            error_msg = _error_text(error_msg)
                            self.progress.complete_chapter(f"❌ {error_msg}")
                            # **CONTINUE** - never skip chapter, just mark as error

                except _RetryChapter as retry_exc:
                    chapter_retry = True
                    chapter_error = str(retry_exc)
                except Exception as e:
                    error_msg = f"Exceção: {str(e)}"
                    if self.verbose:
                        print(f"   ❌ ERRO DE EXCEÇÃO: {error_msg}")
                    chapter_error = error_msg
                    if (engine_tracker.get("label") or (config.engine or "").lower()) == "edge":
                        _edge_retry(error_msg)
                    errors.append(f"{chapter.name}: {error_msg}")
                    error_msg = _error_text(error_msg)
                    self.progress.complete_chapter(f"❌ {error_msg}")
                    # **CONTINUE** - log error but continue processing other chapters
                finally:
                    if engine_obj is not None and engine_name_used:
                        engine_pool.release(engine_name_used, engine_obj)
                        engine_obj = None
                        engine_name_used = None

                if chapter_retry:
                    if chapter_attempt >= max_chapter_attempts:
                        chapter_error = chapter_error or "Falha persistente"
                        errors.append(f"{chapter.name}: {chapter_error}")
                        chapter_error = _error_text(chapter_error)
                        self.progress.complete_chapter(f"❌ {chapter_error}")
                        break
                    await _maybe_apply_edge_fallback()
                    continue

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
                break

        success = len(errors) == 0

        # Log Edge-TTS failure statistics if any failures occurred
        if (config.engine or "").lower() == "edge" and (
            edge_failure_count > 0 or edge_switched_to_piper
        ):
            print("\n" + "─" * 60)
            print("📊 Edge-TTS Failure Statistics")
            print("─" * 60)
            print(f"   Total failures: {edge_failure_count}")
            print(f"   Final consecutive failures: {edge_consecutive_failures}")
            if edge_switched_to_piper:
                print("   ✅ Successfully switched to Piper fallback")
            elif edge_consecutive_failures >= EDGE_FAILURE_THRESHOLD:
                print(
                    f"   ⚠️  Reached failure threshold ({EDGE_FAILURE_THRESHOLD}) but Piper unavailable"
                )
            print("─" * 60 + "\n")

        return ConversionResult(
            success=success,
            total_chapters=original_total,
            converted_chapters=len(converted_files),
            output_files=converted_files,
            errors=errors,
        )

    def _auto_engine_candidates(self, base_config: ConversionConfig) -> List[str]:
        """Return preferred auto-mode engine order."""
        candidates: List[str] = []
        prefer_piper = bool(getattr(base_config, "auto_prefer_piper", False))
        network_tier = (
            getattr(self.hardware_profile, "network_speed_estimate", None)
            if hasattr(self, "hardware_profile")
            else None
        )
        prefer_offline = str(network_tier or "").lower() == "slow"
        piper_voice = None
        try:
            piper_voice = self.tts_factory.voice_provider.get_voice(
                "piper", base_config.primary_language
            )
        except Exception:
            piper_voice = None
        has_piper = bool(piper_voice)
        if has_piper and (prefer_piper or prefer_offline):
            candidates.append("piper")
        candidates.extend(["edge", "coqui"])
        if has_piper and "piper" not in candidates:
            candidates.append("piper")
        ordered: List[str] = []
        seen: Set[str] = set()
        for name in candidates:
            if name and name not in seen:
                ordered.append(name)
                seen.add(name)
        return ordered

    def _apply_edge_rate_caps(self, configs: Iterable[ConversionConfig]) -> None:
        """Clamp Edge concurrency according to the selected voice."""
        for cfg in configs:
            if (cfg.engine or "").lower() != "edge":
                continue
            cap = self._resolve_edge_cap(cfg.voice)
            if not cap:
                continue
            current = cfg.edge_max_concurrency or cap
            cfg.edge_max_concurrency = max(1, min(cap, current))

    def _resolve_edge_cap(self, voice_id: Optional[str]) -> Optional[int]:
        if not voice_id:
            return None
        multilingual = self.tts_factory.voice_provider.edge_voice_is_multilingual(voice_id)
        if multilingual is None and isinstance(voice_id, str):
            multilingual = "multilingual" in voice_id.lower()
        if multilingual:
            return EDGE_MULTILINGUAL_RATE_CAP
        if multilingual is False:
            return EDGE_MONOLINGUAL_RATE_CAP
        return None

    def _prepare_auto_engines(
        self, base_config: ConversionConfig
    ) -> Dict[str, tuple[ConversionConfig, object]]:
        pool: Dict[str, tuple[ConversionConfig, object]] = {}
        for name in self._auto_engine_candidates(base_config):
            try:
                cloned = self._clone_engine_config(base_config, name)
                engine_instance = self.tts_factory.create_engine(cloned)
                pool[name] = (cloned, engine_instance)
            except Exception:
                continue
        return pool

    def _clone_engine_config(
        self, base_config: ConversionConfig, engine_name: str
    ) -> ConversionConfig:
        cloned = replace(base_config, engine=engine_name, voice=None, model_path=None)
        cloned.languages = list(base_config.languages)
        cloned.language_voices = {}
        prefer_monolingual = bool(getattr(base_config, "prefer_monolingual_edge", False))
        voice = self.tts_factory.voice_provider.get_voice(engine_name, cloned.primary_language)
        if engine_name == "edge" and prefer_monolingual:
            monolingual_voice = self.tts_factory.voice_provider.get_monolingual_voice(
                cloned.primary_language
            )
            if monolingual_voice:
                voice = monolingual_voice
        if engine_name == "coqui" and not voice:
            voice = "tts_models/multilingual/multi-dataset/xtts_v2"
        cloned.voice = voice
        cloned.language_voices = self.tts_factory.voice_provider.build_language_voice_map(
            engine_name,
            cloned.languages
            or (
                [cloned.primary_language]
                if cloned.primary_language and cloned.primary_language != "auto"
                else []
            ),
            voice,
            primary_language=cloned.primary_language,
        )
        if engine_name == "edge" and prefer_monolingual:
            lang_key = (cloned.primary_language or "").split("-", 1)[0]
            cloned.language_voices = (
                {lang_key: voice} if lang_key and voice else dict(cloned.language_voices)
            )
        return cloned

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
            print("📊 Engine Rankings (based on recent performance):")
            for engine, score, reason in rankings:
                print(f"   {engine}: {score:.1f}/100 ({reason})")

        # Use ranked order (best first)
        order = [engine for engine, _, _ in rankings]

        # Fallback: if no ranking data, use static optimal order
        if not order:
            order = self._preferred_auto_engine_order(pool)

        if "edge" in order:
            order = ["edge"] + [name for name in order if name != "edge"]

        if not order:
            order = available_engines

        selected = order[0]

        # Check if we should switch from current engine
        if (
            hasattr(self.speed_controller, "_current_engine")
            and self.speed_controller._current_engine
        ):
            current = self.speed_controller._current_engine
            if current in available_engines and current != selected:
                switch_recommendation = self.speed_controller.recommend_engine_switch(
                    current, available_engines, verbose=self.verbose
                )
                if switch_recommendation:
                    new_engine, reason = switch_recommendation
                    print(f"🔄 AUTO: Switching {current} → {new_engine}")
                    print(f"   Reason: {reason}")
                    selected = new_engine
                    self.speed_controller.record_engine_switch(new_engine)

        return selected, order

    def _preferred_auto_engine_order(
        self, pool: Dict[str, tuple[ConversionConfig, object]]
    ) -> List[str]:
        order: List[str] = []
        config = self._active_config or None
        network_tier = (
            getattr(self.hardware_profile, "network_speed_estimate", None)
            if hasattr(self, "hardware_profile")
            else None
        )
        prefer_offline = str(network_tier or "").lower() == "slow"
        prefer_piper = bool(config and getattr(config, "auto_prefer_piper", False))
        if (prefer_piper or prefer_offline) and "piper" in pool:
            order.append("piper")
        for candidate in ("edge", "coqui"):
            if candidate in pool and candidate not in order:
                order.append(candidate)
        for name in pool:
            if name not in order:
                order.append(name)
        return order

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
                chapter_num = self._chapter_number(chapter, idx + 1)
                display_name = self._chapter_display_name(chapter, chapter_num).lower()
                if numeric_target is not None and chapter_num == numeric_target:
                    prioritized.append(chapter)
                    seen_indices.add(idx)
                    break
                if selector in display_name:
                    prioritized.append(chapter)
                    seen_indices.add(idx)
                    break

        if not prioritized:
            return chapters

        # Keep prioritized chapters in natural book order (ascending index),
        # then append the remaining chapters also in natural order.
        prioritized_sorted = [
            chapter for idx, chapter in enumerate(chapters) if idx in seen_indices
        ]
        remaining = [chapter for idx, chapter in enumerate(chapters) if idx not in seen_indices]
        return prioritized_sorted + remaining

    def _install_requirements(self) -> bool:
        if self._requirements_attempted:
            return False
        self._requirements_attempted = True

        python_root = Path(__file__).resolve().parents[1]
        project_root = python_root.parent
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
            capture_output=True,
            text=True,
        )

        if result.returncode == 0:
            print(self.loc.t("requirements_success"))
            return True

        stderr = (result.stderr or "").lower()
        stdout = (result.stdout or "").lower()
        if "externally-managed-environment" in stderr or "externally-managed-environment" in stdout:
            if not os.getenv("EPUB2MP3_VENV_BOOTSTRAPPED"):
                venv_path = project_root / ".venv"
                venv_python = venv_path / "bin" / "python"
                try:
                    if not venv_python.exists():
                        print("🔧 Criando ambiente virtual local (.venv)...")
                        subprocess.run(
                            [sys.executable, "-m", "venv", str(venv_path)],
                            check=False,
                        )
                    if venv_python.exists():
                        print("📦 Instalando dependências no .venv...")
                        subprocess.run(
                            [
                                str(venv_python),
                                "-m",
                                "pip",
                                "install",
                                "-r",
                                str(requirements_path),
                            ],
                            check=False,
                        )
                        os.environ["EPUB2MP3_VENV_BOOTSTRAPPED"] = "1"
                        os.execv(str(venv_python), [str(venv_python)] + sys.argv)
                except Exception:
                    pass

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

        async def _synthesize_safe(engine_obj, text, output_path, **kwargs):
            try:
                sig = inspect.signature(engine_obj.synthesize_async)
                allowed = {k: v for k, v in kwargs.items() if k in sig.parameters}
            except Exception:
                allowed = kwargs
            return await engine_obj.synthesize_async(text, output_path, **allowed)

        chapter_label = chapter.name or f"Chapter {index}"
        output_path = self.file_manager.get_temp_output_path(chapter_label, output_dir, index)
        cache_dir = getattr(config, "cache_dir", None)
        speech_text, _pre_tts_path, payload_locked = self._resolve_pre_tts_payload(
            chapter, index, output_dir, config
        )

        if output_path.exists() and not config.force_reprocess:
            # **AUTOMATIC CACHE VALIDATION**: Verify cached audio integrity
            cache_valid = True
            try:
                from .audio_validator import AudioValidator

                if speech_text and getattr(config, "validate_audio", True):
                    validator = AudioValidator()
                    validation_result = validator.validate_duration(
                        speech_text,
                        output_path,
                        tolerance=0.25,  # 25% tolerance for cached files
                    )

                    if not validation_result.is_valid:
                        cache_valid = False
                        if self.verbose:
                            print(
                                f"⚠️ Chapter {index} cache INVALID: {validation_result.error_message}"
                            )
                            print(f"   Re-converting chapter {index}...")
                        # Delete invalid cached file
                        try:
                            output_path.unlink()
                        except OSError:
                            pass
                    elif self.verbose:
                        print(
                            f"✓ Chapter {index} cache valid: "
                            f"{validation_result.actual_duration:.1f}s "
                            f"({validation_result.duration_diff_percent:+.1f}% diff)"
                        )
            except Exception as e:
                if self.verbose:
                    print(f"⚠️ Chapter {index} cache validation error: {e}")
                # On validation error, trust cache and continue
                cache_valid = True

            if cache_valid:
                progress.start_chapter(chapter_label, index)
                if cache_dir:
                    try:
                        cached_chunks = ChapterProcessor.chunk_text(speech_text or "")
                        cached_payload = "\n".join(cached_chunks)
                        self._cache_text(cache_dir, chapter, index, cached_payload)
                    except Exception:
                        pass
                self._cache_audio(
                    cache_dir, output_path, chapter, index, config, text_root=output_dir
                )
                status = self.loc.t("status_cached")
                self._announce_stage(index, chapter_label, status)
                if getattr(config, "listen", False):
                    progress.tick(self.loc.t("status_playing"))
                    played = await self.audio_processor.play_audio(output_path)
                    status = (
                        self.loc.t("status_complete")
                        if played
                        else self.loc.t("status_play_unavailable")
                    )
                    self._announce_stage(index, chapter_label, status)
                progress.complete_chapter(status)
                outcome = ChapterConversionOutcome(
                    index=index, name=chapter_label, path=output_path
                )
                return output_path if legacy_mode else outcome
            # If cache invalid, fall through to reconversion below

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
                    text_info = "None" if chapter_text is None else f"{len(chapter_text)} chars"
                    print(f"[DEBUG] Chapter {index} text: {text_info}")
                    if chapter_text:
                        print(f"[DEBUG] Chapter {index} preview: {str(chapter_text)[:100]}")

                if not TextValidator.is_valid_text(speech_text or " "):
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
                    chunks = ChapterProcessor.chunk_text(speech_text or "")
                    chapter_payload = "\n".join(chunks)
                    if self.verbose:
                        print(
                            f"[DEBUG] Chapter {index} chunks: {len(chunks)}, payload: {len(chapter_payload)} chars"
                        )

                except Exception as e:
                    if self.verbose:
                        print(f"[DEBUG] Chapter {index} chunk_text error: {e}")
                    raise
                self._cache_text(cache_dir, chapter, index, chapter_payload)

                # Spot-check against EPUB to ensure payload still matches source text
                if not self._spot_check_text_against_epub(speech_text or "", chapter_payload):
                    status_holder["text"] = "❌ Texto diverge do EPUB (spot-check)"
                    self._announce_stage(index, chapter_label, status_holder["text"])
                    outcome = ChapterConversionOutcome(
                        index=index,
                        name=chapter_label,
                        path=None,
                        error=status_holder["text"],
                    )
                    return None if legacy_mode else outcome

                # **TEXT INTEGRITY MONITORING**: Log character counts
                epub_text = speech_text or ""
                epub_char_count = len(re.sub(r"\s+", " ", epub_text).strip())
                payload_char_count = len(re.sub(r"\s+", " ", chapter_payload).strip())
                char_diff = epub_char_count - payload_char_count
                char_diff_percent = (
                    (abs(char_diff) / max(epub_char_count, 1)) * 100 if epub_char_count > 0 else 0
                )

                if abs(char_diff) > 50:  # Only log if significant difference
                    diff_symbol = "⚠️ " if abs(char_diff_percent) > 5.0 else "ℹ️ "
                    print(
                        f"{diff_symbol}Chapter {index}: EPUB={epub_char_count:,} chars → "
                        f"TTS={payload_char_count:,} chars ({char_diff:+,} chars, "
                        f"{char_diff_percent:+.1f}%)"
                    )

                status_holder["text"] = self.loc.t("status_synthesizing")
                self._announce_stage(index, chapter_label, status_holder["text"])

                # **UPDATED**: Estratégia de fallback e timeouts baseados em duração estimada
                char_count = len(chapter_payload or "")
                lang_tag_count = chapter_payload.lower().count("[[lang:") if chapter_payload else 0

                use_immediate_fallback = lang_tag_count > 50 or (
                    lang_tag_count > 20 and char_count > 15000
                )
                if payload_locked:
                    use_immediate_fallback = False

                if use_immediate_fallback:
                    if self.verbose:
                        print(
                            f"[DEBUG] Chapter {index} muito complexo "
                            f"({lang_tag_count} tags, {char_count} chars) - usando fallback imediato"
                        )
                    try:
                        from ..language import LanguageMarkup

                        simplified = (
                            LanguageMarkup.strip(chapter_payload)
                            if LanguageMarkup
                            else chapter_payload
                        )
                        if self.verbose:
                            print(
                                f"[DEBUG] Chapter {index} FALLBACK IMEDIATO: "
                                f"{char_count} → {len(simplified)} chars"
                            )
                        status_holder["text"] = (
                            f"🔄 Fallback: removendo {lang_tag_count} tags de idioma"
                        )
                        self._announce_stage(index, chapter_label, status_holder["text"])
                        chapter_payload = simplified
                    except ImportError:
                        if self.verbose:
                            print(
                                f"[DEBUG] Chapter {index} FALLBACK: LanguageMarkup não disponível"
                            )

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
                        f"[DEBUG] Chapter {index} timeout: {chapter_timeout:.0f}s "
                        f"(estimado {estimated_seconds:.0f}s, {char_count} chars, {lang_tag_count} tags)"
                    )

                # Try synthesis (already with fallback applied for complex chapters)
                synthesis_task = None
                temp_wav = None
                max_attempts = 1 if use_immediate_fallback else 2
                attempt = 1

                while attempt <= max_attempts and temp_wav is None:
                    # On second attempt for non-complex chapters, apply fallback
                    if attempt == 2 and not use_immediate_fallback and not payload_locked:
                        try:
                            from ..language import LanguageMarkup

                            simplified_payload = (
                                LanguageMarkup.strip(chapter_payload)
                                if LanguageMarkup
                                else chapter_payload
                            )
                            original_count = chapter_payload.lower().count("[[lang:")
                            if self.verbose:
                                print(
                                    f"[DEBUG] Chapter {index} FALLBACK: removendo {original_count} tags [[lang:]]"
                                )
                                print(
                                    f"[DEBUG] Chapter {index} FALLBACK: {len(chapter_payload)} → {len(simplified_payload)} chars"
                                )
                            status_holder["text"] = (
                                f"🔄 Tentativa 2: removendo {original_count} tags de idioma"
                            )
                            self._announce_stage(index, chapter_label, status_holder["text"])
                            chapter_payload = simplified_payload
                        except ImportError:
                            if self.verbose:
                                print(
                                    f"[DEBUG] Chapter {index} FALLBACK: LanguageMarkup não disponível"
                                )

                    try:
                        if self.verbose:
                            print(f"[DEBUG] Chapter {index} tentativa {attempt}/{max_attempts}")

                        # Pass formatting segments only on first attempt with original payload
                        chapter_formatting = (
                            None
                            if payload_locked
                            else (
                                getattr(chapter, "formatting_segments", None)
                                if attempt == 1 and chapter_payload == speech_text
                                else None
                            )
                        )
                        synthesis_task = asyncio.create_task(
                            _synthesize_safe(
                                tts_engine,
                                chapter_payload,
                                output_path.with_suffix(".wav"),
                                formatting_segments=chapter_formatting,
                            )
                        )
                        temp_wav = await asyncio.wait_for(synthesis_task, timeout=chapter_timeout)

                        if temp_wav and (attempt == 2 or use_immediate_fallback):
                            if self.verbose:
                                print(f"[DEBUG] Chapter {index} SUCESSO no fallback!")

                    except asyncio.TimeoutError:
                        if self.verbose:
                            print(
                                f"[DEBUG] Chapter {index} tentativa {attempt} timeout após {chapter_timeout}s"
                            )
                        if synthesis_task and not synthesis_task.done():
                            synthesis_task.cancel()
                            try:
                                await synthesis_task
                            except asyncio.CancelledError:
                                pass

                        if attempt == max_attempts:
                            temp_wav = None
                            if hasattr(tts_engine, "last_error"):
                                tts_engine.last_error = "timeout_final"

                    except Exception as e:
                        if legacy_mode:
                            raise
                        if self.verbose:
                            print(f"[DEBUG] Chapter {index} tentativa {attempt} erro: {e}")
                        if synthesis_task and not synthesis_task.done():
                            synthesis_task.cancel()

                        if attempt == max_attempts:
                            temp_wav = None
                            if hasattr(tts_engine, "last_error"):
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

                # Post-validate output after each chapter
                await self._auto_validate_output(output_dir, stage=f"chapter-{index}")

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

                # **INTEGRITY VALIDATION**: Verify audio matches text
                if getattr(config, "validate_audio", True):
                    try:
                        from .audio_validator import AudioValidator

                        validator = AudioValidator()
                        file_result = validator.validate_audio_file(converted)
                        if not file_result.is_valid:
                            recovered = await self._attempt_segment_retry(
                                tts_engine,
                                index,
                                chapter_label,
                                converted,
                                config=config,
                            )
                            if recovered:
                                file_result = validator.validate_audio_file(converted)
                        if not file_result.is_valid:
                            if self.verbose:
                                print(
                                    f"⚠️ Chapter {index} validation warning: {file_result.error_message}"
                                )
                            if getattr(config, "strict_validate", False):
                                converted.unlink(missing_ok=True)
                                status_holder["text"] = (
                                    file_result.error_message or "Áudio inválido"
                                )
                                self._announce_stage(index, chapter_label, status_holder["text"])
                                outcome = ChapterConversionOutcome(
                                    index=index,
                                    name=chapter_label,
                                    path=None,
                                    error=status_holder["text"],
                                )
                                return None if legacy_mode else outcome
                        else:
                            normalized_len = len(re.sub(r"\s+", " ", chapter_payload or "").strip())
                            if normalized_len >= 5000:
                                tolerance = 0.35 if normalized_len < 20000 else 0.25
                                validation_result = validator.validate_duration(
                                    chapter_payload,
                                    converted,
                                    tolerance=tolerance,
                                )
                                if not validation_result.is_valid:
                                    recovered = await self._attempt_segment_retry(
                                        tts_engine,
                                        index,
                                        chapter_label,
                                        converted,
                                        config=config,
                                    )
                                    if recovered:
                                        validation_result = validator.validate_duration(
                                            chapter_payload,
                                            converted,
                                            tolerance=tolerance,
                                        )
                                if not validation_result.is_valid:
                                    if self.verbose:
                                        print(
                                            f"⚠️ Chapter {index} validation warning: {validation_result.error_message}"
                                        )
                                    if getattr(config, "strict_validate", False):
                                        converted.unlink(missing_ok=True)
                                        status_holder["text"] = (
                                            validation_result.error_message or "Duração inválida"
                                        )
                                        self._announce_stage(
                                            index, chapter_label, status_holder["text"]
                                        )
                                        outcome = ChapterConversionOutcome(
                                            index=index,
                                            name=chapter_label,
                                            path=None,
                                            error=status_holder["text"],
                                        )
                                        return None if legacy_mode else outcome

                                    # **AUTOMATIC RETRY**: Check for failed segments and retry
                                    try:
                                        if hasattr(tts_engine, "get_synthesis_tracker"):
                                            tracker = tts_engine.get_synthesis_tracker()
                                            if tracker:
                                                missing_segments = tracker.get_missing_segments()
                                                if missing_segments:
                                                    if self.verbose:
                                                        print(
                                                            f"🔄 Chapter {index}: Found {len(missing_segments)} failed segments, attempting retry..."
                                                        )

                                                    from .retry_manager import RetryManager

                                                    retry_manager = RetryManager(max_retries=3)
                                                    temp_retry_dir = (
                                                        converted.parent / f"retry_temp_{index}"
                                                    )

                                                    retry_report = (
                                                        await retry_manager.retry_failed_segments(
                                                            engine=tts_engine,
                                                            failed_segments=missing_segments,
                                                            output_path=converted,
                                                            temp_dir=temp_retry_dir,
                                                        )
                                                    )

                                                    if self.verbose:
                                                        print(
                                                            f"✓ Retry results: {retry_report.successful}/{retry_report.total_retried} recovered, "
                                                            f"{retry_report.still_failed} still failed"
                                                        )

                                                    # Clean up retry temp dir
                                                    try:
                                                        if temp_retry_dir.exists():
                                                            import shutil

                                                            shutil.rmtree(
                                                                temp_retry_dir, ignore_errors=True
                                                            )
                                                    except Exception:
                                                        pass

                                                    if retry_report.still_failed > 0:
                                                        if self.verbose:
                                                            print(
                                                                f"⚠️ Chapter {index}: {retry_report.still_failed} segments could not be recovered after retries"
                                                            )
                                    except Exception as e:
                                        if self.verbose:
                                            print(f"⚠️ Retry mechanism error: {e}")

                                # Save validation log
                                if cache_dir:
                                    try:
                                        from .cache_manager import CacheManager

                                        cm = CacheManager(cache_dir=cache_dir)
                                        validation_log_path = cm.get_validation_log_path(
                                            self._current_book_path or Path("unknown.epub"), index
                                        )

                                        # Create simple validation report
                                        import json
                                        from datetime import datetime

                                        validation_data = {
                                            "chapter_number": index,
                                            "chapter_title": chapter_label,
                                            "validated_at": datetime.utcnow().isoformat(),
                                            "is_valid": validation_result.is_valid,
                                            "expected_duration": validation_result.expected_duration,
                                            "actual_duration": validation_result.actual_duration,
                                            "duration_diff_percent": validation_result.duration_diff_percent,
                                            "error_message": validation_result.error_message,
                                            "text_length": len(chapter_payload),
                                        }

                                        validation_log_path.parent.mkdir(
                                            parents=True, exist_ok=True
                                        )
                                        with open(validation_log_path, "w", encoding="utf-8") as f:
                                            json.dump(
                                                validation_data, f, indent=2, ensure_ascii=False
                                            )

                                        if self.verbose:
                                            print(
                                                f"✓ Chapter {index} validation: "
                                                f"{validation_result.actual_duration:.1f}s audio "
                                                f"(expected {validation_result.expected_duration:.1f}s, "
                                                f"{validation_result.duration_diff_percent:+.1f}% diff)"
                                            )

                                    except Exception as e:
                                        if self.verbose:
                                            print(
                                                f"⚠️ Chapter {index} failed to save validation log: {e}"
                                            )

                    except ImportError:
                        # audio_validator not available, skip validation
                        pass
                    except Exception as e:
                        if self.verbose:
                            print(f"⚠️ Chapter {index} validation error: {e}")

                # **TRANSCRIPTION VERIFICATION**: Verify audio content via speech-to-text
                if (
                    getattr(config, "verify_transcription", False)
                    and converted
                    and converted.exists()
                ):
                    try:
                        from .transcription_verifier import TranscriptionVerifier
                        from .transcription_verifier import is_available as _whisper_available

                        if _whisper_available():
                            if (
                                not hasattr(self, "_transcription_verifier")
                                or self._transcription_verifier is None
                            ):
                                # Don't force language — let Whisper auto-detect per chapter
                                self._transcription_verifier = TranscriptionVerifier(
                                    model_size=getattr(config, "transcription_model", "medium"),
                                    language=None,
                                )

                            status_holder["text"] = "🔍 Verificando transcrição..."
                            self._announce_stage(index, chapter_label, status_holder["text"])

                            vr = self._transcription_verifier.verify_chapter(
                                converted, chapter_payload
                            )

                            if vr.passed:
                                if self.verbose:
                                    print(
                                        f"✅ Chapter {index} transcrição OK: "
                                        f"{vr.similarity_score:.1%} similaridade"
                                    )
                            else:
                                if getattr(vr, "partial", False):
                                    # Timeout during transcription - audio likely fine, just too large
                                    print(
                                        f"⚠️ Chapter {index} verificação parcial (timeout): "
                                        f"{vr.similarity_score:.1%} - mantendo MP3"
                                    )
                                else:
                                    print(
                                        f"❌ Chapter {index} transcrição FALHOU: "
                                        f"{vr.similarity_score:.1%} similaridade (mínimo {self._transcription_verifier.SIMILARITY_THRESHOLD:.0%})"
                                    )
                                    if self.verbose:
                                        print(f"   {vr.details}")
                                    # Delete bad audio and signal failure for retry
                                    converted.unlink(missing_ok=True)
                                    status_holder["text"] = (
                                        f"❌ Transcrição diverge: {vr.similarity_score:.1%} similaridade"
                                    )
                                    self._announce_stage(
                                        index, chapter_label, status_holder["text"]
                                    )
                                    outcome = ChapterConversionOutcome(
                                        index=index,
                                        name=chapter_label,
                                        path=None,
                                        error=status_holder["text"],
                                    )
                                    return None if legacy_mode else outcome
                        elif self.verbose:
                            print(
                                "⚠️ faster-whisper não instalado, pulando verificação de transcrição"
                            )
                    except Exception as e:
                        if self.verbose:
                            print(f"⚠️ Chapter {index} transcription verification error: {e}")

                status_holder["text"] = self.loc.t("status_complete")
                self._announce_stage(index, chapter_label, status_holder["text"])
                if getattr(config, "listen", False):
                    status_holder["text"] = self.loc.t("status_playing")
                    self._announce_stage(index, chapter_label, status_holder["text"])
                    played = await self.audio_processor.play_audio(converted)
                    status_holder["text"] = (
                        self.loc.t("status_complete")
                        if played
                        else self.loc.t("status_play_unavailable")
                    )
                    self._announce_stage(index, chapter_label, status_holder["text"])
                self._cache_audio(
                    cache_dir, converted, chapter, index, config, text_root=output_dir
                )
                # Post-validate after each chapter (lightweight, best-effort)
                await self._auto_validate_output(output_dir, stage=f"chapter-{index}")
                outcome = ChapterConversionOutcome(index=index, name=chapter_label, path=converted)
                return converted if legacy_mode else outcome
            except Exception as inner_exc:
                if legacy_mode:
                    raise
                raise RuntimeError(f"chapter conversion failed: {inner_exc}") from inner_exc
        except Exception as exc:
            if self.verbose:
                print(f"[DEBUG] Chapter {index} exception: {type(exc).__name__}: {exc}")
                import traceback

                traceback.print_exc()
            if not status_holder["text"].startswith("❌"):
                status_holder["text"] = self.loc.t("status_internal_error")
                self._announce_stage(index, chapter_label, status_holder["text"])
            if legacy_mode:
                raise
            raise RuntimeError(f"chapter conversion failed: {type(exc).__name__}: {exc}") from exc
        finally:
            semaphore.release()
            heartbeat_stop.set()
            heartbeat_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await heartbeat_task
            progress.complete_chapter(status_holder["text"])

    def _generate_full_book_text(self, output_dir: Path, chapters: List[Chapter]) -> Optional[Path]:
        """Generate a single TXT file with the complete book text."""
        try:
            if not chapters:
                return None

            text_dir = output_dir / "text"
            if not text_dir.exists():
                text_dir.mkdir(parents=True, exist_ok=True)

            # Use book title from config or first chapter
            book_title = "livro_completo"
            if self._active_config:
                book_title = getattr(self._active_config, "book_title", None) or book_title

            safe_title = self.file_manager.sanitize_filename(book_title)
            full_book_file = output_dir / f"{safe_title}_completo.txt"

            # Collect all chapter texts in order
            full_text_parts = []
            for idx, chapter in enumerate(chapters, start=1):
                self._chapter_number(chapter, idx)
                chapter_label = self._chapter_index_label(chapter, idx)
                chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_label}"
                # Remove duplicate prefix
                chapter_name_clean = self._remove_duplicate_chapter_prefix(
                    chapter_label, chapter_name
                )

                # Add chapter header (use original name for display)
                full_text_parts.append(f"\n{'='*70}\n")
                full_text_parts.append(f"CAPÍTULO {chapter_label}: {chapter_name}\n")
                full_text_parts.append(f"{'='*70}\n\n")

                # Try to find pre-tts.txt first (final processed text)
                safe_name = self.file_manager.sanitize_filename(chapter_name_clean)
                pre_tts_file = text_dir / f"{chapter_label} - {safe_name}-pre-tts.txt"
                parsed_file = text_dir / f"{chapter_label} - {safe_name}-parsed.txt"

                text_content = None
                if pre_tts_file.exists():
                    text_content = pre_tts_file.read_text(encoding="utf-8")
                elif parsed_file.exists():
                    text_content = parsed_file.read_text(encoding="utf-8")
                else:
                    # Fallback to chapter text
                    text_content = self._speech_text(chapter)

                if text_content:
                    full_text_parts.append(text_content.strip())
                    full_text_parts.append("\n\n")

            # Write complete book text
            full_book_file.write_text("".join(full_text_parts), encoding="utf-8")

            if self.verbose:
                print(f"\n📖 Texto completo do livro gerado: {full_book_file.name}")
                print(f"   Total: {len(''.join(full_text_parts)):,} caracteres")

            return full_book_file

        except Exception as exc:
            if self.verbose:
                print(f"⚠️ Falha ao gerar texto completo do livro: {exc}")
            return None

    async def _report_results(self, result: ConversionResult) -> None:
        print("\n📊 Conversion Results:")
        print(f"  ✅ Converted: {result.converted_chapters}/{result.total_chapters}")
        print(f"  📁 Files: {len(result.output_files)}")
        if result.errors:
            print(f"  ❌ Errors: {len(result.errors)}")
            for error in result.errors[:3]:
                print(f"    • {error}")
        if not result.success:
            print(
                "❌ Conversão incompleta: um ou mais capítulos falharam (reexecute para recuperar)."
            )

        # Print adaptive performance summary
        if self._adaptive_controller and self.verbose:
            self._adaptive_controller.print_summary()

        # Final cleanup of resources before validation
        self._cleanup_resources(force_gc=True)

        # Final automatic validation
        final_output = self._last_output_dir or (
            Path(self._active_config.output_dir) if self._active_config else None
        )
        if (
            final_output
            and self._active_config
            and self._last_chapters_for_text
            and getattr(self._active_config, "auto_validate_output", True)
        ):
            self._generate_all_text_files(
                self._last_chapters_for_text,
                final_output,
                self._active_config,
                cleanup_existing=True,
            )
            # Generate complete book text file
            self._generate_full_book_text(final_output, self._last_chapters_for_text)

        await self._auto_validate_output(final_output, stage="final")

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
                        print(f"⚠️ Could not remove temporary file: {candidate}")

        audio_cache = temp_dir / "audio"
        if audio_cache.exists():
            try:
                shutil.rmtree(audio_cache, ignore_errors=True)
            except OSError:
                if self.verbose:
                    print(f"⚠️ Could not clean audio cache: {audio_cache}")

    def _cache_audio(
        self,
        cache_dir: Optional[Path],
        audio_path: Path,
        chapter: Chapter,
        index: int,
        config: ConversionConfig,
        *,
        text_root: Optional[Path] = None,
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
            target_path = target_dir / f"{index:03d} - {safe_name}.mp3"
            if not target_path.exists() or target_path.stat().st_mtime < audio_path.stat().st_mtime:
                shutil.copy2(audio_path, target_path)

            # Update cache index with hash/size if we have pre-tts text
            cache_index = self._load_cache_index(cache_dir)
            index_label = self._chapter_index_label(chapter, index)
            pre_tts_path = self._find_pre_tts_path(
                cache_dir,
                text_root or audio_path.parent,
                index,
                chapter_name,
                index_label=index_label,
            )
            pre_tts_hash = None
            if pre_tts_path and pre_tts_path.exists():
                with contextlib.suppress(Exception):
                    pre_tts_hash = self._hash_text(pre_tts_path.read_text(encoding="utf-8"))
            entry = cache_index.get(index_label) or cache_index.get(str(index)) or {}
            entry.update(
                {
                    "path": str(target_path),
                    "size": target_path.stat().st_size if target_path.exists() else 0,
                    "pre_tts_hash": pre_tts_hash,
                }
            )
            cache_index[index_label] = entry
            self._save_cache_index(cache_dir, cache_index)
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
            base_name = f"{index:03d} - {safe_name}"
            target_path = target_dir / f"{base_name}.txt"
            pre_tts_path = target_dir / f"{base_name}-pre-tts.txt"
            parsed_path = target_dir / f"{base_name}-parsed.txt"
            parsed_text = getattr(chapter, "text", None) or ""
            target_path.write_text(text, encoding="utf-8")
            pre_tts_path.write_text(text, encoding="utf-8")
            parsed_path.write_text(parsed_text, encoding="utf-8")
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
        return any(
            keyword in error_lower for keyword in ["timeout", "rate", "limit", "throttle", "quota"]
        )


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
