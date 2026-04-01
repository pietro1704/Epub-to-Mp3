# -*- coding: utf-8 -*-
"""Audio conversion pipeline wired to the TTS engines."""

from __future__ import annotations

import asyncio
import contextlib
import difflib
import gc
import inspect
import json
import os
import re
import resource
import shutil
import socket
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
from mutagen.mp3 import MP3

from ._cache_mixin import _CacheMixin
from ._edge_throttle_mixin import _EdgeThrottleMixin
from ._engine_selection_mixin import _EngineSelectionMixin
from ._health_watchdog_mixin import _HealthWatchdogMixin
from ._metrics_report_mixin import _MetricsReportMixin
from ._output_file_mixin import _OutputFileMixin
from ._retry_mixin import _RetryMixin
from ._server_engine_helpers import _build_multi_engine_slot_map
from ._validation_mixin import _ValidationMixin
from .adaptive_performance import AdaptivePerformanceController
from .auto_tuner import AutoTuner
from .cache_manager import CacheManager
from .chapter_utils import deduplicate_chapters_by_content
from .config import ConversionConfig
from .ebook_reader import Chapter, EbookReader
from .engine_pool import JobEnginePool
from .hardware_detector import HardwareProfile
from .i18n import Localization, get_localization
from .performance_profile_store import PerformanceProfileStore
from .progress import ProgressTracker
from .speed_controller import AdaptiveSpeedController
from .text_integrity_validator import TextIntegrityValidator
from .tts.coqui_guard import is_coqui_supported_environment
from .tts.factory import TTSFactory
from .tts.kokoro_guard import load_kokoro_supports_language
from .tts.piper_guard import is_piper_supported_environment
from .utils import AudioProcessor, FileManager, TextValidator, resolve_cache_root

_kokoro_support_check = load_kokoro_supports_language()
_coqui_supported = is_coqui_supported_environment()
_piper_supported = is_piper_supported_environment()


def _has_kokoro_support(language: Optional[str]) -> bool:
    if _kokoro_support_check is None:
        return False
    try:
        return bool(_kokoro_support_check(language))
    except Exception:
        return False


def _has_piper_support() -> bool:
    return _piper_supported


def _has_coqui_support() -> bool:
    return _coqui_supported


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


