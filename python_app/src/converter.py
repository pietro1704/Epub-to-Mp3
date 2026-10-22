# -*- coding: utf-8 -*-
"""Audio conversion pipeline wired to the TTS engines."""

from __future__ import annotations

import asyncio
import contextlib as contextlib
import difflib as difflib
import gc as gc
import inspect as inspect
import json as json
import os
import random as random
import re
import resource as resource
import shutil as shutil
import socket as socket
import sys as sys
import threading as threading
import time as time
import unicodedata as unicodedata
import uuid as uuid
import weakref as weakref
from concurrent.futures import ThreadPoolExecutor as ThreadPoolExecutor
from dataclasses import dataclass as dataclass, replace as replace
from pathlib import Path
from typing import Any as Any, Callable, Dict, Iterable, List, Optional, Set as Set

import psutil as psutil
from mutagen.mp3 import MP3

from ._cache_mixin import _CacheMixin
from ._edge_throttle_mixin import _EdgeThrottleMixin
from ._engine_selection_mixin import _EngineSelectionMixin
from ._env_utils import env_bool as _env_bool
from ._env_utils import env_float as _env_float
from ._env_utils import env_int as _env_int
from ._health_watchdog_mixin import _await_task_with_deadline as _await_task_with_deadline, _HealthWatchdogMixin, _safe_cancel_task as _safe_cancel_task
from ._metrics_report_mixin import _MetricsReportMixin
from ._output_file_mixin import _OutputFileMixin
from ._retry_mixin import _RetryMixin
from ._server_engine_helpers import _build_multi_engine_slot_map as _build_multi_engine_slot_map
from ._validation_mixin import _ValidationMixin
from .adaptive_performance import AdaptivePerformanceController as AdaptivePerformanceController
from .audio_postprocess import add_silence_padding
from .auto_tuner import AutoTuner as AutoTuner
from .cache_manager import CacheManager as CacheManager
from .converter_lifecycle import ConverterLifecycle
from .converter_telemetry import ConverterTelemetry
from .converter_startup_policy import ConverterStartupPolicy
from .converter_chapter_identity import ConverterChapterIdentity
from .converter_text_preparation import ConverterTextPreparation
from .converter_chapter_selection import ConverterChapterSelection
from .converter_parallel_scheduler import ConverterParallelScheduler
from .converter_models import ChapterConversionOutcome as ChapterConversionOutcome, ConversionResult as ConversionResult
from .chapter_identity import assign_chapter_identities as assign_chapter_identities, chapter_identity_fields as chapter_identity_fields
from .chapter_utils import deduplicate_chapters_by_content as deduplicate_chapters_by_content
from .config import ConversionConfig
from .ebook_reader import Chapter, EbookReader
from .engine_pool import JobEnginePool
from .error_classifier import classify_error as classify_error
from .hardware_detector import HardwareProfile as HardwareProfile
from .i18n import Localization as Localization, get_localization as get_localization
from .performance_profile_store import PerformanceProfileStore as PerformanceProfileStore
from .progress import ProgressTracker
from .speed_controller import AdaptiveSpeedController as AdaptiveSpeedController
from .stream_attempt_observation import atomic_copy_audio as atomic_copy_audio, atomic_write_manifest as atomic_write_manifest, observe_synthesis as observe_synthesis
from .text_integrity_validator import TextIntegrityValidator as TextIntegrityValidator
from .tts.factory import TTSFactory as TTSFactory
from .tts.piper_guard import is_piper_supported_environment
from .utils import AudioProcessor as AudioProcessor, FileManager as FileManager, TextValidator as TextValidator, resolve_cache_root as resolve_cache_root

_piper_supported = is_piper_supported_environment()


def _has_kokoro_support(language: Optional[str]) -> bool:
    """Stub kept for back-compat after the Kokoro engine was removed."""
    return False


def _has_piper_support() -> bool:
    return _piper_supported


def _has_coqui_support() -> bool:
    """Stub kept for back-compat after the Coqui engine was removed."""
    return False


async def _apply_silence_padding(
    output_path: Path,
    config: ConversionConfig,
    *,
    logger: Optional[Callable[[str], None]] = None,
) -> None:
    """Pad a finalised chapter MP3 with configured intro/outro silence.

    Errors are logged but swallowed — padding is cosmetic and must not fail
    the chapter.
    """
    intro = max(int(getattr(config, "chapter_intro_silence_ms", 0) or 0), 0)
    outro = max(int(getattr(config, "chapter_outro_silence_ms", 0) or 0), 0)
    if intro == 0 and outro == 0:
        return
    ok, error = await add_silence_padding(
        output_path,
        intro_ms=intro,
        outro_ms=outro,
        bitrate=getattr(config, "bitrate", "8k") or "8k",
        sample_rate=int(getattr(config, "sample_rate", 16_000) or 16_000),
        channels=int(getattr(config, "channels", 1) or 1),
    )
    if not ok and logger:
        logger(f"   ⚠️ silence padding failed: {error}")