class AudioConverter(
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
        # Persistent chapter checkpoint — survives process restarts
        self._checkpoint_done_set: set[int] = set()
        self._checkpoint_total: int = 0
        self._checkpoint_interval: int = int(os.getenv("CHECKPOINT_INTERVAL", "5"))
        self._auto_fix_guard: bool = False
        self._final_validation_passed: bool = True
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
        self._chapter_stats: Dict[str, float] = {}
        self._eta_recent_cps: List[float] = []
        self._segment_adaptive_state: Dict[str, Any] = {
            "last_event_by_chapter": {},
            "engine_cps": {},
            "last_adjustment": 0.0,
            "cooldown_seconds": 20.0,
            "up_streak": 0,
            "down_streak": 0,
            "pre_reduce_streak": 0,
            "pre_hold_streak": 0,
            "pre_check_counter_by_engine": {},
            "pre_check_interval_by_engine": {},
            "pre_check_stable_streak_by_engine": {},
            "pre_check_base_interval": max(1, _env_int("PRE_SEGMENT_CHECK_BASE_INTERVAL", 1)),
            "pre_check_max_interval": max(1, _env_int("PRE_SEGMENT_CHECK_MAX_INTERVAL", 4)),
            "pre_check_promote_streak": max(2, _env_int("PRE_SEGMENT_CHECK_PROMOTE_STREAK", 6)),
        }
        self._edge_circuit_state: Dict[str, Any] = {
            "open": False,
            "failures": 0,
            "threshold": 2,
            "opened_at": 0.0,
            "cooldown_seconds": 900.0,
            "last_reason": "",
        }
        self._auto_ab_enabled = _env_bool("AUTO_ENGINE_AB_ENABLED", True)
        self._auto_ab_interval = max(2, _env_int("AUTO_ENGINE_AB_INTERVAL", 6))
        self._auto_ab_max_gap = max(1.0, _env_float("AUTO_ENGINE_AB_MAX_GAP", 15.0))
        self._auto_ab_counter = 0
        self._resource_budget_enabled = _env_bool("ENGINE_RESOURCE_BUDGET_ENABLED", True)
        self._engine_resource_budget: Dict[str, Dict[str, int]] = {}
        self._resource_budget_min_share = max(
            0.15, min(0.8, _env_float("ENGINE_RESOURCE_BUDGET_MIN_SHARE", 0.3))
        )
        self._best_param_store = PerformanceProfileStore()
        self._persist_best_params = _env_bool("PERSIST_BEST_ENGINE_PARAMS", True)
        # Warmup is opt-in to avoid changing synthesis semantics unexpectedly.
        self._warmup_before_first_chapter = _env_bool("ENGINE_WARMUP_ENABLED", False)
        self._engine_warmup_done: Set[str] = set()
        self._warm_start_enabled = ENGINE_WARM_START_ENABLED
        self._warm_start_ttl_seconds = ENGINE_WARM_START_TTL_SECONDS
        self._warm_start_path = self._best_param_store.path.with_name("engine-warm-start.json")
        self._eta_baseline_path = self._best_param_store.path.with_name("eta-baselines.json")
        self._eta_baseline_key: Optional[str] = None
        self._startup_guardrail_path = self._best_param_store.path.with_name(
            "startup-guardrail.json"
        )
        self._startup_guardrail_applied = False
        self._canary_profile_done = False
        self._chapter_prefetch_enabled = _env_bool("CHAPTER_PREFETCH_ENABLED", True)
        self._adaptive_checkpoint_enabled = _env_bool("ADAPTIVE_STATE_CHECKPOINT_ENABLED", True)
        self._adaptive_checkpoint_interval = max(
            1, _env_int("ADAPTIVE_STATE_CHECKPOINT_INTERVAL", 1)
        )
        self._adaptive_checkpoint_dirty = 0
        thermal_cap_env = _env_int("THERMAL_PARALLEL_CAP", 0)
        self._thermal_guard_state: Dict[str, Any] = {
            "last_poll": 0.0,
            "poll_interval": max(10.0, _env_float("THERMAL_GUARD_POLL_SECONDS", 20.0)),
            "cap": thermal_cap_env if thermal_cap_env > 0 else None,
            "mode": str(os.getenv("THERMAL_POWER_MODE", "normal") or "normal"),
        }

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

    @staticmethod
    def _normalize_perf_key_piece(value: Optional[str], fallback: str) -> str:
        text = (value or "").strip()
        return text if text else fallback

    def _runtime_tuning_key(
        self, cfg: Optional[ConversionConfig], engine_label: str
    ) -> Dict[str, str]:
        engine = self._normalize_perf_key_piece((engine_label or "").lower(), "unknown")
        voice = self._normalize_perf_key_piece(getattr(cfg, "voice", None), "default")
        language = self._normalize_perf_key_piece(getattr(cfg, "primary_language", None), "auto")
        machine_signature = "generic"
        profile = getattr(self, "hardware_profile", None)
        if profile is not None:
            cpu = int(getattr(profile, "cpu_physical", 0) or 0)
            ram = int(float(getattr(profile, "ram_total_gb", 0.0) or 0.0))
            os_name = str(getattr(profile, "os_type", "unknown") or "unknown").lower()
            net = str(getattr(profile, "network_speed_estimate", "unknown") or "unknown").lower()
            machine_signature = f"{os_name}-c{cpu}-r{ram}-n{net}"
        return {
            "engine": engine,
            "voice": voice,
            "language": language,
            "machine_signature": machine_signature,
        }

    async def _run_engine_warmup(
        self,
        *,
        engine_label: str,
        engine_obj: Optional[object],
        cfg: Optional[ConversionConfig],
        output_dir: Path,
    ) -> None:
        engine_name = (engine_label or "").lower()
        if (
            not self._warmup_before_first_chapter
            or engine_obj is None
            or not hasattr(engine_obj, "synthesize_async")
            or engine_name in self._engine_warmup_done
        ):
            return
        if self._is_warm_start_fresh(cfg, engine_name):
            self._engine_warmup_done.add(engine_name)
            self._append_runtime_metric(
                {"event": "warm_start_hit", "engine": engine_name},
                output_dir=output_dir,
            )
            if self.verbose:
                print(f"⚡ Warm start hit for {engine_name} (skipping warmup)")
            return
        warmup_chars = max(160, _env_int("ENGINE_WARMUP_CHARS", 420))
        warmup_text = ("Warmup segment. " * 40)[:warmup_chars]
        warmup_timeout = max(10.0, _env_float("ENGINE_WARMUP_TIMEOUT_SECONDS", 45.0))
        warmup_dir = Path(output_dir) / ".warmup"
        warmup_dir.mkdir(parents=True, exist_ok=True)
        warmup_path = self._warmup_output_path(warmup_dir, engine_name)
        try:
            await asyncio.wait_for(
                engine_obj.synthesize_async(warmup_text, warmup_path, formatting_segments=None),
                timeout=warmup_timeout,
            )
            self._engine_warmup_done.add(engine_name)
            self._mark_warm_start_ready(cfg, engine_name)
            self._append_runtime_metric(
                {"event": "warm_start_store", "engine": engine_name},
                output_dir=output_dir,
            )
            if self.verbose:
                print(f"🔥 Warmup ready for {engine_name}")
        except Exception as exc:
            if self.verbose:
                print(f"⚠️ Warmup skipped for {engine_name}: {exc}")
        finally:
            with contextlib.suppress(Exception):
                if warmup_path.exists():
                    warmup_path.unlink()

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

    def _save_conversion_checkpoint(
        self,
        chapter_num: int,
        output_dir: Path,
        config: ConversionConfig,
        *,
        success: bool = True,
    ) -> None:
        """Save a conversion checkpoint after every N successful chapters.

        The checkpoint records which chapter indices have been completed so that
        a subsequent run can skip them via _split_cached_chapters (MP3 detection)
        and print a resume notice to the user.
        """
        if not success:
            return
        self._checkpoint_done_set.add(chapter_num)
        count = len(self._checkpoint_done_set)
        if count % self._checkpoint_interval != 0 and count != self._checkpoint_total:
            return
        if not self._current_book_path:
            return
        try:
            self.cache_manager.save_checkpoint(
                book_path=self._current_book_path,
                book_title=getattr(config, "book_title", "") or "",
                output_dir=output_dir,
                temp_dir=self._setup_temp_directory(config),
                total_chapters=self._checkpoint_total,
                completed_chapters=sorted(self._checkpoint_done_set),
                current_chapter=chapter_num,
                conversion_config={
                    "engine": getattr(config, "engine", ""),
                    "voice": getattr(config, "voice", ""),
                },
            )
        except Exception:
            pass  # Checkpoint is best-effort; never break a conversion

    def _runtime_metrics_path(self, output_dir: Optional[Path] = None) -> Optional[Path]:
        target_dir = output_dir or self._last_output_dir
        if not target_dir:
            return None
        try:
            target_dir = Path(target_dir)
            target_dir.mkdir(parents=True, exist_ok=True)
            return target_dir / "_runtime_metrics.jsonl"
        except Exception:
            return None

    def _append_runtime_metric(
        self, payload: Dict[str, Any], output_dir: Optional[Path] = None
    ) -> None:
        path = self._runtime_metrics_path(output_dir)
        if path is None:
            return
        event = dict(payload or {})
        event.setdefault("ts", time.time())
        try:
            self._rotate_runtime_metrics_if_needed(path)
            with path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(event, ensure_ascii=False) + "\n")
        except Exception:
            if self.verbose:
                print("⚠️ Failed to persist runtime metric")

    def _segment_metrics_path(self, output_dir: Optional[Path] = None) -> Optional[Path]:
        target_dir = output_dir or self._last_output_dir
        if not target_dir:
            return None
        try:
            base = Path(target_dir)
            base.mkdir(parents=True, exist_ok=True)
            return base / "_segment_metrics.jsonl"
        except Exception:
            return None

    def _append_segment_metric(
        self, payload: Dict[str, Any], output_dir: Optional[Path] = None
    ) -> None:
        path = self._segment_metrics_path(output_dir)
        if path is None:
            return
        event = dict(payload or {})
        event.setdefault("ts", time.time())
        try:
            self._rotate_runtime_metrics_if_needed(path, max_bytes=4_000_000)
            with path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(event, ensure_ascii=False) + "\n")
        except Exception:
            if self.verbose:
                print("⚠️ Failed to persist segment metric")

    def _eta_baseline_key_for_config(self, config: Optional[ConversionConfig]) -> str:
        cfg = config or self._active_config
        engine = str(getattr(cfg, "engine", "unknown") or "unknown").lower()
        book = str(getattr(cfg, "book_title", "") or "unknown").strip().lower()
        key = self._runtime_tuning_key(cfg, str(getattr(cfg, "engine", "unknown") or "unknown"))
        machine = str(key.get("machine_signature", "generic") or "generic")
        return f"{machine}|{engine}|{book}"

    def _load_eta_baseline(self, config: Optional[ConversionConfig]) -> float:
        key = self._eta_baseline_key_for_config(config)
        self._eta_baseline_key = key
        path = self._eta_baseline_path
        if not path.exists():
            return 0.0
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return 0.0
        if not isinstance(payload, dict):
            return 0.0
        row = payload.get(key)
        if not isinstance(row, dict):
            return 0.0
        try:
            return max(0.0, float(row.get("chars_per_second", 0.0) or 0.0))
        except Exception:
            return 0.0

    def _save_eta_baseline(
        self, config: Optional[ConversionConfig], chars_per_second: float
    ) -> None:
        cps = max(0.0, float(chars_per_second or 0.0))
        if cps <= 1.0:
            return
        key = self._eta_baseline_key or self._eta_baseline_key_for_config(config)
        path = self._eta_baseline_path
        path.parent.mkdir(parents=True, exist_ok=True)
        payload: Dict[str, Any] = {}
        if path.exists():
            with contextlib.suppress(Exception):
                loaded = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    payload.update(loaded)
        prev = payload.get(key) if isinstance(payload.get(key), dict) else {}
        prev_cps = float((prev or {}).get("chars_per_second", 0.0) or 0.0)
        blended = cps if prev_cps <= 0 else ((prev_cps * 0.65) + (cps * 0.35))
        payload[key] = {
            "chars_per_second": round(float(blended), 3),
            "updated_at": time.time(),
            "samples": int(float((prev or {}).get("samples", 0) or 0) + 1),
        }
        with contextlib.suppress(Exception):
            path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    def _apply_startup_guardrail(self, config: Optional[ConversionConfig]) -> None:
        """Reduce aggressive settings when previous run regressed versus baseline."""
        if self._startup_guardrail_applied or not config:
            return
        if not _env_bool("STARTUP_GUARDRAIL_ENABLED", True):
            self._startup_guardrail_applied = True
            return
        threshold = max(5.0, _env_float("STARTUP_GUARDRAIL_DROP_PCT", 20.0))
        key = self._eta_baseline_key_for_config(config)
        path = self._startup_guardrail_path
        payload: Dict[str, Any] = {}
        if path.exists():
            with contextlib.suppress(Exception):
                loaded = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    payload.update(loaded)
        row = payload.get(key) if isinstance(payload.get(key), dict) else {}
        baseline = float((row or {}).get("baseline_cps", 0.0) or 0.0)
        last = float((row or {}).get("last_cps", 0.0) or 0.0)
        self._startup_guardrail_applied = True
        if baseline <= 1.0 or last <= 1.0:
            return
        if last >= baseline * (1.0 - (threshold / 100.0)):
            return

        engine = (config.engine or "").lower()
        if engine == "piper":
            workers = max(
                1, int(getattr(config, "piper_max_procs", 0) or os.getenv("PIPER_MAX_PROCS", "2"))
            )
            chunk = max(
                1800,
                int(
                    getattr(config, "piper_chunk_chars", 0)
                    or os.getenv("PIPER_CHUNK_CHARS", "3000")
                ),
            )
            config.piper_max_procs = max(1, workers - 1)
            config.piper_chunk_chars = max(1800, chunk - 300)
            os.environ["PIPER_MAX_PROCS"] = str(config.piper_max_procs)
            os.environ["PIPER_CHUNK_CHARS"] = str(config.piper_chunk_chars)
        elif engine == "edge":
            config.edge_enable_parallel = False
            config.edge_chunk_chars = max(
                4000, int((getattr(config, "edge_chunk_chars", 12000) or 12000) * 0.8)
            )
            os.environ["EDGE_CHUNK_CHARS"] = str(config.edge_chunk_chars)
        if getattr(config, "extra", None) is None:
            config.extra = {}
        config.extra["startup_guardrail"] = "1"
        self._append_runtime_metric(
            {
                "event": "startup_guardrail_applied",
                "baseline_cps": round(baseline, 3),
                "last_cps": round(last, 3),
                "threshold_pct": threshold,
                "engine": engine,
            },
            output_dir=self._last_output_dir,
        )

    def _update_startup_guardrail(
        self, config: Optional[ConversionConfig], chapter_cps: float
    ) -> None:
        cps = max(0.0, float(chapter_cps or 0.0))
        if cps <= 1.0:
            return
        key = self._eta_baseline_key_for_config(config)
        path = self._startup_guardrail_path
        path.parent.mkdir(parents=True, exist_ok=True)
        payload: Dict[str, Any] = {}
        if path.exists():
            with contextlib.suppress(Exception):
                loaded = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    payload.update(loaded)
        row = payload.get(key) if isinstance(payload.get(key), dict) else {}
        prev_baseline = float((row or {}).get("baseline_cps", 0.0) or 0.0)
        baseline = cps if prev_baseline <= 0 else max(prev_baseline * 0.99, cps)
        payload[key] = {
            "baseline_cps": round(baseline, 3),
            "last_cps": round(cps, 3),
            "updated_at": time.time(),
            "samples": int(float((row or {}).get("samples", 0) or 0) + 1),
        }
        with contextlib.suppress(Exception):
            path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    async def _maybe_run_piper_canary(
        self,
        *,
        tts_engine: object,
        config: Optional[ConversionConfig],
        chapter_text: str,
        output_dir: Path,
        chapter_index: int,
    ) -> None:
        """Probe two Piper profiles on a short sample and lock the best one."""
        if self._canary_profile_done:
            return
        if not _env_bool("STARTUP_CANARY_ENABLED", True):
            self._canary_profile_done = True
            return
        if not config or (config.engine or "").lower() != "piper":
            self._canary_profile_done = True
            return
        text = str(chapter_text or "").strip()
        if len(text) < 800:
            self._canary_profile_done = True
            return

        sample = text[: min(len(text), _env_int("STARTUP_CANARY_SAMPLE_CHARS", 1400))]
        base_workers = max(
            1,
            int(getattr(config, "piper_max_procs", 0) or os.getenv("PIPER_MAX_PROCS", "2") or "2"),
        )
        base_chunk = max(
            1800,
            int(
                getattr(config, "piper_chunk_chars", 0)
                or os.getenv("PIPER_CHUNK_CHARS", "3000")
                or "3000"
            ),
        )
        candidates = [
            (base_workers, base_chunk),
            (min(8, base_workers + 1), max(1800, base_chunk - 300)),
        ]
        if candidates[1] == candidates[0]:
            candidates = [candidates[0]]

        results: List[tuple[int, int, float]] = []
        for idx, (workers, chunk_chars) in enumerate(candidates):
            probe_path = output_dir / f"_canary_{chapter_index}_{idx}.wav"
            with contextlib.suppress(Exception):
                probe_path.unlink(missing_ok=True)
            os.environ["PIPER_MAX_PROCS"] = str(workers)
            os.environ["PIPER_CHUNK_CHARS"] = str(chunk_chars)
            with contextlib.suppress(Exception):
                setattr(tts_engine, "_semaphore", asyncio.Semaphore(max(1, workers)))
            with contextlib.suppress(Exception):
                setattr(tts_engine, "_chunk_char_limit", int(chunk_chars))
            started = time.time()
            try:
                out = await tts_engine.synthesize_async(sample, probe_path)
            except Exception:
                out = None
            elapsed = max(0.001, time.time() - started)
            if out is not None and Path(out).exists():
                results.append((workers, chunk_chars, elapsed))
            with contextlib.suppress(Exception):
                probe_path.unlink(missing_ok=True)

        if not results:
            self._canary_profile_done = True
            return
        best_workers, best_chunk, best_elapsed = min(results, key=lambda item: item[2])
        config.piper_max_procs = int(best_workers)
        config.piper_chunk_chars = int(best_chunk)
        os.environ["PIPER_MAX_PROCS"] = str(best_workers)
        os.environ["PIPER_CHUNK_CHARS"] = str(best_chunk)
        with contextlib.suppress(Exception):
            setattr(tts_engine, "_semaphore", asyncio.Semaphore(max(1, int(best_workers))))
        with contextlib.suppress(Exception):
            setattr(tts_engine, "_chunk_char_limit", int(best_chunk))
        self._canary_profile_done = True
        self._append_runtime_metric(
            {
                "event": "startup_canary_selected",
                "chapter": chapter_index,
                "workers": int(best_workers),
                "chunk_chars": int(best_chunk),
                "elapsed_s": round(float(best_elapsed), 4),
                "candidates": len(results),
            },
            output_dir=output_dir,
        )
        if self.verbose:
            print(
                "🧪 Startup canary selected Piper profile: "
                f"workers={best_workers}, chunk={best_chunk} "
                f"(sample {best_elapsed:.2f}s)"
            )

    def _apply_detected_runtime_defaults(
        self,
        config: ConversionConfig,
        *,
        network_tier: str,
        auto_engine_pool: Optional[Dict[str, tuple[ConversionConfig, object]]] = None,
    ) -> None:
        """Apply HW/network driven defaults and propagate to runtime engine configs."""
        profile = self.hardware_profile
        cpu_physical = max(1, int(getattr(profile, "cpu_physical", 2) or 2))
        ram_total = float(getattr(profile, "ram_total_gb", 0.0) or 0.0)
        tier = (network_tier or "fast").strip().lower()

        targets: List[ConversionConfig] = [config]
        if auto_engine_pool:
            for pooled_config, _ in auto_engine_pool.values():
                if pooled_config is not None and pooled_config not in targets:
                    targets.append(pooled_config)

        for cfg in targets:
            engine_name = (cfg.engine or "").lower()
            if engine_name == "piper":
                if getattr(cfg, "piper_max_procs", None) is None:
                    piper_cap = max(1, min(4, cpu_physical))
                    if ram_total < 8:
                        piper_cap = min(piper_cap, 2)
                    if tier in {"slow", "medium"}:
                        piper_cap = max(1, min(piper_cap, max(1, cpu_physical // 2)))
                    cfg.piper_max_procs = piper_cap
                os.environ.setdefault("PIPER_MAX_PROCS", str(max(1, int(cfg.piper_max_procs or 1))))
                os.environ.setdefault(
                    "PIPER_CHUNK_CHARS",
                    str(2600 if ram_total < 8 else 3200),
                )
            elif engine_name == "coqui":
                if getattr(cfg, "coqui_max_workers", None) is None:
                    workers = 1 if ram_total < 8 else min(4, max(1, cpu_physical // 2))
                    cfg.coqui_max_workers = workers
                if getattr(cfg, "coqui_chunk_chars", None) is None:
                    cfg.coqui_chunk_chars = 1200 if ram_total < 8 else 1800
                os.environ.setdefault(
                    "COQUI_MAX_WORKERS", str(max(1, int(cfg.coqui_max_workers or 1)))
                )
                os.environ.setdefault(
                    "COQUI_CHUNK_CHARS", str(max(800, int(cfg.coqui_chunk_chars or 1200)))
                )

        if auto_engine_pool:
            for name, (pooled_config, engine_obj) in auto_engine_pool.items():
                engine_name = (name or "").lower()
                if engine_name == "piper" and engine_obj is not None:
                    target = max(1, int(getattr(pooled_config, "piper_max_procs", 1) or 1))
                    with contextlib.suppress(Exception):
                        setattr(engine_obj, "_semaphore", asyncio.Semaphore(target))
                if engine_name == "coqui" and engine_obj is not None:
                    chunk_limit = int(getattr(pooled_config, "coqui_chunk_chars", 0) or 0)
                    if chunk_limit > 0:
                        with contextlib.suppress(Exception):
                            setattr(engine_obj, "_chunk_char_limit", chunk_limit)

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
                detected[label] = "File missing after initial attempt"
                continue
            try:
                size = output_path.stat().st_size
            except OSError:
                size = 0
            if size <= 1000:
                detected[label] = f"Invalid file ({size} bytes)"
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

        # Clean up legacy duplicate files: old code wrote "N - X.Y.Z - name-parsed.txt"
        # variants alongside the canonical "X.Y.Z - name-parsed.txt" files.
        # Use regex to reliably detect the integer-prefix pattern regardless of
        # how many " - " separators the chapter name itself contains.
        _int_prefix_re = re.compile(r"^\d+ - \d+(\.\d+)* - ")
        if text_dir.exists():
            duplicates_removed = 0
            for txt_file in sorted(text_dir.glob("*.txt")):
                if _int_prefix_re.match(txt_file.name):
                    txt_file.unlink(missing_ok=True)
                    duplicates_removed += 1
            if duplicates_removed > 0 and not self.verbose:
                print(f"  🧹 Removed {duplicates_removed} legacy duplicate file(s)")

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
            # When speech_text was set by _prepare_speech_text at parse time it already has:
            #   (a) [[fmt:]] markers converted to audible cues
            #   (b) apply_structural_speech_cues "..." pauses after headings
            # Re-calling to_audible_text with the original formatting_segments would
            # reconstruct text from the raw HTML-derived segments, discarding (b).
            # Fix: process only from speech_text itself, without passing segments.
            raw_speech = getattr(chapter_obj, "speech_text", None)
            if raw_speech is not None:
                if formatter and "[[fmt" in raw_speech:
                    # Rare: speech_text still has unresolved markers — convert without
                    # segments so we work from the text (which may already have cues).
                    pre_tts_text_local = formatter.to_audible_text(raw_speech, None)
                elif formatter:
                    pre_tts_text_local = formatter.strip_inline_markdown(raw_speech)
                else:
                    pre_tts_text_local = raw_speech
            else:
                # Fallback: no pre-processed speech_text — run the full formatting pipeline
                # using the original HTML-derived segments (no structural cues to preserve).
                speech_text_local = chapter_obj.text or ""
                if formatter:
                    formatting_segments_local = getattr(chapter_obj, "formatting_segments", None)
                    if formatting_segments_local or "[[fmt" in speech_text_local:
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
                                f"⚠️ Timeout ao processar chapter {chapter_label} - attempt {retry_count}/{max_retries}"
                            )
                            future = executor.submit(_prepare_payload, chapter_label, chapter)
                        else:
                            print(f"❌ Chapter {chapter_label} failed after {max_retries} attempts")
                            raise Exception(
                                f"Chapter {chapter_label} cannot be processed after {max_retries} attempts"
                            )

                if result_data is None:
                    raise Exception(f"Chapter {chapter_label} retornou dados nulos")

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
                    force = getattr(config, "force_reprocess", False) or getattr(
                        config, "clear_cache", False
                    )
                    if parsed_path.exists() and pre_tts_path.exists() and not force:
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
                                    f"🔄 Regerando text do chapter {chapter_label} "
                                    f"(attempt {retry_idx + 1}/{max_text_retries})"
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
                            f"Post-parsing validation failed after retry ({chapter_label})"
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

    def _analyze_chapter_stats(self, chapters: List[Chapter]) -> Dict[str, float]:
        """Return summary statistics used to pick the fastest engine for the book."""
        stats: Dict[str, float] = {
            "count": len(chapters),
            "max_chars": 0,
            "avg_chars": 0,
            "long_ratio": 0.0,
            "total_chars": 0,
            "prefer_offline_engine": False,
        }
        if not chapters:
            return stats

        lengths: List[int] = [max(0, self._estimate_chapter_chars(chapter)) for chapter in chapters]
        total = sum(lengths)
        stats["total_chars"] = total
        stats["max_chars"] = max(lengths) if lengths else 0
        stats["avg_chars"] = total / len(lengths)
        long_threshold = EDGE_OFFLINE_LONG_CHARS
        long_count = sum(1 for value in lengths if value >= long_threshold)
        stats["long_ratio"] = long_count / len(lengths)

        # Detect outlier chapters: chapters that are >5× the median size.
        # These are typically footnote-container files that embed the entire book text.
        sorted_lengths = sorted(lengths)
        median_chars = sorted_lengths[len(sorted_lengths) // 2] if sorted_lengths else 0
        outlier_threshold = max(median_chars * 5, 50_000)
        outlier_indices = [i for i, v in enumerate(lengths) if v > outlier_threshold and v > 50_000]
        stats["median_chars"] = float(median_chars)
        stats["outlier_indices"] = outlier_indices  # type: ignore[assignment]
        if outlier_indices:
            outlier_max = max(lengths[i] for i in outlier_indices)
            stats["outlier_max_chars"] = float(outlier_max)
            # Warn the user so they know they can skip this chapter.
            for idx in outlier_indices:
                ch = chapters[idx]
                ch_chars = lengths[idx]
                ratio = ch_chars // max(median_chars, 1)
                (ch_chars // 1000) * 1000  # round down to nearest 1K
                print(
                    f'\n⚠️  Oversized chapter: "{getattr(ch, "name", "?")[:70]}"'
                    f" ({ch_chars:,} chars = {ratio}× median)"
                    f" — conversion will take longer for this chapter"
                )

        prefer_offline = False
        reasons: List[str] = []
        if stats["max_chars"] >= EDGE_OFFLINE_LONG_CHARS:
            prefer_offline = True
            reasons.append(f"chapter with ~{stats['max_chars']:,} chars")
        if stats["long_ratio"] >= EDGE_OFFLINE_LONG_RATIO:
            prefer_offline = True
            reasons.append(f"{int(stats['long_ratio'] * 100)}% of chapters are too long")
        if stats["total_chars"] >= EDGE_OFFLINE_TOTAL_CHARS:
            prefer_offline = True
            reasons.append(f"{stats['total_chars']:,} total chars")
        stats["prefer_offline_engine"] = prefer_offline
        if prefer_offline and reasons:
            stats["offline_reason"] = "; ".join(reasons)
            stats["prefer_piper_engine"] = True
        return stats

    def _apply_chapter_engine_preferences(
        self, config: ConversionConfig, stats: Dict[str, float]
    ) -> None:
        """Report chapter stats without forcing pre-emptive engine switches."""
        if not stats or not stats.get("prefer_offline_engine"):
            return
        reason = stats.get("offline_reason")
        if reason:
            print(f"🎯 Long chapters detected ({reason}) — keeping Edge as first attempt.")
        # Product decision: do not switch to offline engines preemptively.
        # Offline engines must be used only after real Edge failures/timeouts.

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

    @staticmethod
    def _chapter_selector_aliases(value: object) -> Set[str]:
        """Build equivalent selector forms (e.g. 5, 5.0, 005) for resilient matching."""
        text = str(value).strip() if value is not None else ""
        if not text:
            return set()

        aliases: Set[str] = {text}
        numeric_text = text.replace(",", ".")

        try:
            num = float(numeric_text)
            if num.is_integer():
                base = str(int(num))
                aliases.add(base)
                aliases.add(f"{base}.0")
            else:
                aliases.add(str(num))
        except Exception:
            pass

        if re.fullmatch(r"\d+", text):
            base = str(int(text))
            aliases.add(base)
            aliases.add(f"{base}.0")

        return {item for item in aliases if item}

    @staticmethod
    def _effective_primary_language(
        config: Optional[ConversionConfig], default: str = "pt-BR"
    ) -> str:
        if config:
            raw_primary = str(getattr(config, "primary_language", "") or "").strip()
            if raw_primary and raw_primary.lower() not in {"auto", "unknown"}:
                return raw_primary
            languages = list(getattr(config, "languages", []) or [])
            for lang in languages:
                candidate = str(lang or "").strip()
                if candidate and candidate.lower() not in {"auto", "unknown"}:
                    return candidate
        return default

    @staticmethod
    def _normalize_title_for_match(raw: str) -> str:
        text = str(raw or "")
        text = text.replace("–", "-").replace("—", "-")
        text = unicodedata.normalize("NFD", text)
        text = "".join(ch for ch in text if unicodedata.category(ch) != "Mn")
        text = re.sub(r"\s+", " ", text.lower())
        return text.strip()

    def _find_quick_synth_text_file(
        self,
        *,
        chapter_num: str,
        text_dirs: List[Path],
        issue_heading: Optional[str] = None,
    ) -> tuple[Optional[Path], bool, Dict[Path, List[Path]]]:
        chapter_aliases = self._chapter_selector_aliases(chapter_num)
        chapter_aliases.add(str(chapter_num).strip())

        def _matches_chapter_alias(path_obj: Path) -> bool:
            name = path_obj.name
            for alias in chapter_aliases:
                alias = str(alias).strip()
                if not alias:
                    continue
                if f" - {alias} -" in name:
                    return True
                if name.startswith(f"{alias} -") or name.startswith(f"{alias}."):
                    return True
            return False

        available_pre_tts: Dict[Path, List[Path]] = {}
        available_parsed: Dict[Path, List[Path]] = {}
        for text_dir in text_dirs:
            pre_tts_files = sorted(text_dir.glob("*-pre-tts.txt"))
            parsed_files = sorted(text_dir.glob("*-parsed.txt"))
            available_pre_tts[text_dir] = pre_tts_files
            available_parsed[text_dir] = parsed_files
            target = next((f for f in pre_tts_files if _matches_chapter_alias(f)), None)
            if target:
                return target, False, available_pre_tts
            target = next((f for f in parsed_files if _matches_chapter_alias(f)), None)
            if target:
                return target, True, available_pre_tts

        # Fallback: fuzzy match by chapter heading when legacy cache uses sequential prefixes.
        wanted_title = self._normalize_title_for_match(issue_heading or "")
        if wanted_title:
            scored: List[tuple[float, Path, bool]] = []
            for text_dir, files in available_pre_tts.items():
                for candidate in files:
                    stem = candidate.stem.replace("-pre-tts", "")
                    stem_norm = self._normalize_title_for_match(re.sub(r"^\s*\d+\s*-\s*", "", stem))
                    ratio = difflib.SequenceMatcher(None, wanted_title, stem_norm).ratio()
                    scored.append((ratio, candidate, False))
                for candidate in available_parsed.get(text_dir, []):
                    stem = candidate.stem.replace("-parsed", "")
                    stem_norm = self._normalize_title_for_match(re.sub(r"^\s*\d+\s*-\s*", "", stem))
                    ratio = difflib.SequenceMatcher(None, wanted_title, stem_norm).ratio()
                    scored.append((ratio, candidate, True))
            if scored:
                best_ratio, best_path, using_parsed = max(scored, key=lambda row: row[0])
                if best_ratio >= 0.45:
                    return best_path, using_parsed, available_pre_tts

        return None, False, available_pre_tts

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
        Skip obvious credits/ads or very short chapters when there is no cached audio.
        Never removes chapters that already have a cached MP3.
        """
        patterns = [
            "créditos",
            "agradecimentos",
            "folha de rosto",
            "sumário",
            "indice",
            "capas",
        ]
        min_chars = int(os.getenv("AUTO_SKIP_MIN_CHARS", "400").strip() or "400")
        # Default disabled to not skip chapters in test/default conversion scenarios
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

    async def convert(self, reader: EbookReader, config: ConversionConfig) -> ConversionResult:
        """Convert all chapters in ``reader`` according to ``config``."""

        # Enable verbose mode if requested
        self.verbose = getattr(config, "verbose", False)
        self._active_config = config
        self._final_validation_passed = True
        self._startup_guardrail_applied = False
        self._canary_profile_done = False
        self._eta_recent_cps = []
        # Show TTS output only in verbose mode
        self.show_tts_output = self.verbose
        if not getattr(config, "log_callback", None):
            # Roteia logs internos para a barra de progresso/CLI automaticamente
            def _log_to_progress(message: str) -> None:
                self.progress.tick(message)
                if not self.progress._supports_overwrite:
                    print(message)

            config.log_callback = _log_to_progress

        # Initialize auto-tuning (detecta HW e network, configura flags automaticamente)
        await self._initialize_auto_tuning()

        # Initialize adaptive performance controller
        self._initialize_adaptive_performance()

        # Optimize memory and threading settings
        self._optimize_memory_settings()

        if self.verbose:
            print("[DEBUG] AudioConverter.convert() started")
            print(f"[DEBUG] Config: engine={getattr(config, 'engine', 'unknown')}, mode=sequential")

        # Setup paths
        reader_path = getattr(reader, "file_path", None)
        try:
            self._current_book_path = Path(reader_path) if reader_path else None
        except TypeError:
            self._current_book_path = None

        output_dir = self._setup_output_directory(config)
        self._last_output_dir = output_dir

        # Honor --clear-cache: skip reading pre-existing cache and overwrite outputs.
        # Text files are overwritten via cleanup_existing=True in _generate_all_text_files.
        # Cached MP3s are ignored via ignore_cached_audio in _split_cached_chapters.
        # In-memory and on-disk chapter cache is bypassed via get_cached_chapters(bypass=True).
        # Best-effort deletion of stale artifacts (non-fatal if it fails).
        if getattr(config, "clear_cache", False):
            if self.verbose:
                print("--clear-cache: bypassing pre-existing cache, outputs will be overwritten")
            try:
                if self._current_book_path:
                    self.cache_manager.clear_cache(self._current_book_path, title=reader.title)
                elif reader.title:
                    self.cache_manager.clear_cache(title=reader.title)
            except Exception as exc:
                if self.verbose:
                    print(f"Warning: could not remove cache directory: {exc}")
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
        self._apply_runtime_feature_overrides(config)
        self._apply_startup_guardrail(config)
        self._load_adaptive_state_checkpoint(temp_dir)
        chapters = list(
            reader.get_chapter_structure(preserve_all=config.preserve_all_chapters) or []
        )
        # Store original before deduplication for potential restoration
        original_chapters = chapters.copy()

        chapters, duplicates_removed = deduplicate_chapters_by_content(chapters)
        if duplicates_removed:
            print(f"  🧹 Removed {duplicates_removed} duplicate chapter(s) automatically")

        chapter_stats = self._analyze_chapter_stats(chapters)
        self._chapter_stats = chapter_stats
        self._apply_chapter_engine_preferences(config, chapter_stats)

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
        resume_from_failure = True
        if getattr(config, "extra", None):
            resume_raw = config.extra.get("resume_from_failure")
            if resume_raw is not None:
                resume_from_failure = str(resume_raw).lower() in {"1", "true", "yes", "on"}
        if resume_from_failure:
            checkpoint = self._load_failure_checkpoint(temp_dir)
            failed_labels = (
                checkpoint.get("failed_chapters", []) if isinstance(checkpoint, dict) else []
            )
            if isinstance(failed_labels, list) and failed_labels:
                failed_set = {str(item).strip() for item in failed_labels if str(item).strip()}
                resumed_chapters: List[Chapter] = []
                for idx, chapter in enumerate(chapters, start=1):
                    chapter_num = self._chapter_number(chapter, idx)
                    chapter_label = self._chapter_display_name(chapter, chapter_num)
                    chapter_name = str(getattr(chapter, "name", "") or "").strip()
                    if (
                        str(chapter_num) in failed_set
                        or chapter_label in failed_set
                        or chapter_name in failed_set
                    ):
                        resumed_chapters.append(chapter)
                if resumed_chapters and len(resumed_chapters) < len(chapters):
                    print(
                        f"🔁 Resume-from-failure: retrying only {len(resumed_chapters)}/{len(chapters)} failed chapter(s)"
                    )
                    chapters = resumed_chapters
            if isinstance(checkpoint, dict):
                blocked = checkpoint.get("edge_blocked_chapters", [])
                if blocked:
                    if getattr(config, "extra", None) is None:
                        config.extra = {}
                    config.extra["edge_blocked_chapters"] = list(blocked)

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
        initial_cleanup = bool(
            getattr(config, "force_reprocess", False) or getattr(config, "clear_cache", False)
        )
        self._generate_all_text_files(
            chapters_for_text,
            temp_dir,
            config,
            cleanup_existing=initial_cleanup,
            text_validator=text_validator if getattr(config, "validate_text", True) else None,
        )
        if self._text_validation_errors and self.verbose:
            print(
                f"⚠️ Post-parsing validation: {len(self._text_validation_errors)} problem(s) detected"
            )

        # Validate all chapters against cache
        integrity_report = text_validator.validate_all_chapters(
            chapters_for_text, show_progress=True
        )

        # Hard-stop if chapters are empty or duplicated to avoid bad audio/output naming
        hard_block_errors = [
            v
            for v in integrity_report.chapters_with_issues
            if v.message and ("Chapter text empty" in v.message or "Duplicate content" in v.message)
        ]
        if hard_block_errors:
            print("\n❌ Text validation failed: empty or duplicate chapters detected.")
            for v in hard_block_errors:
                print(f"   - Chapter {v.chapter_index}: {v.chapter_title} → {v.message}")
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
                self._apply_runtime_feature_overrides(config)
                self._load_adaptive_state_checkpoint(temp_dir)
                text_validator = TextIntegrityValidator(cache_dir=temp_dir, verbose=self.verbose)

                self._generate_all_text_files(
                    chapters_for_text,
                    temp_dir,
                    config,
                    cleanup_existing=True,
                    text_validator=text_validator
                    if getattr(config, "validate_text", True)
                    else None,
                )

                print("✅ Cache cleaned! Proceeding with full conversion.\n")
            except Exception as exc:
                print(f"❌ Failure clearing cache: {exc}")
                print("⚠️  Continuando com conversion mas pode haver problems.\n")

        # Save parsed text for all chapters (creates baseline for validation)
        text_validator.save_all_chapters_text(chapters_for_text, show_progress=not self.verbose)

        if getattr(config, "priority_selectors", None):
            chapters = self._prioritize_chapters(chapters, config.priority_selectors)
        total_chapters = len(chapters)
        # Init checkpoint tracking for this conversion run
        self._checkpoint_done_set = set()
        self._checkpoint_total = total_chapters
        if self._current_book_path:
            _ckpt = self.cache_manager.load_checkpoint(self._current_book_path)
            if _ckpt and _ckpt.completed_chapters:
                self._checkpoint_done_set = set(_ckpt.completed_chapters)
                print(
                    f"♻️  Checkpoint: {len(self._checkpoint_done_set)}/{_ckpt.total_chapters}"
                    " chapters previously completed (skipping via cache detection)"
                )
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
                print("🛡️ Edge automatic stable mode: slow network detected")
        if edge_stable_mode and (config.engine or "").lower() == "edge":
            config.edge_enable_parallel = False
            config.edge_auto_tune = False
            config.edge_chunk_chars = 4000
            config.edge_max_segment_seconds = 120
            print("🛡️ Edge stable mode: reduced parallelism and extended timeouts")
        # Auto-parallel: prefer env override, else derive from hardware profile
        # Aggressive defaults: use all available CPU cores for maximum throughput
        chapter_parallel_count = int(os.getenv("CHAPTER_PARALLEL_COUNT", "0") or "0")
        if chapter_parallel_count <= 0:
            cpu_logical = os.cpu_count() or 1
            cpu_physical = 0
            with contextlib.suppress(Exception):
                cpu_physical = psutil.cpu_count(logical=False) or 0
            ram_total = 0.0
            ram_available = 0.0
            network_tier = ""
            if self.hardware_profile is not None:
                ram_total = float(getattr(self.hardware_profile, "ram_total_gb", 0.0) or 0.0)
                ram_available = float(
                    getattr(self.hardware_profile, "ram_available_gb", 0.0) or 0.0
                )
                network_tier = str(
                    getattr(self.hardware_profile, "network_speed_estimate", "") or ""
                ).lower()
            if cpu_physical >= 8:
                chapter_parallel_count = min(8, cpu_logical)
            elif cpu_physical >= 4:
                chapter_parallel_count = min(6, cpu_logical)
            elif cpu_physical >= 2:
                chapter_parallel_count = min(4, cpu_logical)
            else:
                chapter_parallel_count = 2
            # Resource-aware conservative defaults for stability/throughput.
            if (ram_total and ram_total <= 8.5) or (ram_available and ram_available <= 2.5):
                chapter_parallel_count = min(chapter_parallel_count, 2)
            if network_tier in {"slow", "medium"}:
                chapter_parallel_count = min(chapter_parallel_count, 1)
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
        self._engine_warmup_done.clear()
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
            self._write_runtime_metrics_summary(temp_dir)
            self._write_runtime_metrics_csv(temp_dir)
            self._write_runtime_metrics_dashboard(temp_dir)
            self._write_segment_metrics_summary(temp_dir)
            self._write_segment_metrics_csv(temp_dir)
            self._write_segment_metrics_dashboard(temp_dir)
            self._write_runtime_recommendations(temp_dir)
            await self._report_results(result)
            return result

        is_auto_engine = (config.engine or "").lower() == "auto"
        auto_engine_pool: Dict[str, tuple[ConversionConfig, object]] = {}
        engine_seeds: Dict[str, object] = {}
        try:
            if is_auto_engine:
                auto_engine_pool = self._prepare_auto_engines(config)
                if not auto_engine_pool:
                    raise RuntimeError("No engine available in automatic mode")
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
                        raise RuntimeError("No engine available in automatic mode")
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
                print(f"[DEBUG] Engine configured: {type(sample_engine).__name__}")
            else:
                print("[DEBUG] Engine configured: AUTO")

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
        self._apply_detected_runtime_defaults(
            config,
            network_tier=edge_network_tier,
            auto_engine_pool=auto_engine_pool if is_auto_engine else None,
        )
        if is_auto_engine:
            for name, (pool_cfg, pool_engine_obj) in auto_engine_pool.items():
                self._apply_persisted_engine_params(
                    cfg=pool_cfg,
                    engine_label=name,
                    engine_obj=pool_engine_obj,
                )
        else:
            self._apply_persisted_engine_params(
                cfg=config,
                engine_label=(config.engine or "").lower(),
                engine_obj=engine_seeds.get((config.engine or "").lower()),
            )
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
        config_snapshots: Dict[int, Dict[str, object]] = {}
        for cfg in edge_configs:
            config_snapshots[id(cfg)] = {
                "chunk_chars": getattr(cfg, "edge_chunk_chars", None),
                "max_segment_seconds": getattr(cfg, "edge_max_segment_seconds", None),
                "enable_parallel": getattr(cfg, "edge_enable_parallel", True),
            }
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
            print("🌧️ Edge: unstable network detected → starting with conservative profile")
        self._edge_auto_state = {
            "enabled": edge_auto_enabled,
            "network_tier": edge_network_tier,
            "parallel_cap": parallel_slots_cap,
            "fast_parallel_cap": parallel_slots_cap or chapter_parallel_count,
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
            "fast_profiles": config_snapshots,
            "recovery_streak": 0,
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
                        reason="failures detectadas em chapters longos",
                    )
                    edge_rescue_applied = True
                elif not edge_rescue_aggressive:
                    rescue_profile = self._apply_edge_rescue_profile(
                        engine_pool=engine_pool,
                        edge_configs=edge_configs,
                        reason="persistent failures even after safe adjustments",
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
            retry_engine = (retry_config.engine or "").lower()
            force_offline_after_persistent_edge = (
                edge_rescue_applied
                and not forced_offline_once
                and retry_round >= 2
                and retry_engine == "edge"
            )
            if force_offline_after_persistent_edge:
                fallback_engine = self._resolve_offline_fallback_engine({"piper", "coqui"})
                if fallback_engine and engine_pool.has_engine(fallback_engine):
                    force_offline_engine = fallback_engine
            if force_offline_engine:
                forced_offline_once = True
                retry_config = replace(retry_config, engine=force_offline_engine, voice=None)
                print(
                    f"🛟 Edge unstable → forcing retry with {force_offline_engine.upper()} (offline)"
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
                print(f"⚠️ Returned failure without match: {unresolved}")
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
        # Priority: piper > coqui to avoid additional network stalls/timeouts.
        if pending_failures and is_auto_engine and auto_engine_pool:
            rescue_engine = None
            if "piper" in auto_engine_pool:
                rescue_engine = "piper"
            elif "coqui" in auto_engine_pool:
                rescue_engine = "coqui"
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
        converted_estimate = len(unique_outputs)
        if not pending_failures:
            converted_estimate = max(converted_estimate, total_chapters)
        else:
            converted_estimate = max(converted_estimate, total_chapters - len(pending_failures))
        result.converted_chapters = converted_estimate
        result.total_chapters = total_chapters

        if pending_failures:
            ordered_errors = []
            for name, message in pending_failures.items():
                entry = self._lookup_chapter_entry(chapter_lookup, name)
                idx = entry[1] if entry else total_chapters + 1
                ordered_errors.append((idx, name, message))
            ordered_errors.sort(key=lambda item: item[0])
            result.errors = [
                f"{name}: {message} (attempts: {attempts_used.get(name, 'n/d')})"
                if message
                else f"{name} (attempts: {attempts_used.get(name, 'n/d')})"
                for _, name, message in ordered_errors
            ]
        else:
            result.errors = []

        if unresolved_pool:
            for name, message in unresolved_pool.items():
                result.errors.append(f"{name}: {message} (not correlacionado)")

        result.success = not pending_failures and not unresolved_pool

        if result.success:
            self._clear_failure_checkpoint(temp_dir)
            # Clear conversion checkpoint — all chapters done, no need to resume
            if self._current_book_path:
                try:
                    self.cache_manager.clear_checkpoint(self._current_book_path)
                except Exception:
                    pass
        else:
            edge_blocked = []
            if getattr(config, "extra", None):
                edge_blocked = config.extra.get("edge_blocked_chapters", []) or []
            self._save_failure_checkpoint(
                temp_dir,
                failed_chapters=pending_failures.keys(),
                edge_blocked_chapters=edge_blocked,
            )

        # Move successfully converted files even on partial failure (for resume capability)
        if result.converted_chapters > 0:
            if self.verbose:
                print(f"[DEBUG] Moving {len(result.output_files)} files to final directory...")

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
        self._write_runtime_metrics_summary(temp_dir)
        self._write_runtime_metrics_csv(temp_dir)
        self._write_runtime_metrics_dashboard(temp_dir)
        self._write_segment_metrics_summary(temp_dir)
        self._write_segment_metrics_csv(temp_dir)
        self._write_segment_metrics_dashboard(temp_dir)
        self._write_runtime_recommendations(temp_dir)
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
                # Fallback to system temp directory
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
        """Convert multiple chapters in parallel for maximum throughput."""
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
            cleanup_existing = bool(
                getattr(config, "force_reprocess", False) or getattr(config, "clear_cache", False)
            )
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

        # Compute multi-engine slot affinity (default off; needs explicit opt-in).
        _me_requested = (
            bool((config.extra or {}).get("multi_engine_parallel")) and not is_auto_engine
        )
        cli_slot_affinity: list[str] = []
        if _me_requested and not is_auto_engine:
            _me_engines: list[str] = []
            if (config.engine or "").lower() not in {"", "auto"}:
                _me_engines.append((config.engine or "").lower())
            # Add local engines from auto_engine_pool if available
            for name in auto_engine_pool or {}:
                if name not in _me_engines:
                    _me_engines.append(name)
            # Dynamic edge fraction: proportional to relative telemetry speed.
            _tele = getattr(self, "telemetry", None)
            _tele_summary = _tele.summary() if _tele else {}
            _edge_spd = float((_tele_summary.get("edge") or {}).get("avg_chars_per_second") or 0.0)
            _local_spds = [
                float((_tele_summary.get(e) or {}).get("avg_chars_per_second") or 0.0)
                for e in _me_engines[1:]
            ]
            _best_local = max(_local_spds) if _local_spds else 0.0
            if _edge_spd > 0 and _best_local > 0:
                _edge_frac = _edge_spd / (_edge_spd + _best_local)
                _edge_frac = max(0.50, min(0.85, _edge_frac))
            else:
                _edge_frac = float(os.getenv("MULTI_ENGINE_EDGE_FRACTION", "0.67"))
            cli_slot_affinity = _build_multi_engine_slot_map(
                recommended,
                _me_engines,
                edge_fraction=_edge_frac,
            )
            if cli_slot_affinity:
                counts = {e: cli_slot_affinity.count(e) for e in dict.fromkeys(cli_slot_affinity)}
                print(
                    "⚡ Multi-engine parallel: " + ", ".join(f"{e}×{n}" for e, n in counts.items())
                )

        # Helper to create chapter task
        def create_chapter_task(
            chapter: Chapter, preferred_engine: Optional[str] = None
        ) -> asyncio.Task:
            task_config = config
            if preferred_engine and not is_auto_engine:
                from dataclasses import replace as _dc_replace

                task_config = _dc_replace(config, engine=preferred_engine)
            return asyncio.create_task(
                self._convert_chapters_sequential(
                    [chapter],
                    engine_pool,
                    output_dir,
                    task_config,
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
        slot_task_engine: dict[asyncio.Task, str] = {}

        for slot_idx in range(min(parallel_slots, total_chapters)):
            try:
                chapter = next(chapter_iter)
                pref = cli_slot_affinity[slot_idx] if slot_idx < len(cli_slot_affinity) else None
                task = create_chapter_task(chapter, preferred_engine=pref)
                pending_tasks[task] = chapter
                slot_task_engine[task] = pref or ""
            except StopIteration:
                break

        while pending_tasks:
            done, _ = await asyncio.wait(pending_tasks.keys(), return_when=asyncio.FIRST_COMPLETED)

            freed_slot_engines: list[str] = []
            for task in done:
                chapter = pending_tasks.pop(task)
                freed_slot_engines.append(slot_task_engine.pop(task, ""))
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

            # Refill freed slots, preserving engine affinity.
            for freed_engine in freed_slot_engines:
                if len(pending_tasks) >= parallel_slots:
                    break
                try:
                    chapter = next(chapter_iter)
                    pref = freed_engine if (freed_engine and cli_slot_affinity) else None
                    task = create_chapter_task(chapter, preferred_engine=pref)
                    pending_tasks[task] = chapter
                    slot_task_engine[task] = pref or ""
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
        """Convert chapters sequentially, without parallelism."""
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

        # Preflight: detect DNS issues, but do not bypass Edge entirely.
        # Product requirement: always attempt Edge at least once before offline fallback.
        if (config.engine or "").lower() == "edge":
            try:
                socket.getaddrinfo("speech.platform.bing.com", 443, proto=socket.IPPROTO_TCP)
            except Exception:
                if self.verbose:
                    print(
                        "🛟 Edge DNS unavailable in preflight; still trying Edge 1x before offline fallback"
                    )

        # Compat: accept a direct engine instead of a pool
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
            cleanup_existing = bool(
                getattr(config, "force_reprocess", False) or getattr(config, "clear_cache", False)
            )
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
            reason = self._classify_failure_reason(last_error)
            if reason == "throttle":
                return "rate_limit"
            if reason == "transient":
                return "timeout"
            return reason

        edge_unavailable_hits = 0
        auto_engine_pool = auto_engine_pool or {}
        unavailable_engines: Set[str] = set()
        edge_globally_blocked = False
        edge_blocked_chapters_global: Set[str] = set()
        if getattr(config, "extra", None):
            raw_blocked = config.extra.get("edge_blocked_chapters") or []
            if isinstance(raw_blocked, (list, tuple, set)):
                edge_blocked_chapters_global = {
                    str(item).strip() for item in raw_blocked if str(item).strip()
                }
            else:
                edge_blocked_chapters_global = {
                    part.strip() for part in str(raw_blocked).split(",") if part.strip()
                }
        edge_state = self._edge_auto_state or {}
        edge_auto_enabled = bool(edge_state.get("enabled"))
        edge_force_offline = bool(edge_state.get("force_offline_after_trunc"))
        edge_circuit = self._edge_circuit_state
        edge_circuit["open"] = False
        edge_circuit["failures"] = 0
        edge_circuit["opened_at"] = 0.0
        edge_circuit["last_reason"] = ""

        def _edge_circuit_open() -> bool:
            if not bool(edge_circuit.get("open")):
                return False
            opened_at = float(edge_circuit.get("opened_at") or 0.0)
            cooldown = float(edge_circuit.get("cooldown_seconds") or 900.0)
            if opened_at > 0 and (time.time() - opened_at) >= cooldown:
                edge_circuit["open"] = False
                edge_circuit["failures"] = 0
                edge_circuit["opened_at"] = 0.0
                edge_circuit["last_reason"] = ""
                if self.verbose:
                    print("✅ Edge circuit breaker reset after cooldown")
                return False
            return True

        def _trip_edge_circuit(reason: str) -> None:
            failures = int(edge_circuit.get("failures", 0) or 0) + 1
            edge_circuit["failures"] = failures
            edge_circuit["last_reason"] = reason
            threshold = int(edge_circuit.get("threshold", 2) or 2)
            if failures >= threshold:
                edge_circuit["open"] = True
                edge_circuit["opened_at"] = time.time()
                unavailable_engines.add("edge")
                if self.verbose:
                    print(f"🧯 Edge circuit breaker OPEN ({reason})")

        def _reset_edge_circuit() -> None:
            edge_circuit["open"] = False
            edge_circuit["failures"] = 0
            edge_circuit["opened_at"] = 0.0
            edge_circuit["last_reason"] = ""

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
                    print(f"   🛠️ Coqui safe mode ({reason}): chunks=1600, workers=1")
            except Exception:
                pass

        def available_auto_pool() -> Dict[str, tuple[ConversionConfig, object]]:
            if not auto_engine_pool:
                return {}
            circuit_open = _edge_circuit_open()
            return {
                name: entry
                for name, entry in auto_engine_pool.items()
                if name not in unavailable_engines and not (circuit_open and name == "edge")
            }

        def can_use_piper() -> bool:
            """Check if Piper is usable in this environment."""
            if not _has_piper_support():
                return False
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
                        print("   ⚠️ Edge pre-check failed; keeping selected engine")
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
                Handle Edge outages without mudar de engine (mode manual).
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
                    print(f"   ⚠️ Edge unavailable ({context}) - error: {last_error}")
                nonlocal edge_unavailable_hits
                edge_unavailable_hits += 1
                if edge_unavailable_hits >= EDGE_MONOLINGUAL_THRESHOLD:
                    raise RuntimeError("edge_unavailable_threshold")
                _maybe_apply_edge_slow_mode(f"Edge unavailable ({reason})", engine_obj=engine_obj)

                max_wait = min(seconds, 25)
                if self.verbose:
                    print(
                        f"   ⏳ No fallback available; waiting {max_wait}s antes de tentar novamente..."
                    )
                waited = 0
                while waited < max_wait:
                    chunk = min(3, max_wait - waited)
                    await asyncio.sleep(chunk)
                    waited += chunk
                    self.progress.tick(f"⏳ Edge unavailable - waiting {max_wait - waited}s...")
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
                    print(f"\n🔄 Edge-TTS com {edge_consecutive_failures} failures consecutive")
                    print(f"   🔀 Mudando para Edge monolingual: {config.primary_language}")
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
                if not _has_kokoro_support(config.primary_language):
                    if self.verbose:
                        print("   ⚠️ Kokoro has no voice for this language; skipping fallback")
                    edge_switched_to_kokoro = True
                else:
                    try:
                        from .tts.kokoro_engine import KokoroTTSEngine

                        KokoroTTSEngine()  # test availability
                        print(
                            f"\n🔄 Edge monolingual com {edge_consecutive_failures} failures consecutive"
                        )
                        print("   🔀 Switching to Kokoro (local, fast)")
                        config = replace(config, engine="kokoro")
                        engine_pool.register_engine("kokoro", config)
                        edge_switched_to_kokoro = True
                        edge_consecutive_failures = 0
                        return
                    except Exception as e:
                        if self.verbose:
                            print(f"   ⚠️ Kokoro unavailable: {e}")
                        edge_switched_to_kokoro = True  # skip to piper

            # TIER 4: Piper after PIPER_THRESHOLD failures (from Kokoro or Edge)
            if (
                not edge_switched_to_piper
                and edge_consecutive_failures >= EDGE_PIPER_THRESHOLD
                and (edge_switched_to_kokoro or edge_switched_to_monolingual)
            ):
                if can_use_piper():
                    piper_language = self._effective_primary_language(config)
                    current_label = "Kokoro" if current_engine == "kokoro" else "Edge"
                    print(
                        f"\n🔄 {current_label} com {edge_consecutive_failures} failures consecutive"
                    )
                    print(f"   🛟 Mudando para Piper (offline) com language: {piper_language}")
                    from .config import VoiceConfigProvider

                    voice_provider = VoiceConfigProvider()
                    piper_model = voice_provider.get_voice("piper", piper_language)
                    if piper_model:
                        config = replace(
                            config,
                            engine="piper",
                            primary_language=piper_language,
                            model_path=Path(piper_model) if piper_model else None,
                        )
                        engine_pool.register_engine("piper", config)
                        try:
                            _, piper_engine = await engine_pool.acquire("piper")
                            if piper_engine:
                                print(
                                    f"   ✅ Piper loaded: {Path(piper_model).name if piper_model else 'modelo default'}"
                                )
                                engine_pool.release("piper", piper_engine)
                                edge_switched_to_piper = True
                                edge_consecutive_failures = 0
                            else:
                                print("   ⚠️ Piper engine could not be loaded")
                        except Exception as e:
                            print(f"   ⚠️ Error loading Piper: {e}")
                    else:
                        print("   ⚠️ Piper model not found for this language")
                else:
                    print(f"\n⚠️ {edge_consecutive_failures} failures consecutive")
                    print("   ⚠️ Piper not installed - fallback is not possible")

        # Four-tier fallback: Edge multilingual → Edge monolingual → Kokoro → Piper
        edge_failure_count = 0
        edge_consecutive_failures = 0
        base_delay = 0.5  # Start with 0.5s delay
        max_delay = 30.0  # Cap at 30s
        edge_switched_to_monolingual = False
        edge_switched_to_kokoro = False
        edge_switched_to_piper = False
        config.voice if (config.engine or "").lower() == "edge" else None
        stage_pipeline_enabled = self._is_stage_pipeline_enabled(config)
        stage_pipeline_depth = self._stage_pipeline_depth(config)
        stage_pipeline_queue: Optional[asyncio.Queue] = None
        stage_pipeline_task: Optional[asyncio.Task] = None
        stage_pipeline_buffer: Dict[int, tuple[str, Path, bool]] = {}
        stage_pipeline_done = False
        prefetch_task: Optional[asyncio.Task] = None
        prefetch_for_idx: Optional[int] = None

        if stage_pipeline_enabled:
            stage_pipeline_queue = asyncio.Queue(maxsize=max(1, stage_pipeline_depth))

            async def _pipeline_producer() -> None:
                assert stage_pipeline_queue is not None
                for pidx, pchapter in enumerate(chapters_list):
                    pchapter_num = self._chapter_number(pchapter, pidx + 1)
                    started = time.time()
                    self._append_runtime_metric(
                        {
                            "event": "pipeline_stage_start",
                            "stage": "prepare",
                            "chapter": pchapter_num,
                        },
                        output_dir=output_dir,
                    )
                    try:
                        payload = await asyncio.to_thread(
                            self._resolve_pre_tts_payload,
                            pchapter,
                            pchapter_num,
                            output_dir,
                            config,
                        )
                        await stage_pipeline_queue.put((pidx, payload, None))
                        self._append_runtime_metric(
                            {
                                "event": "pipeline_stage_done",
                                "stage": "prepare",
                                "chapter": pchapter_num,
                                "elapsed_s": round(time.time() - started, 3),
                            },
                            output_dir=output_dir,
                        )
                    except Exception as exc:
                        await stage_pipeline_queue.put((pidx, None, exc))
                await stage_pipeline_queue.put((-1, None, None))

            stage_pipeline_task = asyncio.create_task(_pipeline_producer())
            self._append_runtime_metric(
                {
                    "event": "pipeline_enabled",
                    "depth": stage_pipeline_depth,
                    "chapters": len(chapters_list),
                },
                output_dir=output_dir,
            )

        def _launch_prefetch(next_idx: int) -> None:
            nonlocal prefetch_task, prefetch_for_idx
            if stage_pipeline_enabled:
                return
            if not self._chapter_prefetch_enabled:
                return
            if next_idx < 0 or next_idx >= len(chapters_list):
                return
            next_chapter = chapters_list[next_idx]
            next_chapter_num = self._chapter_number(next_chapter, next_idx + 1)
            prefetch_for_idx = next_idx
            prefetch_task = asyncio.create_task(
                asyncio.to_thread(
                    self._resolve_pre_tts_payload,
                    next_chapter,
                    next_chapter_num,
                    output_dir,
                    config,
                )
            )
            self._append_runtime_metric(
                {
                    "event": "prefetch_request",
                    "chapter": next_chapter_num,
                },
                output_dir=output_dir,
            )

        chapter_char_estimates = [max(0, self._estimate_chapter_chars(ch)) for ch in chapters_list]
        if not self._eta_recent_cps:
            baseline_cps = self._load_eta_baseline(config)
            if baseline_cps > 1.0:
                self._eta_recent_cps = [baseline_cps]
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
            if stage_pipeline_enabled and stage_pipeline_queue is not None:
                if idx in stage_pipeline_buffer:
                    speech_text, pre_tts_path, payload_locked = stage_pipeline_buffer.pop(idx)
                else:
                    while True:
                        queue_idx, queue_payload, queue_error = await stage_pipeline_queue.get()
                        if queue_idx == -1:
                            stage_pipeline_done = True
                            break
                        if queue_error is not None:
                            if queue_idx == idx:
                                queue_payload = self._resolve_pre_tts_payload(
                                    chapter, chapter_num, output_dir, config
                                )
                            else:
                                continue
                        if queue_payload is None:
                            continue
                        if queue_idx == idx:
                            speech_text, pre_tts_path, payload_locked = queue_payload
                            break
                        stage_pipeline_buffer[queue_idx] = queue_payload
                    if stage_pipeline_done and idx not in stage_pipeline_buffer:
                        speech_text, pre_tts_path, payload_locked = self._resolve_pre_tts_payload(
                            chapter, chapter_num, output_dir, config
                        )
            else:
                used_prefetch = False
                if prefetch_task is not None and prefetch_for_idx == idx:
                    try:
                        speech_text, pre_tts_path, payload_locked = await prefetch_task
                        used_prefetch = True
                        self._append_runtime_metric(
                            {
                                "event": "prefetch_hit",
                                "chapter": chapter_num,
                            },
                            output_dir=output_dir,
                        )
                    except Exception:
                        used_prefetch = False
                        self._append_runtime_metric(
                            {
                                "event": "prefetch_fallback",
                                "chapter": chapter_num,
                            },
                            output_dir=output_dir,
                        )
                    prefetch_task = None
                    prefetch_for_idx = None
                if not used_prefetch:
                    speech_text, pre_tts_path, payload_locked = self._resolve_pre_tts_payload(
                        chapter, chapter_num, output_dir, config
                    )
                _launch_prefetch(idx + 1)
            current_payload: Optional[str] = speech_text
            chapter_chars = len(speech_text or "")
            # Skip chapters that exceed the configured size limit (e.g. footnote-container
            # files that hold the entire book text as annotation content).
            if MAX_CHAPTER_CHARS > 0 and chapter_chars > MAX_CHAPTER_CHARS:
                print(
                    f"\n⏭️  Skipping chapter {chapter_num} ({chapter_chars:,} chars >"
                    f" MAX_CHAPTER_CHARS={MAX_CHAPTER_CHARS:,}): {chapter.name[:60]}"
                )
                self.progress.complete_chapter(f"⏭️ Skipped ({chapter_chars:,} chars, oversized)")
                converted_files.append(None)  # placeholder so indices stay aligned
                continue
            deferred_safe_pass = bool(getattr(chapter, "_deferred_safe_pass", False))
            remaining_chars_estimate = max(
                0,
                int(chapter_chars)
                + sum(max(0, int(v or 0)) for v in chapter_char_estimates[idx + 1 :]),
            )
            recent_cps = 0.0
            if self._eta_recent_cps:
                recent_tail = self._eta_recent_cps[-6:]
                recent_cps = sum(recent_tail) / max(1, len(recent_tail))
            with contextlib.suppress(Exception):
                self.progress.update_eta_hint(
                    remaining_chars=remaining_chars_estimate,
                    chars_per_second=recent_cps,
                )
            progress_started = False
            chapter_attempt = 0
            max_chapter_attempts = 4 if deferred_safe_pass else 6
            forced_auto_engine: Optional[str] = None
            blocked_engines_for_chapter: Set[str] = set()
            edge_connectivity_recorded = False
            if edge_globally_blocked or "__ALL__" in edge_blocked_chapters_global:
                blocked_engines_for_chapter.add("edge")
            if str(chapter_num) in edge_blocked_chapters_global:
                blocked_engines_for_chapter.add("edge")
            if chapter_label in edge_blocked_chapters_global:
                blocked_engines_for_chapter.add("edge")
            chapter_name_raw = str(getattr(chapter, "name", "") or "").strip()
            if chapter_name_raw in edge_blocked_chapters_global:
                blocked_engines_for_chapter.add("edge")
            # Product decision: keep Edge available as the first attempt even on weak networks.
            if deferred_safe_pass:
                blocked_engines_for_chapter.add("edge")

            while True:
                chapter_attempt += 1
                chapter_retry = False
                start_time = time.time()
                if chapter_attempt > 1:
                    retry_backoff = min(30, 2 ** min(chapter_attempt, 5))
                    self.progress.tick(
                        f"⏳ Retry backoff {retry_backoff}s (attempt {chapter_attempt}/{max_chapter_attempts})"
                    )
                    await asyncio.sleep(retry_backoff)

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
                    return message or "Synthesis failed"

                def _block_edge_connectivity(last_error: Optional[str]) -> None:
                    nonlocal forced_auto_engine
                    nonlocal edge_connectivity_recorded
                    nonlocal edge_globally_blocked
                    nonlocal config
                    blocked_engines_for_chapter.add("edge")
                    # Keep Edge unavailable for the remainder of this sequential pass.
                    unavailable_engines.add("edge")
                    edge_globally_blocked = True
                    _trip_edge_circuit("network")
                    if not edge_connectivity_recorded:
                        self.speed_controller.record_connectivity_failure("edge")
                        edge_connectivity_recorded = True
                    err_text = str(last_error or "")[:220]
                    self._append_runtime_metric(
                        {
                            "event": "edge_connectivity_failure",
                            "chapter": chapter_num,
                            "engine": "edge",
                            "error": err_text,
                        },
                        output_dir=output_dir,
                    )
                    edge_blocked_chapters_global.update(
                        {
                            "__ALL__",
                            str(chapter_num),
                            str(chapter_label or "").strip(),
                            str(getattr(chapter, "name", "") or "").strip(),
                        }
                    )
                    if getattr(config, "extra", None) is None:
                        config.extra = {}
                    config.extra["edge_blocked_chapters"] = sorted(
                        item for item in edge_blocked_chapters_global if item
                    )
                    self._append_runtime_metric(
                        {
                            "event": "edge_blocked_chapter",
                            "chapter": chapter_num,
                            "chapter_label": chapter_label,
                            "engine": "edge",
                            "blocked_size": len(config.extra["edge_blocked_chapters"]),
                        },
                        output_dir=output_dir,
                    )
                    with contextlib.suppress(Exception):
                        from .config import VoiceConfigProvider

                        if can_use_piper():
                            piper_language = self._effective_primary_language(config)
                            piper_model = VoiceConfigProvider().get_voice("piper", piper_language)
                            config = replace(
                                config,
                                engine="piper",
                                primary_language=piper_language,
                                model_path=Path(piper_model) if piper_model else config.model_path,
                            )
                            engine_pool.register_engine("piper", config)
                    if (engine_tracker.get("label") or "").lower() in {"piper", "coqui", "kokoro"}:
                        forced_auto_engine = (engine_tracker.get("label") or "").lower()

                # **RESTORED**: Usar progress tracker (apenas uma vez por chapter)
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
                engine_config: Optional[ConversionConfig] = None

                try:
                    # Conversion to temp directory
                    output_path = self._expected_output_path(chapter, chapter_num, output_dir)

                    # Check if MP3 already exists and is valid (size > 1KB)
                    # Note: Cache validation already done by _validate_and_clean_cache()
                    if output_path.exists() and not config.force_reprocess:
                        file_size = output_path.stat().st_size
                        if file_size > 1000:  # Minimum 1KB for valid audio
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
                                    print(f"   ⚠️ Invalid cache detected: {truncation_warning}")
                                output_path.unlink(missing_ok=True)
                            else:
                                converted_files.append(output_path)
                                chapter_success = True
                                chapter_cached = True
                                self.progress.tick(f"✅ File already exists ({file_size} bytes)")
                                self.progress.complete_chapter("✅ Complete (cache)")
                                self._retry_original_texts.pop(chapter_label, None)
                                break
                        else:
                            # Empty or corrupted file — remove and reconvert
                            if self.verbose:
                                print(
                                    f"   🗑️ Removing invalid file ({file_size} bytes): {output_path}"
                                )
                            output_path.unlink(missing_ok=True)
                            output_path.with_suffix(".wav").unlink(missing_ok=True)

                    # Synthesize with heartbeat and timeout (optimized)
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
                            chapter_error = "No engine available in automatic mode"
                            errors.append(f"{chapter.name}: {chapter_error}")
                            chapter_error = _error_text(chapter_error)
                            self.progress.complete_chapter(f"❌ {chapter_error}")
                            break
                        must_try_edge_first = (
                            "edge" in pool_view
                            and "edge" not in blocked_engines_for_chapter
                            and "edge" not in attempted_auto
                        )
                        if must_try_edge_first:
                            picked_engine = "edge"
                            auto_order = [
                                name
                                for name in self._preferred_auto_engine_order(pool_view)
                                if name not in blocked_engines_for_chapter
                            ]
                            if self.verbose:
                                print("   ⚡ AUTO: forcing first attempt on edge for this chapter")
                        if forced_auto_engine and forced_auto_engine in blocked_engines_for_chapter:
                            forced_auto_engine = None
                        if (
                            not must_try_edge_first
                            and forced_auto_engine
                            and forced_auto_engine in pool_view
                        ):
                            picked_engine = forced_auto_engine
                            auto_order = self._preferred_auto_engine_order(pool_view)
                            if picked_engine in auto_order:
                                auto_order = [picked_engine] + [
                                    name for name in auto_order if name != picked_engine
                                ]
                            auto_order = [
                                name
                                for name in auto_order
                                if name not in blocked_engines_for_chapter
                            ]
                            if self.verbose:
                                print(f"   ⚡ AUTO: forcing engine {picked_engine} for retry")
                        else:
                            picked_engine, auto_order = self._pick_auto_engine(
                                chapter_chars, estimated_seconds, pool_view
                            )
                            auto_order = [
                                name
                                for name in (auto_order or [])
                                if name not in blocked_engines_for_chapter
                            ]
                            if picked_engine in blocked_engines_for_chapter:
                                picked_engine = next(
                                    (
                                        candidate
                                        for candidate in (auto_order or [])
                                        if candidate in pool_view
                                    ),
                                    picked_engine,
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
                            edge_reason = f"Chapter too large ({chapter_chars} chars)"
                        elif threshold_seconds and estimated_seconds >= threshold_seconds:
                            edge_reason = f"Chapter estimated at {int(estimated_seconds)}s"
                        if edge_reason and self.verbose:
                            print(f"   ℹ️ Edge keeps engine even for large chapter: {edge_reason}")
                        elif edge_force_offline:
                            if self.verbose:
                                print("   ℹ️ Edge marked as unstable, keeping engine (no fallback)")
                            edge_force_offline = False
                            edge_state["force_offline_after_trunc"] = False

                    # Product decision: no predictive edge→offline switching before a real failure.

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
                            self.progress.set_active_engine(current_engine_label)
                            break
                        except Exception as exc:
                            unavailable_engines.add(current_engine_label)
                            if is_auto_engine and auto_order:
                                candidate_order = [
                                    name
                                    for name in (auto_order or [])
                                    if name not in blocked_engines_for_chapter
                                ]
                                next_engine = self._next_auto_engine(
                                    candidate_order, attempted_auto
                                )
                                if next_engine:
                                    attempted_auto.add(next_engine)
                                    engine_tracker["label"] = next_engine
                                    current_engine_label = next_engine
                                    continue
                            chapter_error = f"Engine {current_engine_label} unavailable: {exc}"
                            errors.append(f"{chapter.name}: {chapter_error}")
                            chapter_error = _error_text(chapter_error)
                            self.progress.complete_chapter(f"❌ {chapter_error}")
                            engine_obj = None
                            break

                    if engine_obj is None:
                        break

                    tts_engine = engine_obj
                    self._apply_persisted_engine_params(
                        cfg=engine_config,
                        engine_label=current_engine_label,
                        engine_obj=tts_engine,
                    )
                    await self._run_engine_warmup(
                        engine_label=current_engine_label,
                        engine_obj=tts_engine,
                        cfg=engine_config,
                        output_dir=output_dir,
                    )
                    if (current_engine_label or "").lower() == "piper":
                        with contextlib.suppress(Exception):
                            await self._maybe_run_piper_canary(
                                tts_engine=tts_engine,
                                config=engine_config,
                                chapter_text=speech_text,
                                output_dir=output_dir,
                                chapter_index=chapter_num,
                            )
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
                                print(f"   ♻️ Segment plan reused: {len(plan_segments)} blocks")
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
                            "safe mode enabled",
                            engine_pool=engine_pool,
                            engine_obj=tts_engine,
                        )
                    elif current_engine_label == "edge" and chapter_chars >= EDGE_FORCE_SAFE_CHARS:
                        self._apply_edge_slow_mode(
                            f"chapter too large ({chapter_chars} chars)",
                            engine_pool=engine_pool,
                            engine_obj=tts_engine,
                        )
                        with contextlib.suppress(Exception):
                            setattr(tts_engine, "_auto_tune_enabled", False)

                    # Optimized timeout: aggressive floor, larger ceiling for long Edge chapters
                    # Base: duration estimada * 1.5 + 30s buffer
                    base_timeout = estimated_seconds * 1.5 + 30.0
                    timeout_seconds = max(base_timeout, 60.0)  # Minimum 60s
                    max_timeout = 600.0  # Default: up to 10 min
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
                    # Aggressive local strategy for large chapters on Piper.
                    if current_engine_label == "piper" and chapter_chars >= 15000:
                        cpu_physical = max(
                            1,
                            int(
                                getattr(getattr(self, "hardware_profile", None), "cpu_physical", 2)
                                or 2
                            ),
                        )
                        ram_total = float(
                            getattr(getattr(self, "hardware_profile", None), "ram_total_gb", 0.0)
                            or 0.0
                        )
                        if chapter_chars >= 200000:
                            target_chunk = 1400
                        elif chapter_chars >= 100000:
                            target_chunk = 1800
                        elif chapter_chars >= 25000:
                            target_chunk = 2200
                        else:
                            target_chunk = 2400
                        target_workers = min(4, cpu_physical)
                        if 0 < ram_total < 8:
                            target_workers = min(target_workers, 2)
                        target_workers = max(1, target_workers)
                        # Progressive safer tuning across retries (including deferred-safe pass)
                        retry_tier = max(0, int(chapter_attempt) - 1)
                        if deferred_safe_pass:
                            retry_tier = max(retry_tier, 3)
                        if retry_tier > 0:
                            # Keep Piper fallback retries conservative but avoid collapsing
                            # to single-worker mode, which can make very large chapters
                            # impractically slow on CPU-only environments.
                            capped_tier = min(retry_tier, 2)
                            target_chunk = max(1200, int(target_chunk * (0.86**capped_tier)))
                            target_workers = max(2, min(target_workers, 4 - capped_tier))
                        os.environ["PIPER_CHUNK_CHARS"] = str(target_chunk)
                        os.environ["PIPER_MAX_PROCS"] = str(target_workers)
                        with contextlib.suppress(Exception):
                            setattr(tts_engine, "_chunk_char_limit", target_chunk)
                        with contextlib.suppress(Exception):
                            setattr(tts_engine, "_semaphore", asyncio.Semaphore(target_workers))
                        piper_min_timeout = float(
                            os.getenv("PIPER_LARGE_TIMEOUT_MIN", "900") or "900"
                        )
                        if chapter_chars >= 200000:
                            piper_timeout_cap = float(
                                os.getenv("PIPER_LARGE_TIMEOUT_MAX_200K", "3600") or "3600"
                            )
                        elif chapter_chars >= 100000:
                            piper_timeout_cap = float(
                                os.getenv("PIPER_LARGE_TIMEOUT_MAX_100K", "2400") or "2400"
                            )
                        elif chapter_chars >= 50000:
                            piper_timeout_cap = float(
                                os.getenv("PIPER_LARGE_TIMEOUT_MAX_50K", "1800") or "1800"
                            )
                        else:
                            piper_timeout_cap = float(
                                os.getenv("PIPER_LARGE_TIMEOUT_MAX", "900") or "900"
                            )
                        if deferred_safe_pass:
                            piper_timeout_cap = max(piper_timeout_cap, 1800.0)
                        timeout_seconds = min(
                            max(timeout_seconds, piper_min_timeout), piper_timeout_cap
                        )
                        if self.verbose:
                            print(
                                f"⚡ Piper large-chapter mode: chunks={target_chunk}, "
                                f"workers={target_workers}, timeout={int(timeout_seconds)}s"
                            )
                    timeout_seconds = int(timeout_seconds)
                    stall_seconds = float(os.getenv("CHAPTER_STALL_SECONDS", "120") or "120")
                    if stall_seconds < 0:
                        stall_seconds = 0.0
                    # Avoid false "stuck" detection on large local chapters (Piper/Coqui):
                    # synthesis can take >45-60s before first progress callback.
                    if current_engine_label in {"piper", "coqui"} and chapter_chars >= 50000:
                        local_floor = float(
                            os.getenv("LOCAL_ENGINE_STALL_MIN_SECONDS", "600") or "600"
                        )
                        proportional = max(
                            local_floor,
                            min(float(timeout_seconds) * 0.40, float(timeout_seconds) * 0.85),
                        )
                        stall_seconds = max(stall_seconds, proportional)
                        if self.verbose:
                            print(
                                f"🛡️ Local engine stall guard: stall timeout={int(stall_seconds)}s"
                            )

                    if self.verbose:
                        print(
                            f"🎤 [{chapter_num}/{len(chapters_list)}] {chapter.name}: Starting TTS synthesis"
                        )
                        print(f"   📝 Text: {chapter_chars} chars (timeout: {timeout_seconds}s)")

                    self.progress.tick(
                        f"🎤 Synthesizing {chapter_chars} chars (timeout: {timeout_seconds}s)..."
                    )

                    # Heartbeat to show progress (optimized: 3s instead of 1s)
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
                            print(f"   🔄 Running TTS command: {type(tts_engine).__name__}")

                        synthesis_result = None
                        slow_engine_triggered = False
                        max_attempts = 1 if current_engine_label == "edge" else 2
                        last_tts_output_path = tts_output_path
                        last_needs_transcode = needs_mp3_transcode
                        self._append_runtime_metric(
                            {
                                "event": "pipeline_stage_start",
                                "stage": "synthesize",
                                "chapter": chapter_num,
                                "engine": current_engine_label,
                            },
                            output_dir=output_dir,
                        )
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
                                segment_progress_state["hits"] += 1
                                self._record_segment_success(
                                    engine_label=engine_tracker.get("label")
                                    or (config.engine or "").lower(),
                                    chapter_index=chapter_num,
                                    segment_chars=len(text or ""),
                                    engine_pool=engine_pool,
                                    config=engine_config,
                                )

                            def on_pre_segment(text: str, total_chars: int):
                                segment_chars = len(text or "")
                                self._mark_health_activity(chapter_num, "pre-segment")
                                self._pre_segment_health_check(
                                    engine_label=engine_tracker.get("label")
                                    or (config.engine or "").lower(),
                                    segment_chars=segment_chars,
                                    engine_pool=engine_pool,
                                    config=engine_config,
                                    engine_obj=engine_instance.get("object"),
                                )

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
                                disable_resume = str(
                                    (getattr(config, "extra", {}) or {}).get(
                                        "disable_chunk_resume", "0"
                                    )
                                ).strip().lower() in {"1", "true", "yes", "on"}
                                # Avoid retry loops: after first chapter attempt, discard stale chunks
                                # so we don't keep replaying the same failing segment payload.
                                # Also discard when force_reprocess/clear_cache is set — stale chunks
                                # must not be resumed when the user explicitly requests a fresh run.
                                resume_allowed = (
                                    (not disable_resume)
                                    and chapter_attempt == 1
                                    and attempt == 0
                                    and not getattr(config, "force_reprocess", False)
                                    and not getattr(config, "clear_cache", False)
                                )
                                if not resume_allowed:
                                    try:
                                        for stale in chunk_root.glob("chunk_*.*"):
                                            stale.unlink(missing_ok=True)
                                        (chunk_root / "manifest.json").unlink(missing_ok=True)
                                        if self.verbose:
                                            self.progress.tick(
                                                "🧹 Clearing stale chunks before retry (anti-loop)"
                                            )
                                    except Exception:
                                        pass
                                try:
                                    existing_chunks = list(chunk_root.glob("chunk_*.mp3"))
                                except Exception:
                                    existing_chunks = []
                                if existing_chunks:
                                    self.progress.tick(
                                        f"♻️ Resuming {len(existing_chunks)} chunk(s) already ready"
                                    )

                            def on_chunk_ready(
                                segment_index: int,
                                temp_path: Path,
                                segment_text: Optional[str] = None,
                            ) -> None:
                                segment_progress_state["hits"] += 1
                                # Update bar with completed chunks
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
                                        print(f"   ⚠️ Failure saving chunk {segment_index}: {exc}")

                            # Only use callback/chunking when a resume directory is available
                            chunk_callback = on_chunk_ready if chunk_root else None
                            primary_chunk_callback = chunk_callback
                            primary_chunk_root = chunk_root if chunk_root else None

                            stall_event = asyncio.Event()
                            slow_switch_event = asyncio.Event()
                            segment_progress_state = {"hits": 0}
                            # Reset stall reference when a new synthesis attempt starts
                            # (including engine switches within the same chapter).
                            with contextlib.suppress(Exception):
                                self.progress.mark_activity()
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
                                    pre_segment_callback=on_pre_segment,
                                    chunk_callback=primary_chunk_callback,
                                    resume_chunks_dir=primary_chunk_root,
                                )
                            )
                            stall_task = asyncio.create_task(
                                self._watch_chapter_stall(
                                    chapter_num,
                                    synthesis_task,
                                    stall_seconds,
                                    stall_event,
                                    probe_dir=Path(getattr(config, "cache_dir", "") or ""),
                                )
                            )
                            slow_task: Optional[asyncio.Task] = None

                            if (
                                ENGINE_SLOW_FALLBACK_ENABLED
                                and is_auto_engine
                                and auto_order
                                and len(auto_order) > 1
                            ):
                                network_hint = (
                                    str(
                                        getattr(
                                            getattr(self, "hardware_profile", None),
                                            "network_speed_estimate",
                                            "",
                                        )
                                        or ""
                                    )
                                    .strip()
                                    .lower()
                                )
                                avoid_edge_due_network = network_hint in {
                                    "slow",
                                    "unknown",
                                    "unstable",
                                }
                                current_is_local = (current_engine_label or "").lower() in {
                                    "piper",
                                    "coqui",
                                }
                                skip_slow_switch = (
                                    current_is_local
                                    and chapter_chars >= EDGE_PREDICTIVE_TIMEOUT_CHARS
                                    and avoid_edge_due_network
                                )

                                async def _watch_slow_engine() -> None:
                                    min_slow = max(30, int(ENGINE_SLOW_FALLBACK_MIN_SECONDS))
                                    timeout_ratio = float(ENGINE_SLOW_FALLBACK_TIMEOUT_RATIO)
                                    timeout_ratio = max(0.15, min(timeout_ratio, 0.9))
                                    trigger_after = max(
                                        min_slow, int(timeout_seconds * timeout_ratio)
                                    )
                                    # New guard: even with partial progress, switch engine if
                                    # no new segment/chunk arrives for too long.
                                    no_progress_ratio = float(
                                        os.getenv("ENGINE_SLOW_NO_PROGRESS_RATIO", "0.22") or "0.22"
                                    )
                                    no_progress_ratio = max(0.10, min(no_progress_ratio, 0.75))
                                    no_progress_after = max(
                                        min_slow,
                                        int(timeout_seconds * no_progress_ratio),
                                    )
                                    last_hits = int(segment_progress_state["hits"])
                                    last_progress_at = time.time()
                                    hard_elapsed_ratio = float(
                                        os.getenv("ENGINE_SLOW_HARD_ELAPSED_RATIO", "0.55")
                                        or "0.55"
                                    )
                                    hard_elapsed_ratio = max(0.25, min(hard_elapsed_ratio, 0.95))
                                    hard_elapsed_limit = max(
                                        min_slow * 2,
                                        int(timeout_seconds * hard_elapsed_ratio),
                                    )
                                    while True:
                                        await asyncio.sleep(5)
                                        if synthesis_task.done():
                                            return
                                        elapsed_s = int(time.time() - start_synthesis)
                                        current_hits = int(segment_progress_state["hits"])
                                        now_ts = time.time()
                                        if current_hits > last_hits:
                                            last_hits = current_hits
                                            last_progress_at = now_ts
                                        idle_for = int(max(0.0, now_ts - last_progress_at))
                                        if elapsed_s < trigger_after:
                                            continue
                                        # Original behavior: no segment progress at all.
                                        if current_hits <= 0:
                                            slow_switch_event.set()
                                            with contextlib.suppress(Exception):
                                                synthesis_task.cancel()
                                            return
                                        # New behavior: progress exists but became too sparse/stalled.
                                        if idle_for >= no_progress_after:
                                            slow_switch_event.set()
                                            with contextlib.suppress(Exception):
                                                synthesis_task.cancel()
                                            return
                                        # Safety valve for very long elapsed time with weak progress.
                                        if elapsed_s >= hard_elapsed_limit and current_hits < 4:
                                            slow_switch_event.set()
                                            with contextlib.suppress(Exception):
                                                synthesis_task.cancel()
                                            return

                                if not skip_slow_switch:
                                    slow_task = asyncio.create_task(_watch_slow_engine())
                            try:
                                synthesis_result = await asyncio.wait_for(
                                    synthesis_task, timeout=timeout_seconds
                                )
                            except asyncio.CancelledError as exc:
                                if stall_event.is_set() or slow_switch_event.is_set():
                                    raise asyncio.TimeoutError() from exc
                                raise
                            finally:
                                stall_task.cancel()
                                with contextlib.suppress(asyncio.CancelledError):
                                    await stall_task
                                if slow_task is not None:
                                    slow_task.cancel()
                                    with contextlib.suppress(asyncio.CancelledError):
                                        await slow_task
                            if synthesis_result:
                                break
                            waited = await wait_edge_cooldown_if_needed(
                                f"attempt {attempt + 1}/{max_attempts}",
                                tracker=engine_tracker,
                                engine_ref=engine_instance,
                            )
                            if not waited:
                                break

                        if synthesis_result and last_needs_transcode:
                            self._append_runtime_metric(
                                {
                                    "event": "pipeline_stage_start",
                                    "stage": "encode",
                                    "chapter": chapter_num,
                                    "engine": current_engine_label,
                                },
                                output_dir=output_dir,
                            )
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
                                print("[DEBUG] Failure converting WAV→MP3 (ffmpeg)")
                                self._append_runtime_metric(
                                    {
                                        "event": "transcode_failed",
                                        "chapter": chapter_num,
                                        "engine": current_engine_label,
                                        "input": str(last_tts_output_path.name),
                                        "output": str(output_path.name),
                                    },
                                    output_dir=output_dir,
                                )
                            synthesis_result = converted
                            if synthesis_result:
                                with contextlib.suppress(OSError):
                                    last_tts_output_path.unlink(missing_ok=True)
                                self._append_runtime_metric(
                                    {
                                        "event": "pipeline_stage_done",
                                        "stage": "encode",
                                        "chapter": chapter_num,
                                        "engine": current_engine_label,
                                    },
                                    output_dir=output_dir,
                                )

                        if self.verbose and synthesis_result:
                            print(f"   ✅ TTS completed: {output_path.name}")
                    except asyncio.TimeoutError:
                        elapsed = int(time.time() - start_synthesis)
                        if slow_switch_event.is_set() and is_auto_engine and auto_order:
                            current_engine = (engine_tracker.get("label") or "").lower()
                            blocked_engines_for_chapter.add(current_engine)
                            attempted_auto.add(current_engine)
                            slow_engine_triggered = True
                            if self.verbose:
                                print(
                                    f"   ⚡ Slow engine detected ({current_engine}, {elapsed}s without segment progress) - switching engine"
                                )
                            self.progress.tick(
                                f"⚡ Slow engine {current_engine}: switching automatically"
                            )
                            synthesis_result = None
                            continue
                        if self.verbose:
                            print(f"   ⚠️ TIMEOUT: Chapter stuck after {elapsed}s")
                        self.progress.tick(
                            f"⚠️ TIMEOUT after {elapsed}s - trying fallback without language..."
                        )
                        if current_engine_label == "edge":
                            _maybe_apply_edge_slow_mode(
                                f"timeout after {elapsed}s", engine_obj=tts_engine
                            )
                            setattr(tts_engine, "last_error", "timeout")
                            await wait_edge_cooldown_if_needed(
                                f"timeout after {elapsed}s",
                                tracker=engine_tracker,
                                engine_ref=engine_instance,
                            )
                        elif current_engine_label == "coqui":
                            _maybe_apply_coqui_recovery(
                                f"timeout after {elapsed}s", engine_obj=tts_engine
                            )

                        # **FALLBACK**: Remover language markup e tentar novamente
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
                                print("   🔄 RETRY: Trying again without language markers")
                                print(
                                    f"   📝 RETRY: {clean_chars} chars (timeout: {fallback_timeout}s)"
                                )

                            self.progress.tick(
                                f"🔄 Fallback: {clean_chars} chars (timeout: {fallback_timeout}s)"
                            )

                            # Heartbeat for fallback engine (optimized: 3s)
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
                                        pre_segment_callback=on_pre_segment,
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
                                        print("[DEBUG] Failure converting WAV→MP3 (fallback)")
                                        self._append_runtime_metric(
                                            {
                                                "event": "transcode_failed",
                                                "chapter": chapter_num,
                                                "engine": current_engine_label,
                                                "input": str(tts_output_path.name),
                                                "output": str(output_path.name),
                                                "phase": "fallback",
                                            },
                                            output_dir=output_dir,
                                        )
                                    synthesis_result = converted
                                    if synthesis_result:
                                        with contextlib.suppress(OSError):
                                            tts_output_path.unlink(missing_ok=True)
                                if self.verbose and synthesis_result:
                                    print("   ✅ RETRY: Success no fallback!")
                            finally:
                                heartbeat_active = False
                                fallback_task.cancel()
                                with contextlib.suppress(asyncio.CancelledError):
                                    await fallback_task

                        except (ImportError, asyncio.TimeoutError):
                            total_elapsed = int(time.time() - start_synthesis)
                            if self.verbose:
                                print(
                                    "   ⚠️ FALLBACK: Double attempt failed; skipping short-text emergency to avoid truncation"
                                )
                            self.progress.tick("🔄 Full-text retry only (short emergency disabled)")
                            # Never synthesize reduced text (e.g., first 1000 chars), because
                            # it generates valid-but-truncated audio and poisons final validation.
                            synthesis_result = None
                            with contextlib.suppress(Exception):
                                setattr(tts_engine, "last_error", "timeout_full_retry_required")

                            if not synthesis_result:
                                total_elapsed = int(time.time() - start_synthesis)
                                error_msg = (
                                    f"TRIPLE TIMEOUT after {total_elapsed}s - all attempts failed"
                                )
                                current_label = (engine_tracker.get("label") or "").lower()
                                if (
                                    is_auto_engine
                                    and current_label in {"piper", "coqui"}
                                    and chapter_attempt < max_chapter_attempts
                                ):
                                    # Keep retrying the same chapter locally with safer settings
                                    # instead of skipping ahead with failure.
                                    blocked_engines_for_chapter.add("edge")
                                    forced_auto_engine = current_label
                                    if current_label == "piper":
                                        try:
                                            current_chunk = int(
                                                os.getenv(
                                                    "PIPER_CHUNK_CHARS",
                                                    str(
                                                        getattr(config, "piper_chunk_chars", 1800)
                                                        or 1800
                                                    ),
                                                )
                                                or "1800"
                                            )
                                        except Exception:
                                            current_chunk = 1800
                                        safer_chunk = max(900, int(current_chunk * 0.75))
                                        os.environ["PIPER_CHUNK_CHARS"] = str(safer_chunk)
                                        os.environ["PIPER_MAX_PROCS"] = "2"
                                        with contextlib.suppress(Exception):
                                            setattr(config, "piper_chunk_chars", safer_chunk)
                                        with contextlib.suppress(Exception):
                                            setattr(config, "piper_max_procs", 2)
                                    self.progress.tick(
                                        "🔁 Local timeout: retrying same chapter with safer offline profile"
                                    )
                                    chapter_error = error_msg
                                    raise _RetryChapter(error_msg)
                                if self.verbose:
                                    print(f"   ❌ FINAL ERROR: {error_msg}")
                                chapter_error = error_msg
                                if (engine_tracker.get("label") or "").lower() == "edge":
                                    if is_auto_engine:
                                        blocked_engines_for_chapter.add("edge")
                                        _trip_edge_circuit("timeout")
                                    else:
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
                        if (not slow_engine_triggered) and current_engine_label in {
                            "piper",
                            "coqui",
                        }:
                            blocked_engines_for_chapter.add("edge")
                            forced_auto_engine = current_engine_label
                            self._append_runtime_metric(
                                {
                                    "event": "sticky_offline_after_transcode_failure",
                                    "chapter": chapter_num,
                                    "engine": current_engine_label,
                                },
                                output_dir=output_dir,
                            )
                        if current_engine_label == "edge":
                            last_err = str(getattr(tts_engine, "last_error", "") or "")
                            if _edge_error_reason(last_err) in {"network", "auth"}:
                                _block_edge_connectivity(last_err)
                        preferred_order = [
                            name
                            for name in (auto_order or [])
                            if name not in blocked_engines_for_chapter
                        ]
                        if not preferred_order:
                            # Safety net: if local order is exhausted, rebuild candidates from pool
                            # so slow-engine fallback can still switch instead of failing chapter.
                            pool_fallback = available_auto_pool()
                            preferred_order = [
                                name
                                for name in self._preferred_auto_engine_order(pool_fallback)
                                if name not in blocked_engines_for_chapter
                            ]
                        next_engine = self._next_auto_engine(preferred_order, attempted_auto)
                        if next_engine:
                            attempted_auto.add(next_engine)
                            forced_auto_engine = next_engine
                            engine_tracker["label"] = next_engine
                            current_engine_label = next_engine
                            if self.verbose:
                                print(f"   ⚡ AUTO: switching to {next_engine} and retrying")
                            self._append_runtime_metric(
                                {
                                    "event": "engine_switch",
                                    "chapter": chapter_num,
                                    "to": next_engine,
                                    "blocked": sorted(blocked_engines_for_chapter),
                                },
                                output_dir=output_dir,
                            )
                            tts_output_path, needs_mp3_transcode = _resolve_tts_output_path(
                                output_path, next_engine
                            )
                            continue

                    if synthesis_result and output_path.exists():
                        self._append_runtime_metric(
                            {
                                "event": "pipeline_stage_done",
                                "stage": "synthesize",
                                "chapter": chapter_num,
                                "engine": engine_tracker.get("label")
                                or (config.engine or "").lower(),
                            },
                            output_dir=output_dir,
                        )
                        file_size = output_path.stat().st_size

                        # Validar que o file tem tamanho minimum (not is empty/corrupted)
                        if file_size > 1000:  # Minimum 1KB for valid audio
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
                                        "Truncated audio", engine_obj=tts_engine
                                    )
                                    # Force fallback offline after truncamento
                                    edge_state = self._edge_auto_state or {}
                                    edge_state["force_offline_after_trunc"] = True
                                    self._edge_auto_state = edge_state
                                    if is_auto_engine:
                                        pool_view = available_auto_pool()
                                        fallback_engine = self._resolve_offline_fallback_engine(
                                            set(pool_view.keys())
                                        )
                                        if (
                                            fallback_engine
                                            and fallback_engine not in blocked_engines_for_chapter
                                        ):
                                            forced_auto_engine = fallback_engine
                                            if self.verbose:
                                                print(
                                                    "   ⚡ Truncation detected - forcing offline retry: "
                                                    f"edge → {fallback_engine}"
                                                )
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
                                        chapter_error = audio_error or "Invalid audio"
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
                                    chapter_error = segments_error or "Incomplete segments"
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
                                print(f"   📊 File generated: {file_size} bytes")
                            self.progress.complete_chapter(f"✅ Success ({file_size} bytes)")
                            chapter_elapsed = time.time() - start_time
                            current_engine_label = (
                                engine_tracker.get("label") or (config.engine or "").lower()
                            )
                            if chapter_chars:
                                throughput = int(chapter_chars / max(chapter_elapsed, 0.001))
                            else:
                                throughput = 0
                            if chapter_chars > 0 and chapter_elapsed > 0:
                                cps = float(chapter_chars) / max(float(chapter_elapsed), 0.001)
                                self._eta_recent_cps.append(cps)
                                if len(self._eta_recent_cps) > 12:
                                    del self._eta_recent_cps[0 : len(self._eta_recent_cps) - 12]
                                self._save_eta_baseline(config, cps)
                                self._update_startup_guardrail(config, cps)
                            engine_display = (current_engine_label or "engine").upper()
                            print(
                                f"⏱️ [{engine_display}] Chapter {chapter_num} → "
                                f"{chapter_elapsed:.1f}s for {chapter_chars} chars "
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
                                        f"Edge took {int(chapter_elapsed)}s for this chapter"
                                    ):
                                        if self.verbose:
                                            print(
                                                "   ⚡ Next chapters will switch to offline engine for performance"
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
                                        f"low speed ({chars_per_second:.1f} chars/s)",
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
                                            f"   ⚠️ Truncated audio: {coverage_percent:.1f}% do text "
                                            f"({missing_percent:.1f}% missing)"
                                        )

                                    # Increment failure counters
                                    edge_failure_count += 1
                                    edge_consecutive_failures += 1

                                    # Mark for retry
                                    output_path.unlink(missing_ok=True)
                                    synthesis_result = None
                                    if is_auto_engine:
                                        pool_view = available_auto_pool()
                                        fallback_engine = self._resolve_offline_fallback_engine(
                                            set(pool_view.keys())
                                        )
                                        if (
                                            fallback_engine
                                            and fallback_engine not in blocked_engines_for_chapter
                                        ):
                                            forced_auto_engine = fallback_engine
                                            if self.verbose:
                                                print(
                                                    "   ⚡ Incomplete edge audio - forcing offline retry: "
                                                    f"edge → {fallback_engine}"
                                                )
                                    _edge_retry(
                                        f"Audio truncated ({coverage_percent:.1f}% coverage)",
                                        count_failure=False,
                                    )

                                    # Log failure stats
                                    if self.verbose:
                                        print(
                                            f"   📊 Failures Edge: {edge_failure_count} total, "
                                            f"{edge_consecutive_failures} consecutive"
                                        )
                                else:
                                    # Audio is complete - reset consecutive failures counter
                                    # (but keep total failure count for statistics)
                                    if edge_consecutive_failures > 0 and self.verbose:
                                        print(
                                            f"   ✅ Audio complete ({coverage_percent:.1f}% do text) - "
                                            f"resetting consecutive failures counter"
                                        )
                                    edge_consecutive_failures = 0
                        else:
                            # Output file too small - likely corrompido
                            if self.verbose:
                                print(
                                    f"   ⚠️ Output file too small ({file_size} bytes) - considerando failure"
                                )
                            output_path.unlink(missing_ok=True)
                            synthesis_result = None  # Force retry
                    else:
                        # **RETRY**: Tentar com language default em caso de failure
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
                            if reason in {"rate_limit", "timeout"}:
                                backoff = min(8.0, 1.5 + float(edge_consecutive_failures))
                                _maybe_apply_edge_slow_mode(
                                    f"{reason} detected", engine_obj=tts_engine
                                )
                                if self.verbose:
                                    print(
                                        f"   ⏳ Edge {reason}: applying {backoff:.1f}s backoff before retry"
                                    )
                                await asyncio.sleep(backoff)
                            _maybe_apply_edge_slow_mode(
                                f"failure Edge ({reason})", engine_obj=tts_engine
                            )
                            chapter_error = (
                                f"Edge unavailable ({reason})"
                                if reason != "unknown"
                                else "Edge failed"
                            )
                            if is_auto_engine and reason in {"network", "auth"}:
                                _block_edge_connectivity(last_err)
                                if self.verbose:
                                    print(
                                        "   🛡️ Edge blocked for this chapter/pass after connectivity failure"
                                    )
                            else:
                                _edge_retry(chapter_error, count_failure=False)
                        if self.verbose:
                            print("   ⚠️ RETRY: Synthesis failed, retrying with default language")

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
                                    self.progress.tick(
                                        "🔄 Retry: text simples (language default)..."
                                    )
                                    retry_timeout = 45

                                    synthesis_result = None
                                    for attempt in range(2):
                                        synthesis_result = await asyncio.wait_for(
                                            _synthesize_safe(
                                                tts_engine,
                                                simple_text,
                                                output_path,
                                                formatting_segments=None,
                                                pre_segment_callback=on_pre_segment,
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

                                        # Validar tamanho minimum
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
                                                            audio_error or "Invalid audio"
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
                                                        segments_error or "Incomplete segments"
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
                                                    f"   ✅ RETRY: Success with simplified text ({file_size} bytes)"
                                                )
                                            self.progress.complete_chapter("✅ Success (retry)")
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
                                                        f"Edge took {int(chapter_elapsed)}s for this chapter"
                                                    ):
                                                        if self.verbose:
                                                            print(
                                                                "   ⚡ Next chapters will switch to offline engine for performance"
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
                                            print(f"   ⚠️ RETRY: Invalid file ({file_size} bytes)")
                                        output_path.unlink(missing_ok=True)
                            except Exception as retry_e:
                                if self.verbose:
                                    print(f"   ❌ RETRY failed: {retry_e}")

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
                                        "Rate limit detected", engine_obj=tts_engine
                                    )
                                    if hasattr(self, "progress"):
                                        self.progress.tick(
                                            "⏳ Edge rate-limited; applying safe mode and retrying"
                                        )

                            # If all retries failed
                            error_msg = "Synthesis failed"
                            if hasattr(tts_engine, "last_error") and tts_engine.last_error:
                                error_msg += f": {tts_engine.last_error}"
                            if self.verbose:
                                print(f"   ❌ FINAL ERROR: {error_msg}")
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
                    error_msg = f"Exception: {str(e)}"
                    if self.verbose:
                        print(f"   ❌ EXCEPTION ERROR: {error_msg}")
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
                        if not deferred_safe_pass:
                            # Defer hard chapters to the end once, then retry in safe mode.
                            setattr(chapter, "_deferred_safe_pass", True)
                            chapters_list.append(chapter)
                            self.progress.complete_chapter(
                                "⏭️ Deferred to end for safe offline retry"
                            )
                            break
                        chapter_error = chapter_error or "Persistent failure"
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
                self._append_runtime_metric(
                    {
                        "event": "chapter_complete",
                        "chapter": chapter_num,
                        "engine": engine_tracker.get("label") or (config.engine or "").lower(),
                        "chars": chapter_chars,
                        "elapsed_s": round(float(elapsed), 3),
                        "success": bool(chapter_success),
                        "cached": bool(chapter_cached),
                        "attempt": chapter_attempt,
                        "error": (chapter_error or "")[:240] if chapter_error else "",
                    },
                    output_dir=output_dir,
                )
                self._persist_engine_params_after_chapter(
                    cfg=engine_config if engine_config is not None else config,
                    engine_label=engine_tracker.get("label") or (config.engine or "").lower(),
                    chapter_chars=chapter_chars,
                    elapsed_s=elapsed,
                    success=chapter_success and not chapter_cached,
                )
                if (engine_tracker.get("label") or "").lower() == "edge" and chapter_success:
                    _reset_edge_circuit()
                if chapter_success and not chapter_cached:
                    self._maybe_exit_edge_slow_mode(
                        engine_label=engine_tracker.get("label") or (config.engine or "").lower(),
                        chapter_chars=chapter_chars,
                        elapsed=elapsed,
                        engine_pool=engine_pool,
                        engine_obj=engine_instance.get("object"),
                    )
                self._mark_health_progress(chapter_num, chapter_success, elapsed, chapter_error)
                self._record_chapter_progress(
                    chapter,
                    chapter_success,
                    chapter_error,
                )
                self._save_conversion_checkpoint(
                    chapter_num, output_dir, config, success=chapter_success
                )
                if self._adaptive_checkpoint_enabled:
                    self._adaptive_checkpoint_dirty += 1
                    if self._adaptive_checkpoint_dirty >= self._adaptive_checkpoint_interval:
                        self._save_adaptive_state_checkpoint(output_dir)
                break

        success = len(errors) == 0
        if stage_pipeline_task is not None:
            stage_pipeline_task.cancel()
            with contextlib.suppress(Exception):
                await stage_pipeline_task
        if prefetch_task is not None:
            prefetch_task.cancel()
            with contextlib.suppress(Exception):
                await prefetch_task

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

        self._save_adaptive_state_checkpoint(output_dir)

        return ConversionResult(
            success=success,
            total_chapters=original_total,
            converted_chapters=len(converted_files),
            output_files=converted_files,
            errors=errors,
        )

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
                            print(f"⚠️ Chapter {index} cache INVALID: {validation_result.message}")
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
                    status_holder["text"] = "❌ text diverge do EPUB (spot-check)"
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

                # **UPDATED**: Fallback strategy and timeouts based on estimated duration
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
                            f"🔄 Fallback: removendo {lang_tag_count} tags de language"
                        )
                        self._announce_stage(index, chapter_label, status_holder["text"])
                        chapter_payload = simplified
                    except ImportError:
                        if self.verbose:
                            print(f"[DEBUG] Chapter {index} FALLBACK: LanguageMarkup not available")

                # Recompute metrics after fallback
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

                def _pre_segment_monitor(segment_text: str, _total_chars: int):
                    self._pre_segment_health_check(
                        engine_label=(config.engine or "").lower(),
                        segment_chars=len(segment_text or ""),
                        config=config,
                        engine_obj=tts_engine,
                    )

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
                                f"🔄 Tentativa 2: removendo {original_count} tags de language"
                            )
                            self._announce_stage(index, chapter_label, status_holder["text"])
                            chapter_payload = simplified_payload
                        except ImportError:
                            if self.verbose:
                                print(
                                    f"[DEBUG] Chapter {index} FALLBACK: LanguageMarkup not available"
                                )

                    try:
                        if self.verbose:
                            print(f"[DEBUG] Chapter {index} attempt {attempt}/{max_attempts}")

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
                                pre_segment_callback=_pre_segment_monitor,
                            )
                        )
                        temp_wav = await asyncio.wait_for(synthesis_task, timeout=chapter_timeout)

                        if temp_wav and (attempt == 2 or use_immediate_fallback):
                            if self.verbose:
                                print(f"[DEBUG] Chapter {index} SUCESSO no fallback!")

                    except asyncio.TimeoutError:
                        if self.verbose:
                            print(
                                f"[DEBUG] Chapter {index} attempt {attempt} timeout after {chapter_timeout}s"
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
                            print(f"[DEBUG] Chapter {index} attempt {attempt} error: {e}")
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
                                    f"⚠️ Chapter {index} validation warning: {file_result.message}"
                                )
                            if getattr(config, "strict_validate", False):
                                converted.unlink(missing_ok=True)
                                status_holder["text"] = file_result.message or "Invalid audio"
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
                                            f"⚠️ Chapter {index} validation warning: {validation_result.message}"
                                        )
                                    if getattr(config, "strict_validate", False):
                                        converted.unlink(missing_ok=True)
                                        status_holder["text"] = (
                                            validation_result.message or "Invalid duration"
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
                                            "message": validation_result.message,
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

                            status_holder["text"] = "🔍 Verificando transcription..."
                            self._announce_stage(index, chapter_label, status_holder["text"])

                            vr = self._transcription_verifier.verify_chapter(
                                converted, chapter_payload
                            )

                            if vr.passed:
                                if self.verbose:
                                    print(
                                        f"✅ Chapter {index} transcription OK: "
                                        f"{vr.similarity_score:.1%} similarity"
                                    )
                            else:
                                if getattr(vr, "partial", False):
                                    # Timeout during transcription - audio likely fine, just too large
                                    print(
                                        f"⚠️ Chapter {index} partial verification (timeout): "
                                        f"{vr.similarity_score:.1%} - mantendo MP3"
                                    )
                                else:
                                    print(
                                        f"❌ Chapter {index} transcription FAILED: "
                                        f"{vr.similarity_score:.1%} similarity (minimum {self._transcription_verifier.SIMILARITY_THRESHOLD:.0%})"
                                    )
                                    if self.verbose:
                                        print(f"   {vr.details}")
                                    # Delete bad audio and signal failure for retry
                                    converted.unlink(missing_ok=True)
                                    status_holder["text"] = (
                                        f"❌ Transcription diverges: {vr.similarity_score:.1%} similarity"
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
                                "⚠️ faster-whisper not installed, skipping transcription verification"
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
            book_title = "book_complete"
            if self._active_config:
                book_title = getattr(self._active_config, "book_title", None) or book_title

            safe_title = self.file_manager.sanitize_filename(book_title)
            full_book_file = output_dir / f"{safe_title}_complete.txt"

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
                full_text_parts.append(f"\n{'=' * 70}\n")
                full_text_parts.append(f"CHAPTER {chapter_label}: {chapter_name}\n")
                full_text_parts.append(f"{'=' * 70}\n\n")

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

            # Write complete book text (remove legacy *_completo.txt if present)
            for legacy in output_dir.glob("*_completo.txt"):
                try:
                    legacy.unlink()
                except OSError:
                    pass
            full_book_file.write_text("".join(full_text_parts), encoding="utf-8")

            if self.verbose:
                print(f"\n📖 Complete book text generated: {full_book_file.name}")
                print(f"   Total: {len(''.join(full_text_parts)):,} chars")

            return full_book_file

        except Exception as exc:
            if self.verbose:
                print(f"⚠️ Failure generating complete book text: {exc}")
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
                "❌ Conversion incompleta: um ou mais chapters failed (reexecute para recuperar)."
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
        # Always regenerate text files in output dir — removes legacy duplicate
        # variants and ensures content matches the current chapter set.
        if final_output and self._active_config and self._last_chapters_for_text:
            self._generate_all_text_files(
                self._last_chapters_for_text,
                final_output,
                self._active_config,
                cleanup_existing=True,
            )
            # Generate complete book text file
            self._generate_full_book_text(final_output, self._last_chapters_for_text)

        final_validation_ok = await self._auto_validate_output(final_output, stage="final")
        if not final_validation_ok:
            result.success = False
            validation_error = "Final validation failed: conversion is not 100% complete"
            if validation_error not in result.errors:
                result.errors.append(validation_error)
            print("❌ Final validation failed: conversion is incomplete (not 100%).")

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