EDGE_AUTO_TUNE = _env_bool("EDGE_AUTO_TUNE", True)
EDGE_MIN_CHARS_PER_SECOND = _env_float("EDGE_MIN_CHARS_PER_SECOND", 60.0)  # Increased from 45
EDGE_SLOW_RATIO_THRESHOLD = _env_float("EDGE_SLOW_RATIO_THRESHOLD", 1.5)  # More sensitive
EDGE_SAFE_CHUNK_CHARS = _env_int("EDGE_SAFE_CHUNK_CHARS", 10000)
EDGE_SAFE_MAX_SEGMENT_SECONDS = _env_float("EDGE_SAFE_MAX_SEGMENT_SECONDS", 300.0)
EDGE_SAFE_CHAPTER_PARALLEL = _env_int("EDGE_SAFE_CHAPTER_PARALLEL", 8)
EDGE_SAFE_TIMEOUT_MAX = _env_float(
    "EDGE_SAFE_TIMEOUT_MAX", 3600.0
)  # Up to 1h for very long chapters
# Three-tier fallback: Edge multilingual → Edge monolingual → Piper
EDGE_MONOLINGUAL_THRESHOLD = _env_int(
    "EDGE_MONOLINGUAL_THRESHOLD", 3
)  # Switch to monolingual Edge after N consecutive failures
EDGE_PIPER_THRESHOLD = _env_int(
    "EDGE_PIPER_THRESHOLD", 3
)  # Switch to Piper after N consecutive failures (after monolingual)
# Legacy env var for backwards compatibility (maps to PIPER threshold)
EDGE_FAILURE_THRESHOLD = _env_int("EDGE_FAILURE_THRESHOLD", EDGE_PIPER_THRESHOLD)
EDGE_FORCE_SAFE_CHARS = _env_int("EDGE_FORCE_SAFE_CHARS", 60000)
# When False (default), stay on Edge (multi → mono) and never switch the whole
# chapter engine to Piper. Per-chunk fallback still handles isolated hangs.
# Flip to True to restore the legacy multi-tier cascade.
ENGINE_CHAIN_FALLBACK = _env_bool("ENGINE_CHAIN_FALLBACK", False)


def _chain_tier_allowed(tier_engine: str) -> bool:
    """Decide whether the given offline tier may take over the whole chapter.

    Honors both ``ENGINE_CHAIN_FALLBACK`` and ``FALLBACK_ENGINE_OVERRIDE``:
    - override=="none" disables every offline tier (wins over ENGINE_CHAIN_FALLBACK).
    - override pointing to a specific engine pins the cascade to that engine
      (permitted even when ENGINE_CHAIN_FALLBACK is off, mirroring server parity).
    - override in {"", "auto"} defers to ENGINE_CHAIN_FALLBACK.
    """
    override = (os.getenv("FALLBACK_ENGINE_OVERRIDE") or "").strip().lower()
    if override == "none":
        return False
    if override == "piper":
        return override == tier_engine
    return ENGINE_CHAIN_FALLBACK


EDGE_AUTO_STABLE = _env_bool("EDGE_AUTO_STABLE", True)
EDGE_AUTO_PARALLEL_CAPS = {
    "slow": _env_int("EDGE_AUTO_PARALLEL_CAP_SLOW", 4),
    "medium": _env_int("EDGE_AUTO_PARALLEL_CAP_MEDIUM", 6),
    "fast": _env_int("EDGE_AUTO_PARALLEL_CAP_FAST", 8),
    "ultra": _env_int("EDGE_AUTO_PARALLEL_CAP_ULTRA", 10),
}
EDGE_MULTILINGUAL_RATE_CAP = _env_int("EDGE_MULTILINGUAL_RATE_CAP", 10)
EDGE_MONOLINGUAL_RATE_CAP = _env_int("EDGE_MONOLINGUAL_RATE_CAP", 16)
EDGE_OFFLINE_LONG_CHARS = _env_int("EDGE_OFFLINE_LONG_CHARS", 70000)
EDGE_OFFLINE_LONG_RATIO = _env_float("EDGE_OFFLINE_LONG_RATIO", 0.35)
EDGE_OFFLINE_TOTAL_CHARS = _env_int("EDGE_OFFLINE_TOTAL_CHARS", 1_200_000)
EDGE_PREDICTIVE_TIMEOUT_ENABLED = _env_bool("EDGE_PREDICTIVE_TIMEOUT_ENABLED", True)
EDGE_PREDICTIVE_TIMEOUT_SECONDS = _env_int("EDGE_PREDICTIVE_TIMEOUT_SECONDS", 900)
EDGE_PREDICTIVE_TIMEOUT_CHARS = _env_int("EDGE_PREDICTIVE_TIMEOUT_CHARS", 30_000)
EDGE_PREDICTIVE_MIN_EDGE_CPS = _env_float("EDGE_PREDICTIVE_MIN_EDGE_CPS", 85.0)
ENGINE_SLOW_FALLBACK_ENABLED = _env_bool("ENGINE_SLOW_FALLBACK_ENABLED", True)
ENGINE_SLOW_FALLBACK_MIN_SECONDS = _env_int("ENGINE_SLOW_FALLBACK_MIN_SECONDS", 90)
ENGINE_SLOW_FALLBACK_TIMEOUT_RATIO = _env_float("ENGINE_SLOW_FALLBACK_TIMEOUT_RATIO", 0.30)
LEGACY_FINAL_FALLBACK_ENABLED = _env_bool("LEGACY_FINAL_FALLBACK_ENABLED", False)
STAGE_PIPELINE_ENABLED_DEFAULT = _env_bool("STAGE_PIPELINE_ENABLED", True)
STAGE_PIPELINE_DEPTH_DEFAULT = max(1, _env_int("STAGE_PIPELINE_DEPTH", 2))
ENGINE_WARM_START_ENABLED = _env_bool("ENGINE_WARM_START_ENABLED", True)
ENGINE_WARM_START_TTL_SECONDS = max(60.0, _env_float("ENGINE_WARM_START_TTL_SECONDS", 14_400.0))

# Validation thresholds
TRUNCATION_THRESHOLD_PERCENT = _env_float(
    "TRUNCATION_THRESHOLD_PERCENT", 10.0
)  # Consider truncated if >10% missing
EXPECTED_WPM = _env_int(
    "EXPECTED_WPM", 200
)  # Expected words per minute for TTS (Edge-TTS neural voices ~200 WPM)
# Lenient acceptance floor: audio that misses the strict TRUNCATION
# threshold but covers ≥ this much of the text is still considered
# complete. Edge-TTS WPM varies by content type (verse reads slower,
# dialogue faster), so a strict 90% bar causes repeated re-synthesis
# of already-adequate audio. Genuine truncations typically show <60%.
# Both CLI (converter.py) and server (_server_audio_helpers.py) read
# this constant — keep them in lock-step.
LENIENT_COVERAGE_THRESHOLD_PERCENT = _env_float("LENIENT_COVERAGE_THRESHOLD_PERCENT", 80.0)
CHARS_PER_WORD = _env_float("CHARS_PER_WORD", 5.0)  # Average characters per word
# Chapters larger than this are skipped entirely (0 = disabled).
# Useful for EPUBs with footnote-container files that hold the entire book text.
MAX_CHAPTER_CHARS = _env_int("MAX_CHAPTER_CHARS", 0)


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

    # Skip check for short chapters: at low char counts the 10% tolerance
    # window is only a few seconds of audio, making natural TTS speed variance
    # (±5-10%) indistinguishable from real truncation. Raised from 1000 to 1500.
    if text_length < 1500:
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


class AudioConverter(
    ConverterLifecycle,
    ConverterTelemetry,
    ConverterStartupPolicy,
    ConverterChapterIdentity,
    ConverterTextPreparation,
    ConverterChapterSelection,
    ConverterParallelScheduler,

    _HealthWatchdogMixin,
    _MetricsReportMixin,
    _OutputFileMixin,
    _CacheMixin,
    _EdgeThrottleMixin,
    _EngineSelectionMixin,
    _RetryMixin,
    _ValidationMixin,
):
    """Coordinate ebook parsing, TTS synthesis and post-processing."""

    _NUMBERED_FILENAME_RE = re.compile(r"^(\d+(?:\.\d+)?)[\s_-]+(.+)$")


        # Product decision: do not switch to offline engines preemptively.
        # Offline engines must be used only after real Edge failures/timeouts.


    async def convert(self, reader: EbookReader, config: ConversionConfig) -> ConversionResult:
        'Convert all chapters in ``reader`` according to ``config``.'
        from .book_conversion_state import BookConversionState
        from .book_conversion_run import _book_conversion_run

        state = BookConversionState(
            reader=reader,
            config=config,
        )
        flow = await _book_conversion_run(self, state)
        return flow.value if flow is not None else None


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
        'Convert chapters sequentially, without parallelism.'
        from .sequential_conversion_state import SequentialConversionState
        from .sequential_conversion_run import _sequential_conversion_run

        state = SequentialConversionState(
            chapters=chapters,
            engine_pool=engine_pool,
            output_dir=output_dir,
            config=config,
            skip_preprocessing=skip_preprocessing,
            is_auto_engine=is_auto_engine,
            auto_engine_pool=auto_engine_pool,
            book_title=book_title,
            book_author=book_author,
            cover_art=cover_art,
        )
        flow = await _sequential_conversion_run(self, state)
        return flow.value if flow is not None else None

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
        from .chapter_conversion_state import ChapterConversionState
        from .chapter_conversion_run import _chapter_conversion_run

        state = ChapterConversionState(
            semaphore=semaphore,
            chapter=chapter,
            tts_engine=tts_engine,
            output_dir=output_dir,
            index=index,
            config=config,
            progress=progress,
        )
        flow = await _chapter_conversion_run(self, state)
        return flow.value if flow is not None else None


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
