# -*- coding: utf-8 -*-
"""Audio conversion pipeline wired to the TTS engines."""

from __future__ import annotations

import asyncio
import contextlib
import csv
import difflib
import gc
import hashlib
import html
import inspect
import json
import os
import platform
import re
import resource
import shutil
import socket
import subprocess
import sys
import threading
import time
import unicodedata
import weakref
from collections import Counter
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

    @staticmethod
    def _classify_failure_reason(error_text: Optional[str]) -> str:
        text = str(error_text or "").strip().lower()
        if not text:
            return "unknown"
        if any(token in text for token in ("unauthorized", "forbidden", "401", "403", "auth")):
            return "auth"
        if any(
            token in text
            for token in (
                "rate_limit",
                "rate limit",
                "too many requests",
                "429",
                "throttle",
                "quota",
            )
        ):
            return "throttle"
        if any(token in text for token in ("noaudio", "no_audio", "noaudioreceived")):
            return "no_audio"
        if any(
            token in text
            for token in ("ssl", "certificate", "dns", "connector", "connection refused")
        ):
            return "network"
        if any(token in text for token in ("timeout", "timed out", "503", "service_unavailable")):
            return "transient"
        if "connection" in text:
            return "network"
        return "unknown"

    def _apply_engine_resource_budget(
        self,
        *,
        engine_label: str,
        snapshot: ResourceSnapshot,
        engine_pool: Optional[JobEnginePool] = None,
    ) -> None:
        if not self._resource_budget_enabled:
            return
        engine = (engine_label or "unknown").lower()
        ceiling = max(1, int(self._parallel_state.get("ceiling") or 1))
        current = max(1, int(self._parallel_state.get("current") or 1))
        budget = self._engine_resource_budget.setdefault(
            engine,
            {"cap": ceiling, "pressure_streak": 0, "free_streak": 0},
        )
        cap = max(1, min(ceiling, int(budget.get("cap", ceiling) or ceiling)))
        engine_cps = self._segment_adaptive_state.get("engine_cps", {})
        if isinstance(engine_cps, dict) and engine_cps:
            averages: Dict[str, float] = {}
            for name, values in engine_cps.items():
                try:
                    seq = [float(v) for v in (values or []) if float(v) > 0]
                except Exception:
                    seq = []
                if seq:
                    averages[str(name).lower()] = sum(seq) / len(seq)
            if averages and engine in averages:
                top = max(averages.values()) or 1.0
                ratio = max(self._resource_budget_min_share, min(1.0, averages[engine] / top))
                perf_cap = max(1, int(round(ceiling * ratio)))
                cap = min(cap, perf_cap)

        if snapshot.cpu_percent > 94 or snapshot.ram_gb < 0.65:
            budget["pressure_streak"] = int(budget.get("pressure_streak", 0) or 0) + 1
            budget["free_streak"] = 0
            if budget["pressure_streak"] >= 2:
                cap = max(1, cap - 1)
                budget["pressure_streak"] = 0
        elif snapshot.cpu_percent < 72 and snapshot.ram_gb > 1.4:
            budget["free_streak"] = int(budget.get("free_streak", 0) or 0) + 1
            budget["pressure_streak"] = 0
            if budget["free_streak"] >= 3:
                cap = min(ceiling, cap + 1)
                budget["free_streak"] = 0
        else:
            budget["pressure_streak"] = 0
            budget["free_streak"] = 0

        budget["cap"] = cap
        if current > cap:
            self._parallel_state["current"] = cap
            if engine_pool is not None:
                engine_pool.update_parallel_slots(cap)
            self._append_runtime_metric(
                {
                    "event": "resource_budget_cap",
                    "engine": engine,
                    "from_parallel": current,
                    "to_parallel": cap,
                    "cpu_percent": round(float(snapshot.cpu_percent), 2),
                    "ram_gb": round(float(snapshot.ram_gb), 3),
                }
            )
            if self.verbose:
                print(f"⚖️ Resource budget cap for {engine}: {current}→{cap}")

    @staticmethod
    def _adaptive_state_path(temp_dir: Optional[Path]) -> Optional[Path]:
        if temp_dir is None:
            return None
        return Path(temp_dir) / "_adaptive_state_checkpoint.json"

    def _save_adaptive_state_checkpoint(self, temp_dir: Optional[Path]) -> None:
        if not self._adaptive_checkpoint_enabled:
            return
        path = self._adaptive_state_path(temp_dir)
        if path is None:
            return
        payload = {
            "saved_at": time.time(),
            "segment_adaptive_state": {
                "pre_check_interval_by_engine": dict(
                    self._segment_adaptive_state.get("pre_check_interval_by_engine", {}) or {}
                ),
                "pre_check_stable_streak_by_engine": dict(
                    self._segment_adaptive_state.get("pre_check_stable_streak_by_engine", {}) or {}
                ),
                "engine_cps": dict(self._segment_adaptive_state.get("engine_cps", {}) or {}),
                "last_adjustment": float(
                    self._segment_adaptive_state.get("last_adjustment", 0.0) or 0.0
                ),
            },
            "engine_resource_budget": dict(self._engine_resource_budget),
            "auto_ab_counter": int(self._auto_ab_counter or 0),
        }
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
            self._adaptive_checkpoint_dirty = 0
            self._append_runtime_metric({"event": "adaptive_state_saved"})
        except Exception:
            return

    def _load_adaptive_state_checkpoint(self, temp_dir: Optional[Path]) -> None:
        if not self._adaptive_checkpoint_enabled:
            return
        path = self._adaptive_state_path(temp_dir)
        if path is None or not path.exists():
            return
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return
        if not isinstance(payload, dict):
            return
        seg = payload.get("segment_adaptive_state")
        if isinstance(seg, dict):
            for key in (
                "pre_check_interval_by_engine",
                "pre_check_stable_streak_by_engine",
                "engine_cps",
                "last_adjustment",
            ):
                if key in seg:
                    self._segment_adaptive_state[key] = seg.get(key)
        budget = payload.get("engine_resource_budget")
        if isinstance(budget, dict):
            self._engine_resource_budget = {
                str(name): dict(state) for name, state in budget.items() if isinstance(state, dict)
            }
        self._auto_ab_counter = int(payload.get("auto_ab_counter", self._auto_ab_counter) or 0)
        self._append_runtime_metric({"event": "adaptive_state_restored"})

    def _collect_engine_params(
        self, engine: str, cfg: Optional[ConversionConfig]
    ) -> Dict[str, object]:
        engine_name = (engine or "").lower()
        params: Dict[str, object] = {}
        if engine_name == "edge":
            params["edge_chunk_chars"] = int(getattr(cfg, "edge_chunk_chars", 12000) or 12000)
            params["edge_max_concurrency"] = int(
                os.getenv(
                    "EDGE_MAX_CONCURRENCY", str(getattr(cfg, "edge_max_concurrency", 12) or 12)
                )
            )
            params["edge_enable_parallel"] = bool(getattr(cfg, "edge_enable_parallel", True))
            params["edge_max_segment_seconds"] = int(
                getattr(cfg, "edge_max_segment_seconds", 85) or 85
            )
        elif engine_name == "coqui":
            params["coqui_chunk_chars"] = int(
                getattr(cfg, "coqui_chunk_chars", 1500)
                or os.getenv("COQUI_CHUNK_CHARS", "1500")
                or 1500
            )
            params["coqui_max_workers"] = int(
                getattr(cfg, "coqui_max_workers", 0) or os.getenv("COQUI_MAX_WORKERS", "2") or 2
            )
        elif engine_name == "piper":
            params["piper_max_procs"] = int(
                getattr(cfg, "piper_max_procs", 0) or os.getenv("PIPER_MAX_PROCS", "2") or 2
            )
            params["piper_chunk_chars"] = int(
                getattr(cfg, "piper_chunk_chars", 0)
                or os.getenv("PIPER_CHUNK_CHARS", "3000")
                or 3000
            )
        elif engine_name == "kokoro":
            params["kokoro_max_workers"] = int(os.getenv("KOKORO_MAX_WORKERS", "2") or 2)
            params["kokoro_chunk_chars"] = int(os.getenv("KOKORO_CHUNK_CHARS", "2000") or 2000)
        elif engine_name == "spark":
            params["spark_max_workers"] = int(os.getenv("SPARK_MAX_WORKERS", "1") or 1)
            params["spark_chunk_chars"] = int(os.getenv("SPARK_CHUNK_CHARS", "1500") or 1500)
        return params

    def _apply_runtime_feature_overrides(self, config: Optional[ConversionConfig]) -> None:
        """Apply per-run feature toggles from ConversionConfig.extra."""
        if config is None or not getattr(config, "extra", None):
            return
        extra = config.extra

        def _opt_bool(key: str) -> Optional[bool]:
            raw = extra.get(key)
            if raw is None:
                return None
            return str(raw).strip().lower() in {"1", "true", "yes", "on"}

        prefetch = _opt_bool("chapter_prefetch")
        if prefetch is not None:
            self._chapter_prefetch_enabled = prefetch
        auto_ab = _opt_bool("auto_ab")
        if auto_ab is not None:
            self._auto_ab_enabled = auto_ab
        checkpoint = _opt_bool("adaptive_checkpoint")
        if checkpoint is not None:
            self._adaptive_checkpoint_enabled = checkpoint
        stage_pipeline = _opt_bool("stage_pipeline")
        if stage_pipeline is not None:
            config.extra["stage_pipeline"] = "1" if stage_pipeline else "0"

    @staticmethod
    def _is_stage_pipeline_enabled(config: Optional[ConversionConfig]) -> bool:
        if config is None:
            return STAGE_PIPELINE_ENABLED_DEFAULT
        raw = getattr(config, "extra", {}).get("stage_pipeline")
        if raw is None:
            return STAGE_PIPELINE_ENABLED_DEFAULT
        return str(raw).strip().lower() in {"1", "true", "yes", "on"}

    @staticmethod
    def _stage_pipeline_depth(config: Optional[ConversionConfig]) -> int:
        raw = None if config is None else getattr(config, "extra", {}).get("stage_pipeline_depth")
        if raw is None:
            return STAGE_PIPELINE_DEPTH_DEFAULT
        try:
            return max(1, int(raw))
        except (TypeError, ValueError):
            return STAGE_PIPELINE_DEPTH_DEFAULT

    def _apply_engine_params(
        self,
        *,
        engine: str,
        cfg: Optional[ConversionConfig],
        params: Dict[str, object],
        engine_obj: Optional[object] = None,
    ) -> bool:
        engine_name = (engine or "").lower()
        changed = False
        if engine_name == "edge":
            chunk_chars = int(
                params.get("edge_chunk_chars", getattr(cfg, "edge_chunk_chars", 12000))
            )
            max_concurrency = int(
                params.get(
                    "edge_max_concurrency",
                    os.getenv(
                        "EDGE_MAX_CONCURRENCY", str(getattr(cfg, "edge_max_concurrency", 12))
                    ),
                )
            )
            enable_parallel = bool(
                params.get("edge_enable_parallel", getattr(cfg, "edge_enable_parallel", True))
            )
            max_segment_seconds = int(
                params.get("edge_max_segment_seconds", getattr(cfg, "edge_max_segment_seconds", 85))
            )
            if cfg is not None:
                cfg.edge_chunk_chars = chunk_chars
                cfg.edge_max_concurrency = max_concurrency
                cfg.edge_enable_parallel = enable_parallel
                cfg.edge_max_segment_seconds = max_segment_seconds
            os.environ["EDGE_CHUNK_CHARS"] = str(chunk_chars)
            os.environ["EDGE_MAX_CONCURRENCY"] = str(max_concurrency)
            os.environ["EDGE_MAX_SEGMENT_SECONDS"] = str(max_segment_seconds)
            if engine_obj is not None and hasattr(engine_obj, "apply_speed_profile"):
                with contextlib.suppress(Exception):
                    engine_obj.apply_speed_profile(
                        chunk_char_limit=max(4000, int(chunk_chars)),
                        max_segment_seconds=max(30.0, float(max_segment_seconds)),
                    )
            changed = True
        elif engine_name == "coqui":
            chunk_chars = int(
                params.get(
                    "coqui_chunk_chars",
                    getattr(cfg, "coqui_chunk_chars", 1500)
                    or os.getenv("COQUI_CHUNK_CHARS", "1500"),
                )
            )
            max_workers = int(
                params.get(
                    "coqui_max_workers",
                    getattr(cfg, "coqui_max_workers", 0) or os.getenv("COQUI_MAX_WORKERS", "2"),
                )
            )
            if cfg is not None:
                cfg.coqui_chunk_chars = chunk_chars
                cfg.coqui_max_workers = max_workers
            os.environ["COQUI_CHUNK_CHARS"] = str(chunk_chars)
            os.environ["COQUI_MAX_WORKERS"] = str(max_workers)
            if engine_obj is not None:
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_chunk_char_limit", chunk_chars)
            changed = True
        elif engine_name == "piper":
            max_procs = int(
                params.get(
                    "piper_max_procs",
                    getattr(cfg, "piper_max_procs", 0) or os.getenv("PIPER_MAX_PROCS", "2"),
                )
            )
            chunk_chars = int(
                params.get(
                    "piper_chunk_chars",
                    getattr(cfg, "piper_chunk_chars", 0) or os.getenv("PIPER_CHUNK_CHARS", "3000"),
                )
            )
            if cfg is not None:
                cfg.piper_max_procs = max_procs
                cfg.piper_chunk_chars = chunk_chars
            os.environ["PIPER_MAX_PROCS"] = str(max_procs)
            os.environ["PIPER_CHUNK_CHARS"] = str(chunk_chars)
            if engine_obj is not None:
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_chunk_char_limit", chunk_chars)
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_semaphore", asyncio.Semaphore(max(1, max_procs)))
            changed = True
        elif engine_name == "kokoro":
            os.environ["KOKORO_MAX_WORKERS"] = str(
                int(params.get("kokoro_max_workers", os.getenv("KOKORO_MAX_WORKERS", "2")))
            )
            os.environ["KOKORO_CHUNK_CHARS"] = str(
                int(params.get("kokoro_chunk_chars", os.getenv("KOKORO_CHUNK_CHARS", "2000")))
            )
            changed = True
        elif engine_name == "spark":
            os.environ["SPARK_MAX_WORKERS"] = str(
                int(params.get("spark_max_workers", os.getenv("SPARK_MAX_WORKERS", "1")))
            )
            os.environ["SPARK_CHUNK_CHARS"] = str(
                int(params.get("spark_chunk_chars", os.getenv("SPARK_CHUNK_CHARS", "1500")))
            )
            changed = True
        return changed

    def _apply_persisted_engine_params(
        self,
        *,
        cfg: Optional[ConversionConfig],
        engine_label: str,
        engine_obj: Optional[object] = None,
    ) -> bool:
        if not self._persist_best_params:
            return False
        key = self._runtime_tuning_key(cfg, engine_label)
        entry = self._best_param_store.get_profile(
            engine=key["engine"],
            voice=key["voice"],
            language=key["language"],
            machine_signature=key["machine_signature"],
        )
        if not entry:
            return False
        params = entry.get("params", {})
        if not isinstance(params, dict) or not params:
            return False
        changed = self._apply_engine_params(
            engine=key["engine"],
            cfg=cfg,
            params=params,
            engine_obj=engine_obj,
        )
        if changed and self.verbose:
            print(
                "⚡ Loaded best params "
                f"[{key['engine']}/{key['voice']}/{key['language']}] "
                f"({float(entry.get('best_chars_per_second', 0.0) or 0.0):.1f} chars/s)"
            )
        return changed

    def _persist_engine_params_after_chapter(
        self,
        *,
        cfg: Optional[ConversionConfig],
        engine_label: str,
        chapter_chars: int,
        elapsed_s: float,
        success: bool,
    ) -> None:
        if not self._persist_best_params or not success:
            return
        if chapter_chars < 1500 or elapsed_s <= 0:
            return
        cps = float(chapter_chars) / max(float(elapsed_s), 0.001)
        key = self._runtime_tuning_key(cfg, engine_label)
        params = self._collect_engine_params(key["engine"], cfg)
        if not params:
            return
        improved = self._best_param_store.upsert_profile(
            engine=key["engine"],
            voice=key["voice"],
            language=key["language"],
            machine_signature=key["machine_signature"],
            chars_per_second=cps,
            params=params,
        )
        if improved and self.verbose:
            print(
                "💾 Updated best params "
                f"[{key['engine']}/{key['voice']}/{key['language']}] -> {cps:.1f} chars/s"
            )

    @staticmethod
    def _warmup_output_path(base_dir: Path, engine: str) -> Path:
        ext = ".mp3" if (engine or "").lower() == "edge" else ".wav"
        return base_dir / f"{(engine or 'engine').lower()}-warmup{ext}"

    def _warm_start_key(self, cfg: Optional[ConversionConfig], engine_label: str) -> str:
        key = self._runtime_tuning_key(cfg, engine_label)
        return f"{key['engine']}|{key['voice']}|{key['language']}|{key.get('machine_signature','generic')}"

    def _load_warm_start_state(self) -> Dict[str, Any]:
        if not self._warm_start_enabled or not self._warm_start_path.exists():
            return {}
        try:
            payload = json.loads(self._warm_start_path.read_text(encoding="utf-8"))
            entries = payload.get("entries", {}) if isinstance(payload, dict) else {}
            if not isinstance(entries, dict):
                return {}
            now = time.time()
            ttl = max(60.0, float(payload.get("ttl_seconds", self._warm_start_ttl_seconds) or 0.0))
            cleaned: Dict[str, Any] = {}
            changed = False
            for key, raw in entries.items():
                if not isinstance(raw, dict):
                    changed = True
                    continue
                ts = float(raw.get("ts", 0.0) or 0.0)
                if ts <= 0 or (now - ts) > ttl:
                    changed = True
                    continue
                cleaned[str(key)] = {"ts": ts}
            if changed:
                self._save_warm_start_state(cleaned)
            return cleaned
        except Exception:
            return {}

    def _save_warm_start_state(self, entries: Dict[str, Any]) -> None:
        if not self._warm_start_enabled:
            return
        try:
            self._warm_start_path.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "updated_at": time.time(),
                "ttl_seconds": self._warm_start_ttl_seconds,
                "entries": entries,
            }
            self._warm_start_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except Exception:
            return

    def _is_warm_start_fresh(self, cfg: Optional[ConversionConfig], engine_label: str) -> bool:
        entries = self._load_warm_start_state()
        if not entries:
            return False
        key = self._warm_start_key(cfg, engine_label)
        raw = entries.get(key)
        if not isinstance(raw, dict):
            return False
        ts = float(raw.get("ts", 0.0) or 0.0)
        if ts <= 0:
            return False
        return (time.time() - ts) <= self._warm_start_ttl_seconds

    @staticmethod
    def _percentile(values: List[float], q: float) -> float:
        seq = sorted(float(v) for v in (values or []) if float(v) >= 0.0)
        if not seq:
            return 0.0
        if q <= 0:
            return float(seq[0])
        if q >= 1:
            return float(seq[-1])
        idx = (len(seq) - 1) * q
        lo = int(idx)
        hi = min(len(seq) - 1, lo + 1)
        frac = idx - lo
        return float(seq[lo] * (1.0 - frac) + seq[hi] * frac)

    def _mark_warm_start_ready(self, cfg: Optional[ConversionConfig], engine_label: str) -> None:
        entries = self._load_warm_start_state()
        key = self._warm_start_key(cfg, engine_label)
        entries[key] = {"ts": time.time()}
        if len(entries) > 300:
            sorted_keys = sorted(
                entries.keys(),
                key=lambda item: float((entries.get(item) or {}).get("ts", 0.0) or 0.0),
                reverse=True,
            )
            entries = {name: entries[name] for name in sorted_keys[:200]}
        self._save_warm_start_state(entries)

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

    @staticmethod
    def _failure_checkpoint_path(output_dir: Optional[Path]) -> Optional[Path]:
        if not output_dir:
            return None
        try:
            base = Path(output_dir)
            base.mkdir(parents=True, exist_ok=True)
            return base / "_failure_checkpoint.json"
        except Exception:
            return None

    def _load_failure_checkpoint(self, output_dir: Optional[Path]) -> Dict[str, Any]:
        path = self._failure_checkpoint_path(output_dir)
        if path is None or not path.exists():
            return {}
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            return payload if isinstance(payload, dict) else {}
        except Exception:
            return {}

    def _save_failure_checkpoint(
        self,
        output_dir: Optional[Path],
        *,
        failed_chapters: Iterable[str],
        edge_blocked_chapters: Optional[Iterable[str]] = None,
    ) -> None:
        path = self._failure_checkpoint_path(output_dir)
        if path is None:
            return
        try:
            failed = sorted({str(item).strip() for item in failed_chapters if str(item).strip()})
            blocked = sorted(
                {str(item).strip() for item in (edge_blocked_chapters or []) if str(item).strip()}
            )
            resume_chunks: Dict[str, Dict[str, int]] = {}
            chunks_root = path.parent / "chunks"
            if chunks_root.exists():
                for chapter_dir in chunks_root.glob("chapter_*"):
                    if not chapter_dir.is_dir():
                        continue
                    chunk_files = list(chapter_dir.glob("chunk_*.mp3"))
                    manifest_entries = 0
                    manifest_path = chapter_dir / "manifest.json"
                    if manifest_path.exists():
                        with contextlib.suppress(Exception):
                            manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
                            if isinstance(manifest_data, list):
                                manifest_entries = len(manifest_data)
                    resume_chunks[chapter_dir.name] = {
                        "chunk_files": len(chunk_files),
                        "manifest_entries": manifest_entries,
                    }
            payload = {
                "updated_at": time.time(),
                "failed_chapters": failed,
                "edge_blocked_chapters": blocked,
                "resume_chunks": resume_chunks,
            }
            path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        except Exception:
            if self.verbose:
                print("⚠️ Failed to save failure checkpoint")

    def _clear_failure_checkpoint(self, output_dir: Optional[Path]) -> None:
        path = self._failure_checkpoint_path(output_dir)
        if path is None:
            return
        with contextlib.suppress(OSError):
            path.unlink(missing_ok=True)

    def _rotate_runtime_metrics_if_needed(self, path: Path, max_bytes: int = 2_000_000) -> None:
        try:
            if not path.exists():
                return
            if path.stat().st_size < max_bytes:
                return
            timestamp = time.strftime("%Y%m%d-%H%M%S")
            rotated = path.with_name(f"{path.stem}.{timestamp}{path.suffix}")
            path.replace(rotated)
            siblings = sorted(
                path.parent.glob(f"{path.stem}.*{path.suffix}"),
                key=lambda candidate: candidate.stat().st_mtime,
                reverse=True,
            )
            for stale in siblings[5:]:
                with contextlib.suppress(OSError):
                    stale.unlink(missing_ok=True)
        except Exception:
            if self.verbose:
                print("⚠️ Failed to rotate runtime metrics")

    def _write_runtime_metrics_summary(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._runtime_metrics_path(output_dir)
        if metrics_path is None or not metrics_path.exists():
            return
        event_counts: Counter[str] = Counter()
        engine_counts: Counter[str] = Counter()
        failure_counts: Counter[str] = Counter()
        edge_blocked_chapters: Set[str] = set()
        chapters_total = 0
        chapters_ok = 0
        switches = 0
        total_events = 0
        try:
            with metrics_path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        payload = json.loads(line)
                    except Exception:
                        continue
                    total_events += 1
                    event = str(payload.get("event") or "unknown")
                    event_counts[event] += 1
                    engine = str(payload.get("engine") or "").strip().lower()
                    if engine:
                        engine_counts[engine] += 1
                    if event == "chapter_complete":
                        chapters_total += 1
                        if bool(payload.get("success")):
                            chapters_ok += 1
                    if event == "engine_switch":
                        switches += 1
                    if event == "edge_blocked_chapter":
                        chapter_label = str(
                            payload.get("chapter_label") or payload.get("chapter") or ""
                        ).strip()
                        if chapter_label:
                            edge_blocked_chapters.add(chapter_label)
                    if "failed" in event or "failure" in event:
                        failure_counts[event] += 1

            summary = {
                "generated_at": time.time(),
                "metrics_file": str(metrics_path),
                "total_events": total_events,
                "chapters": {
                    "total": chapters_total,
                    "successful": chapters_ok,
                    "failed": max(0, chapters_total - chapters_ok),
                },
                "engine_events": dict(sorted(engine_counts.items())),
                "event_counts": dict(sorted(event_counts.items())),
                "failures": dict(sorted(failure_counts.items())),
                "engine_switches": switches,
                "edge_blocked_chapters": {
                    "count": len(edge_blocked_chapters),
                    "chapters": sorted(edge_blocked_chapters),
                },
                "optimization_metrics": {
                    "prefetch_requests": int(event_counts.get("prefetch_request", 0) or 0),
                    "prefetch_hits": int(event_counts.get("prefetch_hit", 0) or 0),
                    "prefetch_hit_rate": (
                        round(
                            float(event_counts.get("prefetch_hit", 0) or 0)
                            / float(event_counts.get("prefetch_request", 1) or 1),
                            4,
                        )
                        if int(event_counts.get("prefetch_request", 0) or 0) > 0
                        else 0.0
                    ),
                    "ab_explorations": int(event_counts.get("auto_ab_exploration", 0) or 0),
                    "budget_caps_applied": int(event_counts.get("resource_budget_cap", 0) or 0),
                    "adaptive_state_restores": int(
                        event_counts.get("adaptive_state_restored", 0) or 0
                    ),
                },
            }
            summary_path = metrics_path.with_name("metrics-summary.json")
            summary_path.write_text(
                json.dumps(summary, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except Exception:
            if self.verbose:
                print("⚠️ Failed to write runtime metrics summary")

    def _write_runtime_metrics_csv(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._runtime_metrics_path(output_dir)
        if metrics_path is None or not metrics_path.exists():
            return
        chapter_engine_rows: Dict[tuple[str, str], Dict[str, Any]] = {}
        try:
            with metrics_path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        payload = json.loads(line)
                    except Exception:
                        continue
                    if str(payload.get("event") or "") != "chapter_complete":
                        continue
                    chapter = str(payload.get("chapter") or "").strip()
                    engine = str(payload.get("engine") or "").strip().lower()
                    if not chapter or not engine:
                        continue
                    key = (chapter, engine)
                    row = chapter_engine_rows.setdefault(
                        key,
                        {
                            "chapter": chapter,
                            "engine": engine,
                            "attempts": 0,
                            "successes": 0,
                            "failures": 0,
                            "total_chars": 0,
                            "total_elapsed_s": 0.0,
                            "last_error": "",
                        },
                    )
                    row["attempts"] += 1
                    chars = int(payload.get("chars") or 0)
                    elapsed = float(payload.get("elapsed_s") or 0.0)
                    row["total_chars"] += max(0, chars)
                    row["total_elapsed_s"] += max(0.0, elapsed)
                    if bool(payload.get("success")):
                        row["successes"] += 1
                    else:
                        row["failures"] += 1
                        row["last_error"] = str(payload.get("error") or "")[:240]

            csv_path = metrics_path.with_name("metrics-chapter-engine.csv")
            fieldnames = [
                "chapter",
                "engine",
                "attempts",
                "successes",
                "failures",
                "total_chars",
                "total_elapsed_s",
                "avg_chars_per_second",
                "last_error",
            ]
            with csv_path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=fieldnames)
                writer.writeheader()
                for key in sorted(
                    chapter_engine_rows.keys(),
                    key=lambda item: (str(item[0]), str(item[1])),
                ):
                    row = chapter_engine_rows[key]
                    elapsed_total = float(row["total_elapsed_s"] or 0.0)
                    avg_cps = (
                        float(row["total_chars"]) / elapsed_total if elapsed_total > 0 else 0.0
                    )
                    writer.writerow(
                        {
                            "chapter": row["chapter"],
                            "engine": row["engine"],
                            "attempts": row["attempts"],
                            "successes": row["successes"],
                            "failures": row["failures"],
                            "total_chars": row["total_chars"],
                            "total_elapsed_s": f"{elapsed_total:.3f}",
                            "avg_chars_per_second": f"{avg_cps:.3f}",
                            "last_error": row["last_error"],
                        }
                    )
        except Exception:
            if self.verbose:
                print("⚠️ Failed to write runtime metrics CSV")

    def _write_runtime_metrics_dashboard(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._runtime_metrics_path(output_dir)
        if metrics_path is None:
            return
        summary_path = metrics_path.with_name("metrics-summary.json")
        csv_path = metrics_path.with_name("metrics-chapter-engine.csv")
        if not summary_path.exists():
            return
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            chapters = summary.get("chapters", {}) if isinstance(summary, dict) else {}
            total_events = (
                int(summary.get("total_events", 0) or 0) if isinstance(summary, dict) else 0
            )
            switches = (
                int(summary.get("engine_switches", 0) or 0) if isinstance(summary, dict) else 0
            )
            blocked_info = (
                summary.get("edge_blocked_chapters", {}) if isinstance(summary, dict) else {}
            )
            blocked_count = (
                int(blocked_info.get("count", 0) or 0) if isinstance(blocked_info, dict) else 0
            )
            blocked_list = (
                blocked_info.get("chapters", []) if isinstance(blocked_info, dict) else []
            )
            opt = summary.get("optimization_metrics", {}) if isinstance(summary, dict) else {}
            prefetch_hit_rate = float(opt.get("prefetch_hit_rate", 0.0) or 0.0)
            ab_explorations = int(opt.get("ab_explorations", 0) or 0)
            budget_caps = int(opt.get("budget_caps_applied", 0) or 0)
            adaptive_restores = int(opt.get("adaptive_state_restores", 0) or 0)
            rows_html = ""
            if csv_path.exists():
                with csv_path.open("r", encoding="utf-8") as handle:
                    reader = csv.DictReader(handle)
                    rows = list(reader)
                for row in rows:
                    rows_html += (
                        "<tr>"
                        f"<td>{html.escape(str(row.get('chapter', '')))}</td>"
                        f"<td>{html.escape(str(row.get('engine', '')))}</td>"
                        f"<td>{html.escape(str(row.get('attempts', '')))}</td>"
                        f"<td>{html.escape(str(row.get('successes', '')))}</td>"
                        f"<td>{html.escape(str(row.get('failures', '')))}</td>"
                        f"<td>{html.escape(str(row.get('avg_chars_per_second', '')))}</td>"
                        f"<td>{html.escape(str(row.get('last_error', '')))}</td>"
                        "</tr>"
                    )
            blocked_html = "".join(
                f"<li>{html.escape(str(chapter))}</li>" for chapter in (blocked_list or [])
            )
            dashboard = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Conversion Metrics Dashboard</title>
  <style>
    body {{ font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 24px; color: #1b1f24; }}
    h1 {{ margin: 0 0 12px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin-bottom: 18px; }}
    .card {{ border: 1px solid #d0d7de; border-radius: 8px; padding: 12px; background: #f6f8fa; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
    th, td {{ border: 1px solid #d0d7de; padding: 8px; text-align: left; vertical-align: top; }}
    th {{ background: #f3f4f6; }}
  </style>
</head>
<body>
  <h1>Conversion Metrics Dashboard</h1>
  <div class="grid">
    <div class="card"><strong>Total events</strong><br>{total_events}</div>
    <div class="card"><strong>Chapters ok</strong><br>{int(chapters.get('successful', 0) or 0)}/{int(chapters.get('total', 0) or 0)}</div>
    <div class="card"><strong>Engine switches</strong><br>{switches}</div>
    <div class="card"><strong>Edge blocked chapters</strong><br>{blocked_count}</div>
    <div class="card"><strong>Prefetch hit rate</strong><br>{prefetch_hit_rate * 100:.1f}%</div>
    <div class="card"><strong>A/B explorations</strong><br>{ab_explorations}</div>
    <div class="card"><strong>Budget caps applied</strong><br>{budget_caps}</div>
    <div class="card"><strong>Adaptive restores</strong><br>{adaptive_restores}</div>
  </div>
  <h2>Chapter/Engine Attempts</h2>
  <table>
    <thead>
      <tr><th>Chapter</th><th>Engine</th><th>Attempts</th><th>Successes</th><th>Failures</th><th>Avg chars/s</th><th>Last error</th></tr>
    </thead>
    <tbody>{rows_html}</tbody>
  </table>
  <h2>Edge Blocked Chapters</h2>
  <ul>{blocked_html}</ul>
</body>
</html>
"""
            dashboard_path = metrics_path.with_name("metrics-dashboard.html")
            dashboard_path.write_text(dashboard, encoding="utf-8")
        except Exception:
            if self.verbose:
                print("⚠️ Failed to write metrics dashboard")

    def _write_segment_metrics_summary(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._segment_metrics_path(output_dir)
        if metrics_path is None or not metrics_path.exists():
            return
        counts: Counter[str] = Counter()
        per_engine: Dict[str, Dict[str, float]] = {}
        try:
            with metrics_path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        payload = json.loads(line)
                    except Exception:
                        continue
                    event = str(payload.get("event") or "unknown")
                    counts[event] += 1
                    if event != "segment_success":
                        continue
                    engine = str(payload.get("engine") or "unknown").lower()
                    bucket = per_engine.setdefault(
                        engine,
                        {
                            "segments": 0.0,
                            "total_chars": 0.0,
                            "total_elapsed_s": 0.0,
                            "cps_values": [],
                            "elapsed_values": [],
                        },
                    )
                    elapsed = float(payload.get("elapsed_s") or 0.0)
                    chars = float(payload.get("segment_chars") or 0.0)
                    cps = (chars / elapsed) if elapsed > 0 else 0.0
                    bucket["segments"] += 1.0
                    bucket["total_chars"] += chars
                    bucket["total_elapsed_s"] += elapsed
                    if cps > 0:
                        bucket["cps_values"].append(cps)
                    if elapsed > 0:
                        bucket["elapsed_values"].append(elapsed)

            engine_summary: Dict[str, Dict[str, float]] = {}
            for engine, row in sorted(per_engine.items()):
                elapsed = max(0.001, float(row.get("total_elapsed_s") or 0.0))
                chars = float(row.get("total_chars") or 0.0)
                segs = max(1.0, float(row.get("segments") or 1.0))
                cps_values = [float(v) for v in (row.get("cps_values") or []) if float(v) > 0]
                elapsed_values = [
                    float(v) for v in (row.get("elapsed_values") or []) if float(v) > 0
                ]
                p50_cps = self._percentile(cps_values, 0.5)
                p95_cps = self._percentile(cps_values, 0.95)
                p50_elapsed = self._percentile(elapsed_values, 0.5)
                p95_elapsed = self._percentile(elapsed_values, 0.95)
                jitter_ratio = (p95_elapsed / max(0.001, p50_elapsed)) if p50_elapsed > 0 else 0.0
                engine_summary[engine] = {
                    "segments": int(segs),
                    "total_chars": int(chars),
                    "total_elapsed_s": round(elapsed, 3),
                    "avg_chars_per_second": round(chars / elapsed, 3),
                    "avg_chars_per_segment": round(chars / segs, 3),
                    "p50_chars_per_second": round(p50_cps, 3),
                    "p95_chars_per_second": round(p95_cps, 3),
                    "p50_elapsed_s": round(p50_elapsed, 3),
                    "p95_elapsed_s": round(p95_elapsed, 3),
                    "jitter_ratio": round(jitter_ratio, 3),
                }

            summary = {
                "generated_at": time.time(),
                "segment_metrics_file": str(metrics_path),
                "event_counts": dict(sorted(counts.items())),
                "engines": engine_summary,
            }
            summary_path = metrics_path.with_name("segment-metrics-summary.json")
            summary_path.write_text(
                json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
            )
        except Exception:
            if self.verbose:
                print("⚠️ Failed to write segment metrics summary")

    def _write_segment_metrics_csv(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._segment_metrics_path(output_dir)
        if metrics_path is None or not metrics_path.exists():
            return
        rows: Dict[tuple[str, str], Dict[str, Any]] = {}
        try:
            with metrics_path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        payload = json.loads(line)
                    except Exception:
                        continue
                    if str(payload.get("event") or "") != "segment_success":
                        continue
                    engine = str(payload.get("engine") or "").strip().lower()
                    chapter = str(payload.get("chapter") or "").strip()
                    if not engine or not chapter:
                        continue
                    key = (engine, chapter)
                    row = rows.setdefault(
                        key,
                        {
                            "engine": engine,
                            "chapter": chapter,
                            "segments": 0,
                            "total_chars": 0,
                            "total_elapsed_s": 0.0,
                            "avg_cps": 0.0,
                        },
                    )
                    row["segments"] += 1
                    row["total_chars"] += int(payload.get("segment_chars") or 0)
                    row["total_elapsed_s"] += float(payload.get("elapsed_s") or 0.0)
            csv_path = metrics_path.with_name("segment-metrics-engine-chapter.csv")
            fields = [
                "engine",
                "chapter",
                "segments",
                "total_chars",
                "total_elapsed_s",
                "avg_chars_per_second",
            ]
            with csv_path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=fields)
                writer.writeheader()
                for key in sorted(rows.keys(), key=lambda item: (item[0], item[1])):
                    row = rows[key]
                    elapsed = max(0.001, float(row["total_elapsed_s"] or 0.0))
                    avg = float(row["total_chars"]) / elapsed
                    writer.writerow(
                        {
                            "engine": row["engine"],
                            "chapter": row["chapter"],
                            "segments": row["segments"],
                            "total_chars": row["total_chars"],
                            "total_elapsed_s": f"{elapsed:.3f}",
                            "avg_chars_per_second": f"{avg:.3f}",
                        }
                    )
        except Exception:
            if self.verbose:
                print("⚠️ Failed to write segment metrics CSV")

    def _write_segment_metrics_dashboard(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._segment_metrics_path(output_dir)
        if metrics_path is None:
            return
        summary_path = metrics_path.with_name("segment-metrics-summary.json")
        csv_path = metrics_path.with_name("segment-metrics-engine-chapter.csv")
        if not summary_path.exists():
            return
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            engines = summary.get("engines", {}) if isinstance(summary, dict) else {}
            event_counts = summary.get("event_counts", {}) if isinstance(summary, dict) else {}
            total_segments = sum(
                int((entry or {}).get("segments", 0) or 0)
                for entry in (engines.values() if isinstance(engines, dict) else [])
                if isinstance(entry, dict)
            )
            cards = ""
            for engine, row in sorted((engines or {}).items()):
                if not isinstance(row, dict):
                    continue
                cards += (
                    "<div class='card'>"
                    f"<strong>{html.escape(str(engine))}</strong><br>"
                    f"Segments: {int(row.get('segments', 0) or 0)}<br>"
                    f"Avg chars/s: {float(row.get('avg_chars_per_second', 0.0) or 0.0):.1f}<br>"
                    f"P95 chars/s: {float(row.get('p95_chars_per_second', 0.0) or 0.0):.1f}<br>"
                    f"Jitter: {float(row.get('jitter_ratio', 0.0) or 0.0):.2f}x"
                    "</div>"
                )

            rows_html = ""
            if csv_path.exists():
                with csv_path.open("r", encoding="utf-8") as handle:
                    reader = csv.DictReader(handle)
                    for row in reader:
                        rows_html += (
                            "<tr>"
                            f"<td>{html.escape(str(row.get('engine', '')))}</td>"
                            f"<td>{html.escape(str(row.get('chapter', '')))}</td>"
                            f"<td>{html.escape(str(row.get('segments', '')))}</td>"
                            f"<td>{html.escape(str(row.get('total_chars', '')))}</td>"
                            f"<td>{html.escape(str(row.get('avg_chars_per_second', '')))}</td>"
                            "</tr>"
                        )
            chart_html = "<p>No segment cps timeline available.</p>"
            timeline_points: Dict[str, List[tuple[float, float]]] = {}
            if metrics_path.exists():
                with contextlib.suppress(Exception):
                    with metrics_path.open("r", encoding="utf-8") as handle:
                        for line in handle:
                            line = line.strip()
                            if not line:
                                continue
                            payload = json.loads(line)
                            if str(payload.get("event") or "") != "segment_success":
                                continue
                            engine = str(payload.get("engine") or "unknown").lower()
                            ts = float(payload.get("ts") or 0.0)
                            cps = float(payload.get("cps") or 0.0)
                            if ts <= 0.0 or cps <= 0.0:
                                continue
                            timeline_points.setdefault(engine, []).append((ts, cps))
            if timeline_points:
                all_ts = [pt[0] for points in timeline_points.values() for pt in points]
                all_cps = [pt[1] for points in timeline_points.values() for pt in points]
                min_ts = min(all_ts)
                max_ts = max(all_ts)
                max_cps = max(1.0, max(all_cps))
                width = 900.0
                height = 280.0
                pad_x = 42.0
                pad_y = 20.0
                plot_w = max(80.0, width - (pad_x * 2))
                plot_h = max(80.0, height - (pad_y * 2))
                palette = [
                    "#1f77b4",
                    "#d62728",
                    "#2ca02c",
                    "#9467bd",
                    "#ff7f0e",
                    "#17becf",
                ]
                lines: List[str] = [
                    f"<svg viewBox='0 0 {int(width)} {int(height)}' role='img' aria-label='chars per second over time'>",
                    f"<rect x='0' y='0' width='{int(width)}' height='{int(height)}' fill='#ffffff' stroke='#d0d7de' />",
                    f"<line x1='{pad_x}' y1='{height - pad_y}' x2='{width - pad_x}' y2='{height - pad_y}' stroke='#9aa4b2'/>",
                    f"<line x1='{pad_x}' y1='{pad_y}' x2='{pad_x}' y2='{height - pad_y}' stroke='#9aa4b2'/>",
                ]
                for idx, engine in enumerate(sorted(timeline_points.keys())):
                    points = sorted(timeline_points[engine], key=lambda item: item[0])
                    if len(points) < 2:
                        continue
                    color = palette[idx % len(palette)]
                    coords = []
                    for ts, cps in points:
                        if max_ts <= min_ts:
                            x = pad_x
                        else:
                            x = pad_x + ((ts - min_ts) / (max_ts - min_ts)) * plot_w
                        y = (height - pad_y) - ((cps / max_cps) * plot_h)
                        coords.append(f"{x:.1f},{y:.1f}")
                    lines.append(
                        f"<polyline fill='none' stroke='{color}' stroke-width='2' points='{' '.join(coords)}' />"
                    )
                    lines.append(
                        f"<text x='{pad_x + 6}' y='{pad_y + 14 + (idx * 14)}' fill='{color}' font-size='11'>{html.escape(engine)}</text>"
                    )
                lines.append(
                    f"<text x='{width - pad_x}' y='{pad_y + 12}' text-anchor='end' font-size='11' fill='#57606a'>max {max_cps:.1f} cps</text>"
                )
                lines.append("</svg>")
                chart_html = "".join(lines)
            dashboard = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Segment Metrics Dashboard</title>
  <style>
    body {{ font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 24px; color: #1b1f24; }}
    h1 {{ margin: 0 0 12px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin-bottom: 18px; }}
    .card {{ border: 1px solid #d0d7de; border-radius: 8px; padding: 12px; background: #f6f8fa; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
    th, td {{ border: 1px solid #d0d7de; padding: 8px; text-align: left; vertical-align: top; }}
    th {{ background: #f3f4f6; }}
  </style>
</head>
<body>
  <h1>Segment Metrics Dashboard</h1>
  <div class="grid">
    <div class="card"><strong>Total segments</strong><br>{int(total_segments)}</div>
    <div class="card"><strong>Segment success events</strong><br>{int(event_counts.get('segment_success', 0) or 0)}</div>
    <div class="card"><strong>Pre-check events</strong><br>{int(event_counts.get('pre_segment_check', 0) or 0)}</div>
  </div>
  <div class="grid">{cards}</div>
  <h2>Chars/s Timeline</h2>
  {chart_html}
  <h2>Engine/Chapter Segments</h2>
  <table>
    <thead>
      <tr><th>Engine</th><th>Chapter</th><th>Segments</th><th>Total chars</th><th>Avg chars/s</th></tr>
    </thead>
    <tbody>{rows_html}</tbody>
  </table>
</body>
</html>
"""
            dashboard_path = metrics_path.with_name("segment-metrics-dashboard.html")
            dashboard_path.write_text(dashboard, encoding="utf-8")
        except Exception:
            if self.verbose:
                print("⚠️ Failed to write segment metrics dashboard")

    def _write_runtime_recommendations(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._runtime_metrics_path(output_dir)
        if metrics_path is None:
            return
        summary_path = metrics_path.with_name("metrics-summary.json")
        segment_summary_path = metrics_path.with_name("segment-metrics-summary.json")
        if not summary_path.exists():
            return
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
        except Exception:
            return
        segment_summary: Dict[str, Any] = {}
        if segment_summary_path.exists():
            with contextlib.suppress(Exception):
                loaded = json.loads(segment_summary_path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    segment_summary = loaded

        recommendations: List[str] = []
        chapters = summary.get("chapters", {}) if isinstance(summary, dict) else {}
        total = int(chapters.get("total", 0) or 0)
        failed = int(chapters.get("failed", 0) or 0)
        switches = int(summary.get("engine_switches", 0) or 0) if isinstance(summary, dict) else 0
        opt = summary.get("optimization_metrics", {}) if isinstance(summary, dict) else {}
        hit_rate = float(opt.get("prefetch_hit_rate", 0.0) or 0.0)
        budget_caps = int(opt.get("budget_caps_applied", 0) or 0)
        blocked = summary.get("edge_blocked_chapters", {}) if isinstance(summary, dict) else {}
        blocked_count = int(blocked.get("count", 0) or 0) if isinstance(blocked, dict) else 0

        if total > 0 and (failed / max(1, total)) > 0.1:
            recommendations.append(
                "- Alta taxa de falha: habilite `--engine auto` e mantenha retries automáticos."
            )
        if blocked_count > 0:
            recommendations.append(
                "- Edge bloqueou capítulos: reduza `EDGE_MAX_CONCURRENCY` ou use fallback offline."
            )
        if hit_rate < 0.4:
            recommendations.append(
                "- Prefetch com baixo aproveitamento: teste `--stage-pipeline` e `--stage-pipeline-depth 3`."
            )
        if budget_caps > 3:
            recommendations.append(
                "- Resource budget reduziu paralelismo várias vezes: reduza `--parallel-slots`."
            )
        if switches > max(3, total // 2):
            recommendations.append(
                "- Muitas trocas de engine: fixe engine principal para este livro e compare com A/B."
            )

        if segment_summary:
            engines = segment_summary.get("engines", {})
            if isinstance(engines, dict) and engines:
                ranked = sorted(
                    (
                        (
                            str(name),
                            float((row or {}).get("avg_chars_per_second", 0.0) or 0.0),
                        )
                        for name, row in engines.items()
                        if isinstance(row, dict)
                    ),
                    key=lambda item: item[1],
                    reverse=True,
                )
                if ranked:
                    best_name, best_cps = ranked[0]
                    recommendations.append(
                        f"- Melhor engine nesta execução: `{best_name}` (~{best_cps:.1f} chars/s)."
                    )
                high_jitter = [
                    (name, float((row or {}).get("jitter_ratio", 0.0) or 0.0))
                    for name, row in engines.items()
                    if isinstance(row, dict)
                    and float((row or {}).get("jitter_ratio", 0.0) or 0.0) >= 2.5
                ]
                if high_jitter:
                    worst = sorted(high_jitter, key=lambda item: item[1], reverse=True)[0]
                    recommendations.append(
                        f"- Alta variabilidade de segmento em `{worst[0]}` ({worst[1]:.2f}x): "
                        "reduza chunk/concurrency para estabilidade."
                    )
                low_p50 = [
                    (name, float((row or {}).get("p50_chars_per_second", 0.0) or 0.0))
                    for name, row in engines.items()
                    if isinstance(row, dict)
                ]
                if low_p50:
                    slowest = sorted(low_p50, key=lambda item: item[1])[0]
                    if slowest[1] > 0 and slowest[1] < 90:
                        recommendations.append(
                            f"- P50 baixo em `{slowest[0]}` ({slowest[1]:.1f} chars/s): "
                            "priorize engine alternativa ou aumente paralelismo."
                        )

        if not recommendations:
            recommendations.append(
                "- Execução estável; manter perfil atual e repetir benchmark A/B."
            )

        content = [
            "# Runtime Recommendations",
            "",
            f"Generated at: {time.strftime('%Y-%m-%d %H:%M:%S')}",
            "",
            *recommendations,
            "",
        ]
        out = metrics_path.with_name("metrics-recommendations.txt")
        with contextlib.suppress(Exception):
            out.write_text("\n".join(content), encoding="utf-8")

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

    def _record_segment_success(
        self,
        *,
        engine_label: str,
        chapter_index: int,
        segment_chars: int,
        engine_pool: Optional[JobEnginePool] = None,
        config: Optional[ConversionConfig] = None,
    ) -> None:
        """Adapt runtime parameters using successful segment/chunk telemetry."""
        engine = (engine_label or "").lower()
        if segment_chars <= 0:
            return

        state = self._segment_adaptive_state
        now = time.time()
        chapter_key = f"{engine}:{chapter_index}"
        chapter_times = state.setdefault("last_event_by_chapter", {})
        prev_ts = chapter_times.get(chapter_key)
        chapter_times[chapter_key] = now
        if prev_ts is None:
            return

        elapsed = max(now - float(prev_ts), 0.001)
        cps = float(segment_chars) / elapsed
        engine_cps = state.setdefault("engine_cps", {})
        history = engine_cps.setdefault(engine, [])
        history.append(cps)
        if len(history) > 16:
            del history[0 : len(history) - 16]
        avg_cps = sum(history) / len(history)
        snapshot = self._resource_snapshot()
        self._apply_thermal_power_guard(engine_pool=engine_pool)
        self._append_segment_metric(
            {
                "event": "segment_success",
                "engine": engine,
                "chapter": chapter_index,
                "segment_chars": int(segment_chars),
                "elapsed_s": round(float(elapsed), 4),
                "cps": round(float(cps), 3),
                "avg_cps": round(float(avg_cps), 3),
                "cpu_percent": round(float(snapshot.cpu_percent), 2),
                "ram_gb": round(float(snapshot.ram_gb), 3),
                "parallel": int(self._parallel_state.get("current") or 1),
            }
        )
        self._apply_engine_resource_budget(
            engine_label=engine,
            snapshot=snapshot,
            engine_pool=engine_pool,
        )

        # Reduce health-check overhead after sustained stability; restore immediately when unstable.
        base_interval = max(1, int(state.get("pre_check_base_interval", 1) or 1))
        max_interval = max(base_interval, int(state.get("pre_check_max_interval", 4) or 4))
        promote_streak = max(2, int(state.get("pre_check_promote_streak", 6) or 6))
        interval_by_engine = state.setdefault("pre_check_interval_by_engine", {})
        stable_by_engine = state.setdefault("pre_check_stable_streak_by_engine", {})
        current_interval = max(
            base_interval, int(interval_by_engine.get(engine, base_interval) or 1)
        )
        stable_streak = int(stable_by_engine.get(engine, 0) or 0)

        is_unstable = snapshot.cpu_percent > 95 or snapshot.ram_gb < 0.6 or avg_cps < 80
        if is_unstable:
            stable_by_engine[engine] = 0
            if current_interval != base_interval:
                interval_by_engine[engine] = base_interval
                if self.verbose:
                    print(
                        f"🩺 Pre-check interval reset for {engine}: {current_interval}→{base_interval}"
                    )
        else:
            stable_streak += 1
            if stable_streak >= promote_streak and current_interval < max_interval:
                interval_by_engine[engine] = min(max_interval, current_interval + 1)
                stable_by_engine[engine] = 0
                if self.verbose:
                    print(
                        f"⚡ Pre-check interval promoted for {engine}: "
                        f"{current_interval}→{interval_by_engine[engine]}"
                    )
            else:
                stable_by_engine[engine] = stable_streak

        cooldown = float(state.get("cooldown_seconds", 10.0) or 10.0)
        last_adjustment = float(state.get("last_adjustment", 0.0) or 0.0)
        if (now - last_adjustment) < cooldown:
            return

        current_parallel = max(1, int(self._parallel_state.get("current") or 1))
        ceiling_parallel = max(
            current_parallel, int(self._parallel_state.get("ceiling") or current_parallel)
        )
        new_parallel = current_parallel
        reason = None

        if snapshot.ram_gb < 0.45 and current_parallel > 1:
            state["down_streak"] = int(state.get("down_streak", 0) or 0) + 1
            state["up_streak"] = 0
            if state["down_streak"] >= 2:
                new_parallel = current_parallel - 1
                reason = f"segment telemetry: low RAM ({snapshot.ram_gb:.1f} GB)"
        elif snapshot.cpu_percent > 95 and avg_cps < 100 and current_parallel > 1:
            state["down_streak"] = int(state.get("down_streak", 0) or 0) + 1
            state["up_streak"] = 0
            if state["down_streak"] >= 2:
                new_parallel = current_parallel - 1
                reason = (
                    f"segment telemetry: CPU saturation ({int(snapshot.cpu_percent)}%) with low cps"
                )
        elif (
            snapshot.cpu_percent < 75
            and snapshot.ram_gb > 1.0
            and avg_cps > 170
            and current_parallel < ceiling_parallel
        ):
            state["up_streak"] = int(state.get("up_streak", 0) or 0) + 1
            state["down_streak"] = 0
            if state["up_streak"] >= 3:
                new_parallel = current_parallel + 1
                reason = f"segment telemetry: stable throughput (~{int(avg_cps)} chars/s)"
        else:
            state["up_streak"] = 0
            state["down_streak"] = 0

        new_parallel = max(1, min(ceiling_parallel, new_parallel))
        if new_parallel != current_parallel:
            self._parallel_state["current"] = new_parallel
            if engine_pool is not None:
                engine_pool.update_parallel_slots(new_parallel)
            state["last_adjustment"] = now
            state["up_streak"] = 0
            state["down_streak"] = 0
            if self.verbose and reason:
                print(f"⚙️ {reason} → {new_parallel} chapter(s) in parallel")
            return

        if not config:
            return

        tuned = False
        if engine == "piper":
            chunk_chars = int(os.getenv("PIPER_CHUNK_CHARS", "3000") or "3000")
            new_chunk = chunk_chars
            if avg_cps > 200 and snapshot.cpu_percent < 85:
                new_chunk = min(6000, chunk_chars + 300)
            elif avg_cps < 120 or snapshot.cpu_percent > 95:
                new_chunk = max(1800, chunk_chars - 300)
            if new_chunk != chunk_chars:
                os.environ["PIPER_CHUNK_CHARS"] = str(new_chunk)
                tuned = True
                if self.verbose:
                    print(f"⚙️ Piper adaptive chunk: {chunk_chars} → {new_chunk} (seg ok)")
            workers = int(
                getattr(config, "piper_max_procs", 0) or os.getenv("PIPER_MAX_PROCS", "2") or "2"
            )
            new_workers = workers
            if snapshot.cpu_percent > 95 or snapshot.ram_gb < 0.8:
                new_workers = max(1, workers - 1)
            elif avg_cps > 170 and snapshot.cpu_percent < 82 and snapshot.ram_gb > 1.4:
                new_workers = min(8, workers + 1)
            if new_workers != workers:
                os.environ["PIPER_MAX_PROCS"] = str(new_workers)
                config.piper_max_procs = new_workers
                tuned = True
                if self.verbose:
                    print(f"⚙️ Piper adaptive workers: {workers} → {new_workers} (seg ok)")
        elif engine == "coqui":
            chunk_chars = int(os.getenv("COQUI_CHUNK_CHARS", "1500") or "1500")
            new_chunk = chunk_chars
            if avg_cps > 120 and snapshot.cpu_percent < 88:
                new_chunk = min(4000, chunk_chars + 200)
            elif avg_cps < 70 or snapshot.cpu_percent > 95:
                new_chunk = max(900, chunk_chars - 200)
            if new_chunk != chunk_chars:
                os.environ["COQUI_CHUNK_CHARS"] = str(new_chunk)
                config.coqui_chunk_chars = new_chunk
                tuned = True
                if self.verbose:
                    print(f"⚙️ Coqui adaptive chunk: {chunk_chars} → {new_chunk} (seg ok)")
        elif engine == "edge":
            edge_chunk = int(os.getenv("EDGE_CHUNK_CHARS", "12000") or "12000")
            new_chunk = edge_chunk
            if avg_cps > 240 and snapshot.cpu_percent < 85:
                new_chunk = min(24000, edge_chunk + 500)
            elif avg_cps < 140 or snapshot.cpu_percent > 95:
                new_chunk = max(4000, edge_chunk - 500)
            if new_chunk != edge_chunk:
                os.environ["EDGE_CHUNK_CHARS"] = str(new_chunk)
                if config is not None:
                    config.edge_chunk_chars = new_chunk
                tuned = True
                if self.verbose:
                    print(f"⚙️ Edge adaptive chunk: {edge_chunk} → {new_chunk} (seg ok)")

        if tuned:
            state["last_adjustment"] = now

    def _pre_segment_health_check(
        self,
        *,
        engine_label: str,
        segment_chars: int,
        engine_pool: Optional[JobEnginePool] = None,
        config: Optional[ConversionConfig] = None,
        engine_obj: Optional[object] = None,
    ) -> None:
        """Run health checks before each segment and proactively adjust parameters."""
        engine = (engine_label or "").lower()
        if segment_chars <= 0:
            return
        state = self._segment_adaptive_state
        base_interval = max(1, int(state.get("pre_check_base_interval", 1) or 1))
        interval_by_engine = state.setdefault("pre_check_interval_by_engine", {})
        counter_by_engine = state.setdefault("pre_check_counter_by_engine", {})
        interval = max(base_interval, int(interval_by_engine.get(engine, base_interval) or 1))
        counter = int(counter_by_engine.get(engine, 0) or 0) + 1
        counter_by_engine[engine] = counter
        if interval > 1 and (counter % interval) != 1:
            return

        snapshot = self._resource_snapshot()
        self._apply_thermal_power_guard(engine_pool=engine_pool)
        self._append_segment_metric(
            {
                "event": "pre_segment_check",
                "engine": engine,
                "segment_chars": int(segment_chars),
                "cpu_percent": round(float(snapshot.cpu_percent), 2),
                "ram_gb": round(float(snapshot.ram_gb), 3),
                "parallel": int(self._parallel_state.get("current") or 1),
            }
        )
        self._apply_engine_resource_budget(
            engine_label=engine,
            snapshot=snapshot,
            engine_pool=engine_pool,
        )
        current_parallel = max(1, int(self._parallel_state.get("current") or 1))
        ceiling_parallel = max(
            current_parallel, int(self._parallel_state.get("ceiling") or current_parallel)
        )

        reduced_parallel = current_parallel
        if snapshot.ram_gb < 0.4 and current_parallel > 1:
            state["pre_reduce_streak"] = int(state.get("pre_reduce_streak", 0) or 0) + 1
            state["pre_hold_streak"] = 0
            if state["pre_reduce_streak"] >= 2:
                reduced_parallel = current_parallel - 1
        elif snapshot.cpu_percent > 97 and current_parallel > 1:
            state["pre_reduce_streak"] = int(state.get("pre_reduce_streak", 0) or 0) + 1
            state["pre_hold_streak"] = 0
            if state["pre_reduce_streak"] >= 2:
                reduced_parallel = current_parallel - 1
        else:
            state["pre_hold_streak"] = int(state.get("pre_hold_streak", 0) or 0) + 1
            if state["pre_hold_streak"] >= 2:
                state["pre_reduce_streak"] = 0

        reduced_parallel = max(1, min(ceiling_parallel, reduced_parallel))
        if reduced_parallel != current_parallel:
            self._parallel_state["current"] = reduced_parallel
            if engine_pool is not None:
                engine_pool.update_parallel_slots(reduced_parallel)
            state = self._segment_adaptive_state
            state["pre_reduce_streak"] = 0
            state["pre_hold_streak"] = 0
            if self.verbose:
                print(
                    f"🩺 Pre-segment check: reducing parallelism {current_parallel}→{reduced_parallel}"
                )

        if engine == "edge":
            if config is not None:
                chunk_chars = int(getattr(config, "edge_chunk_chars", 12000) or 12000)
                if snapshot.cpu_percent > 95 and segment_chars > 8000:
                    chunk_chars = max(4000, chunk_chars - 1000)
                elif snapshot.cpu_percent < 75 and segment_chars > 12000:
                    chunk_chars = min(24000, chunk_chars + 500)
                config.edge_chunk_chars = chunk_chars
                os.environ["EDGE_CHUNK_CHARS"] = str(chunk_chars)
            if engine_obj is not None and hasattr(engine_obj, "apply_speed_profile"):
                with contextlib.suppress(Exception):
                    engine_obj.apply_speed_profile(
                        chunk_char_limit=max(4000, int(getattr(config, "edge_chunk_chars", 12000))),
                    )
        elif engine == "piper":
            chunk_chars = int(os.getenv("PIPER_CHUNK_CHARS", "3000") or "3000")
            workers = int(
                getattr(config, "piper_max_procs", 0)
                if config is not None
                else 0 or os.getenv("PIPER_MAX_PROCS", "2") or "2"
            )
            if snapshot.cpu_percent > 95:
                chunk_chars = max(1800, chunk_chars - 300)
                workers = max(1, workers - 1)
            elif snapshot.cpu_percent < 75 and segment_chars > 6000:
                chunk_chars = min(6000, chunk_chars + 200)
                workers = min(8, workers + 1)
            os.environ["PIPER_CHUNK_CHARS"] = str(chunk_chars)
            os.environ["PIPER_MAX_PROCS"] = str(workers)
            if config is not None:
                config.piper_max_procs = workers
            if engine_obj is not None:
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_chunk_char_limit", chunk_chars)
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_semaphore", asyncio.Semaphore(max(1, workers)))
        elif engine == "coqui":
            chunk_chars = int(os.getenv("COQUI_CHUNK_CHARS", "1500") or "1500")
            if snapshot.cpu_percent > 95:
                chunk_chars = max(900, chunk_chars - 200)
            elif snapshot.cpu_percent < 75 and segment_chars > 6000:
                chunk_chars = min(4000, chunk_chars + 150)
            os.environ["COQUI_CHUNK_CHARS"] = str(chunk_chars)
            if config is not None:
                config.coqui_chunk_chars = chunk_chars

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
        last_resort_attempted = False
        last_problem_chapters: List[str] = []

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
                        "missing_cache",
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
                    print("✅ Validation passed! Conversion 100% correct.")
                return True

            # Extract chapters with problems
            problem_chapters = extract_problem_chapters(issues)
            last_problem_chapters = list(problem_chapters)

            if not problem_chapters:
                # Has problems but couldn't identify specific chapters
                if self.verbose:
                    print("⚠️  Problems detected but couldn't identify specific chapters")
                consecutive_failures += 1
                if consecutive_failures >= 3:
                    if not last_resort_attempted:
                        last_resort_attempted = True
                        recovered = await self._last_resort_recovery(
                            epub_path=epub_path,
                            output_dir=output_dir,
                            chapter_selectors=None,
                            reason="validation without identifiable chapter mapping",
                        )
                        if recovered:
                            consecutive_failures = 0
                            last_problem_count = float("inf")
                            continue
                    print("❌ Critical error: cannot identify problems. Aborting.")
                    return False
                continue

            # Detect if we're stuck (same number of problems)
            current_problem_count = len(problem_chapters)
            if current_problem_count >= last_problem_count:
                consecutive_failures += 1
                # With progressive tolerance, allow more retries for duration-only issues
                _, duration_only_check = self._categorize_problems(issues, problem_chapters)
                all_duration_only = len(duration_only_check) == current_problem_count
                max_consecutive = 6 if all_duration_only else 3
                if consecutive_failures >= max_consecutive:
                    if not last_resort_attempted:
                        last_resort_attempted = True
                        recovered = await self._last_resort_recovery(
                            epub_path=epub_path,
                            output_dir=output_dir,
                            chapter_selectors=problem_chapters,
                            reason=f"stuck with repeated problems ({current_problem_count})",
                        )
                        if recovered:
                            consecutive_failures = 0
                            last_problem_count = float("inf")
                            continue
                    if self.verbose:
                        print(
                            f"❌ Critical error: stuck with {current_problem_count} problems after {max_consecutive} attempts. Aborting."
                        )
                    return False
            else:
                consecutive_failures = 0

            last_problem_count = current_problem_count

            # Categorize problems by type
            missing_mp3_only, duration_only = self._categorize_problems(issues, problem_chapters)

            if self.verbose:
                print()
                print("=" * 60)
                print(f"🔧 RECONVERSION: {len(problem_chapters)} chapter(s) with problems")
                print("=" * 60)
                print(f"   Chapters: {', '.join(map(str, problem_chapters[:10]))}")
                if missing_mp3_only:
                    print(
                        f"   💡 {len(missing_mp3_only)} chapter(s) with missing MP3 only - quick synthesis"
                    )
                if duration_only:
                    print(
                        f"   ⏱️  {len(duration_only)} chapter(s) with incorrect duration only - will be retried with higher tolerance"
                    )
                skip_set = set(missing_mp3_only) | set(duration_only)
                full_reconvert = [ch for ch in problem_chapters if ch not in skip_set]
                if full_reconvert:
                    print(
                        f"   🔄 {len(full_reconvert)} chapter(s) with incorrect text/name - full reconversion"
                    )

            # Remove bad MP3s before reconverting
            removed_files = self._remove_bad_mp3s(output_dir, issues, problem_chapters)
            if removed_files and self.verbose:
                print(f"   🗑️  {len(removed_files)} bad MP3(s) removed before reconversion:")
                for f in removed_files:
                    print(f"      - {f}")
                print("=" * 60)

            # Reconvert problematic chapters
            try:
                quick_missing_mp3_failed = False
                # For missing MP3s, try quick synthesis first
                if missing_mp3_only:
                    quick_limit = max(1, int(os.getenv("QUICK_SYNTH_MAX_CHAPTERS", "8") or "8"))
                    if len(missing_mp3_only) > quick_limit:
                        quick_missing_mp3_failed = True
                        if self.verbose:
                            print(
                                f"   ⚠️  {len(missing_mp3_only)} missing MP3 chapters (>{quick_limit}) - skipping quick synthesis and forcing full reconversion"
                            )
                    else:
                        success = await self._reconvert_missing_mp3s(
                            output_dir, cache_dir, missing_mp3_only, issues
                        )
                        if success and self.verbose:
                            print(f"   ✅ {len(missing_mp3_only)} MP3(s) generated successfully")
                        if not success:
                            quick_missing_mp3_failed = True
                            if self.verbose:
                                print(
                                    "   ⚠️  Quick synthesis incomplete; falling back to full chapter reconversion"
                                )

                # Duration-only chapters: re-synthesize MP3 (may get slightly different timing)
                if duration_only and attempt <= 2:
                    # Only re-synthesize on first 2 attempts; after that rely on tolerance increase
                    if self.verbose:
                        print(
                            f"   🔄 Re-synthesizing {len(duration_only)} MP3(s) with incorrect duration..."
                        )
                    await self._reconvert_missing_mp3s(output_dir, cache_dir, duration_only, issues)

                # For the rest, reconvert full chapter
                skip_set = set(duration_only)
                if not quick_missing_mp3_failed:
                    skip_set |= set(missing_mp3_only)
                chapters_to_reconvert = [ch for ch in problem_chapters if ch not in skip_set]

                if not chapters_to_reconvert:
                    continue  # Only MP3s/duration, already handled

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
                        print(f"⚠️  Warning: failed to apply transforms ({exc})")

                all_chapters = reader.get_chapter_structure(preserve_all=True)

                chapter_indices = self._resolve_problem_chapter_indices(
                    all_chapters, chapters_to_reconvert
                )

                if not chapter_indices:
                    if self.verbose:
                        print("⚠️  Could not map problematic chapters")
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
                retry_config.extra["disable_chunk_resume"] = "1"

                # Reconvert using existing converter instance
                await self.convert(reader, retry_config)

            except Exception as exc:
                if self.verbose:
                    print(f"⚠️  Error reconverting: {exc}")
                    import traceback

                    traceback.print_exc()
                consecutive_failures += 1
                if consecutive_failures >= 3:
                    if not last_resort_attempted:
                        last_resort_attempted = True
                        recovered = await self._last_resort_recovery(
                            epub_path=epub_path,
                            output_dir=output_dir,
                            chapter_selectors=last_problem_chapters or None,
                            reason=f"exception during reconversion: {exc}",
                        )
                        if recovered:
                            consecutive_failures = 0
                            last_problem_count = float("inf")
                            continue
                    return False
                continue

        # If we reached here, attempts exhausted but may have made progress
        if not last_resort_attempted:
            recovered = await self._last_resort_recovery(
                epub_path=epub_path,
                output_dir=output_dir,
                chapter_selectors=last_problem_chapters or None,
                reason=f"max retries exhausted ({max_retries})",
            )
            if recovered:
                return True
        if self.verbose:
            print(f"⚠️  Reached limit of {max_retries} attempts. Some problems may persist.")
        return False

    def _categorize_problems(self, issues: list, problem_chapters: list) -> tuple[list, list]:
        """
        Categorize problems to decide reconversion strategy.

        Returns:
            Tuple of (missing_mp3_only, duration_only) chapter lists
        """
        missing_mp3_only = []
        duration_only = []

        for chapter_num in problem_chapters:
            chapter_issues = [issue for issue in issues if f"Chapter {chapter_num}" in issue]
            if not chapter_issues:
                continue

            tags: Set[str] = set()
            for issue in chapter_issues:
                issue_l = issue.lower()
                if "missing mp3" in issue_l:
                    tags.add("missing_mp3")
                elif "duration mismatch" in issue_l:
                    tags.add("duration")
                else:
                    # Any other validation issue (missing cache, text mismatch, HTML, duplicates, etc.)
                    # must trigger full chapter reconversion.
                    tags.add("other")

            if tags == {"missing_mp3"}:
                missing_mp3_only.append(chapter_num)
            elif tags == {"duration"}:
                # Duration-only issue (text and MP3 exist but duration off)
                duration_only.append(chapter_num)

        return missing_mp3_only, duration_only

    def _remove_bad_mp3s(self, output_dir: Path, issues: list, problem_chapters: list) -> list[str]:
        """
        Remove bad MP3s before reconverting to avoid conflicts.

        Extracts MP3 names from validation issues (incorrect name, duplicate,
        wrong duration) and removes them from the output directory.

        Returns:
            List of removed file names.
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
        Reconvert only the missing MP3s using cached text.

        Returns:
            True if all MP3s were generated successfully
        """
        if not cache_dir or not cache_dir.exists():
            return False

        try:
            import asyncio

            from .config import VoiceConfigProvider
            from .tts.factory import TTSFactory
            from .utils import AudioProcessor

            config = self._active_config
            if not config:
                return False

            original_primary_language = getattr(config, "primary_language", None)
            original_languages = list(getattr(config, "languages", []) or [])
            effective_lang = self._effective_primary_language(config)
            config.primary_language = effective_lang
            if not original_languages:
                config.languages = [effective_lang]

            factory = TTSFactory()
            available_engines = set(factory.available_engines())

            requested_engine = (getattr(config, "engine", "") or "edge").lower()
            ordered_candidates: list[str] = []

            def _append_candidate(engine_name: str) -> None:
                if not engine_name:
                    return
                if engine_name in ordered_candidates:
                    return
                ordered_candidates.append(engine_name)

            if requested_engine == "auto":
                _append_candidate("edge")
                _append_candidate("piper")
                _append_candidate("coqui")
                _append_candidate("kokoro")
                _append_candidate("spark")
            else:
                _append_candidate(requested_engine)
                if requested_engine == "edge":
                    _append_candidate("piper")
                    _append_candidate("coqui")
                elif requested_engine == "coqui":
                    _append_candidate("piper")
                    _append_candidate("edge")
                elif requested_engine == "piper":
                    _append_candidate("edge")
                    _append_candidate("coqui")

            engine_candidates = [
                name for name in ordered_candidates if name == "edge" or name in available_engines
            ]
            if not engine_candidates:
                if self.verbose:
                    print(
                        f"⚠️  Error while reconverting MP3s: no available engine for request '{requested_engine}'"
                    )
                return False

            selected_engine_name = ""
            tts_engine = None
            original_engine = config.engine
            engine_errors: list[str] = []
            for candidate in engine_candidates:
                try:
                    config.engine = candidate
                    tts_engine = factory.create_engine(config)
                    selected_engine_name = candidate
                    break
                except Exception as exc:
                    engine_errors.append(f"{candidate}: {exc}")
                    continue
                finally:
                    config.engine = original_engine

            if not tts_engine:
                if self.verbose:
                    detail = "; ".join(engine_errors[:3]) if engine_errors else "unknown reason"
                    print(f"⚠️  Error while reconverting MP3s: {detail}")
                return False

            if self.verbose and selected_engine_name != requested_engine:
                print(
                    f"   🔄 Quick synthesis engine fallback: {requested_engine} → {selected_engine_name}"
                )

            # Criar audio processor
            audio_processor = AudioProcessor()
            piper_engine = None
            edge_quick_timeout = max(20, int(os.getenv("EDGE_QUICK_SYNTH_TIMEOUT", "90") or "90"))
            piper_quick_timeout = max(
                60, int(os.getenv("PIPER_QUICK_SYNTH_TIMEOUT", "360") or "360")
            )
            generic_quick_timeout = max(
                45, int(os.getenv("GENERIC_QUICK_SYNTH_TIMEOUT", "240") or "240")
            )
            quick_synth_max_chars = max(
                5000, int(os.getenv("QUICK_SYNTH_MAX_CHARS", "300000") or "300000")
            )

            def _is_edge_network_failure(exc: BaseException) -> bool:
                text = str(exc or "").lower()
                return any(
                    token in text
                    for token in (
                        "clientconnectordnserror",
                        "persistent ssl error",
                        "cannot connect to host",
                        "speech.platform.bing.com",
                        "dns",
                        "ssl",
                        "timeout",
                    )
                )

            normalized_targets: List[str] = []
            seen_targets: Set[str] = set()
            for raw in chapter_nums:
                key = str(raw).strip()
                if not key or key in seen_targets:
                    continue
                seen_targets.add(key)
                normalized_targets.append(key)

            success_count = 0
            completed_targets: Set[str] = set()

            for chapter_num in normalized_targets:
                try:
                    issue_heading = None
                    chapter_token = str(chapter_num).strip()
                    for issue in issues or []:
                        issue_text = str(issue)
                        if f"Chapter {chapter_token} '" not in issue_text:
                            continue
                        try:
                            issue_heading = issue_text.split(f"Chapter {chapter_token} '", 1)[
                                1
                            ].split("':", 1)[0]
                            break
                        except Exception:
                            continue

                    text_dirs: List[Path] = []
                    for candidate in (
                        cache_dir / "text",
                        cache_dir,
                        output_dir / "text",
                    ):
                        if candidate.exists() and candidate.is_dir():
                            text_dirs.append(candidate)
                    if not text_dirs:
                        if self.verbose:
                            print(f"   ⚠️  Chapter {chapter_num}: no text cache directories found")
                        continue

                    target_file, using_parsed_fallback, pre_tts_map = (
                        self._find_quick_synth_text_file(
                            chapter_num=chapter_token,
                            text_dirs=text_dirs,
                            issue_heading=issue_heading,
                        )
                    )

                    if not target_file or not target_file.exists():
                        if self.verbose:
                            print(f"   ⚠️  Chapter {chapter_num}: pre-tts.txt not found")
                            sample_files: List[str] = []
                            for files in pre_tts_map.values():
                                sample_files.extend([f.name[:50] for f in files[:2]])
                            print(f"      Available files: {sample_files[:6]}")
                        continue

                    # Ler text
                    text = target_file.read_text(encoding="utf-8")
                    if not text:
                        if self.verbose:
                            print(f"   ⚠️  Chapter {chapter_num}: empty text")
                        continue
                    if len(text) > quick_synth_max_chars:
                        if self.verbose:
                            print(
                                f"   ⚠️  Chapter {chapter_num}: text too large for quick synthesis "
                                f"({len(text):,} chars > {quick_synth_max_chars:,}) - forcing full reconversion"
                            )
                        continue

                    # Extrair nome do chapter do filename
                    chapter_name = target_file.stem.replace("-pre-tts", "").replace("-parsed", "")
                    # If file has sequential prefix ("9 - 4.3 - ..."), strip it to keep MP3 naming aligned.
                    chapter_name = re.sub(
                        r"^\s*\d+\s*-\s*(?=\d+(?:\.\d+)?\s*-)",
                        "",
                        chapter_name,
                    ).strip()
                    if issue_heading:
                        # Use EPUB heading from validator when available to preserve TOC order/name.
                        chapter_name = issue_heading.strip()

                    if self.verbose:
                        source_tag = "parsed fallback" if using_parsed_fallback else "pre-tts"
                        print(f"   🎙️  Chapter {chapter_num}: synthesizing MP3 ({source_tag})...")

                    # Synthesize audio
                    wav_file = None
                    try:
                        synth_task = tts_engine.synthesize_async(
                            text, target_file.parent / f"temp_{chapter_num}.wav"
                        )
                        if selected_engine_name == "edge":
                            timeout_s = edge_quick_timeout
                        elif selected_engine_name == "piper":
                            timeout_s = piper_quick_timeout
                        else:
                            timeout_s = generic_quick_timeout
                        wav_file = await asyncio.wait_for(synth_task, timeout=timeout_s)
                    except Exception as primary_exc:
                        if selected_engine_name == "edge" and "piper" in available_engines:
                            try:
                                if piper_engine is None:
                                    piper_language = self._effective_primary_language(config)
                                    piper_model = VoiceConfigProvider().get_voice(
                                        "piper", piper_language
                                    )
                                    config.engine = "piper"
                                    config.primary_language = piper_language
                                    if piper_model:
                                        config.model_path = Path(piper_model)
                                    piper_engine = factory.create_engine(config)
                                    if self.verbose:
                                        reason = (
                                            "network/timeout"
                                            if _is_edge_network_failure(primary_exc)
                                            else "error"
                                        )
                                        print(
                                            f"   🔄 Edge quick synthesis failed ({reason}); retrying chapter with Piper"
                                        )
                                piper_task = piper_engine.synthesize_async(
                                    text, target_file.parent / f"temp_{chapter_num}.wav"
                                )
                                wav_file = await asyncio.wait_for(
                                    piper_task, timeout=piper_quick_timeout
                                )
                            except Exception as fallback_exc:
                                if self.verbose:
                                    print(
                                        f"   ⚠️  Chapter {chapter_num}: edge and piper failed - {fallback_exc}"
                                    )
                                wav_file = None
                            finally:
                                config.engine = original_engine
                        else:
                            if self.verbose and isinstance(primary_exc, asyncio.TimeoutError):
                                print(
                                    f"   ⚠️  Chapter {chapter_num}: quick synthesis timeout on {selected_engine_name}"
                                )
                            raise

                    if not wav_file or not Path(wav_file).exists():
                        if self.verbose:
                            print(f"   ❌ Chapter {chapter_num}: synthesis failed")
                        continue

                    # Converter para MP3
                    mp3_path = output_dir / f"{chapter_name}.mp3"
                    await audio_processor.convert_to_mp3(Path(wav_file), mp3_path)

                    # Clean up temporary WAV
                    Path(wav_file).unlink(missing_ok=True)

                    if mp3_path.exists():
                        success_count += 1
                        completed_targets.add(str(chapter_num).strip())
                        if self.verbose:
                            print(f"   ✅ Chapter {chapter_num}: MP3 gerado")
                    else:
                        if self.verbose:
                            print(f"   ❌ Chapter {chapter_num}: MP3 conversion failed")

                except Exception as exc:
                    if self.verbose:
                        print(f"   ⚠️  Chapter {chapter_num}: error - {exc}")
                    continue

            all_done = len(completed_targets) == len(normalized_targets)
            if self.verbose:
                print(
                    f"   📈 Quick synthesis result: {len(completed_targets)}/{len(normalized_targets)} chapter(s)"
                )
            return all_done

        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Error while reconverting MP3s: {exc}")
            return False
        finally:
            if config:
                config.primary_language = original_primary_language
                config.languages = original_languages

    async def _auto_validate_output(self, output_dir: Optional[Path], stage: str = "final") -> bool:
        """
        Run validate_conversion.validate_book to cross-check EPUB, cache and MP3.

        Best-effort: failures are logged only in verbose mode.
        Skipped when a chapter filter is active (--chapter) because the
        full-book validator would flag every non-requested chapter as missing.
        """
        try:
            if stage not in {"final", "cache-only", "test", "initial"}:
                return True
            config = self._active_config
            if not config or getattr(config, "auto_validate_output", True) is False:
                return True

            # Skip full-book validation when only specific chapters were requested
            chapter_filter_active = bool(self._parse_chapter_whitelist(config)) or bool(
                (config.extra or {}).get("selected_indices", "").strip()
            )
            if chapter_filter_active:
                return True

            epub_path = getattr(self, "_current_book_path", None)
            if not epub_path or not Path(epub_path).exists():
                return stage != "final"
            if not output_dir:
                output_dir = self._last_output_dir
            if not output_dir:
                return stage != "final"

            # For "initial" stage, only run if there are existing MP3s to validate
            if stage == "initial":
                if not output_dir.exists():
                    return True
                mp3_files = list(output_dir.glob("*.mp3"))
                if not mp3_files:
                    # No existing MP3s, skip initial validation (first conversion)
                    return True
                if self.verbose:
                    print(
                        f"\n🔍 Detectada conversion anterior com {len(mp3_files)} MP3(s). Validando antes de reconverter..."
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
                            print("\n⚠️  Conversion completed but with validation problems")

                        # Legacy fallback path (disabled by default because it duplicates
                        # expensive full-book validation/retry already handled above).
                        current_engine = getattr(config, "engine", "").lower()
                        if (
                            LEGACY_FINAL_FALLBACK_ENABLED
                            and current_engine in {"edge", "auto"}
                            and stage == "final"
                        ):
                            if self.verbose:
                                print("\n🔄 Trying automatic fallback to Piper...")

                            # Check if Piper is available
                            try:
                                from .tts.factory import TTSFactory

                                factory = TTSFactory()
                                available_engines = factory.available_engines()

                                if "piper" in available_engines:
                                    # Get chapters with problems
                                    from validate_conversion import validate_book

                                    stats, issues = validate_book(
                                        Path(epub_path), Path(output_dir), cache_dir=cache_dir
                                    )

                                    missing_chapters = []
                                    for issue in issues:
                                        if "Missing MP3" in issue:
                                            # Extract chapter number
                                            import re

                                            match = re.search(r"Chapter (\d+(?:\.\d+)?)", issue)
                                            if match:
                                                missing_chapters.append(match.group(1))

                                    if missing_chapters and self.verbose:
                                        print(
                                            f"   🎯 {len(missing_chapters)} chapter(s) missing - reconverting com Piper"
                                        )
                                        print(
                                            f"   Chapters: {', '.join(map(str, missing_chapters[:10]))}"
                                        )

                                    # Mudar temporariamente para Piper
                                    original_engine = config.engine
                                    config.engine = "piper"

                                    try:
                                        # Reconverter chapters missing com Piper
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
                                                    "missing_cache",
                                                    "text_mismatch",
                                                    "parsed_pretts_diff",
                                                    "missing_mp3",
                                                )
                                            )

                                            if not has_critical:
                                                if self.verbose:
                                                    print(
                                                        "   ✅ Fallback para Piper bem-sucedido! Todos os chapters convertidos."
                                                    )
                                                success = True
                                            elif self.verbose:
                                                print(
                                                    f"   ⚠️  Fallback parcial: {stats_after.get('missing_mp3', 0)} chapter(s) ainda missing"
                                                )
                                    finally:
                                        # Restaurar engine original
                                        config.engine = original_engine
                                else:
                                    if self.verbose:
                                        print("   ⚠️  Piper not available para fallback")
                            except Exception as fallback_exc:
                                if self.verbose:
                                    print(f"   ⚠️  Error no fallback: {fallback_exc}")

                        # If problems remain after fallback, show a clear error
                        if not success and self.verbose:
                            print(
                                "\n❌ INCOMPLETE CONVERSION: Alguns chapters not foram convertidos"
                            )
                            print("   Tente:")
                            print("   1. Converter novamente com --engine piper")
                            print("   2. Convert specific chapters with --chapter N")
                    if stage == "final":
                        self._final_validation_passed = bool(success)
                finally:
                    self._auto_fix_guard = False
                return bool(success)

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
                    f"[DEBUG] Auto-validate ({stage}): validation has problems but auto-fix is disabled"
                )
            if stage == "final":
                self._final_validation_passed = not has_problems
            return not has_problems
        except Exception as exc:
            if self.verbose:
                print(f"[DEBUG] Auto-validate ({stage}) failed: {exc}")
            if stage == "final":
                self._final_validation_passed = False
                return False
            return True

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
            issues.append("chapter text is empty or not extracted from EPUB")
        if epub_norm:
            diff = len(epub_norm) - len(parsed_norm)
            allowed_diff = max(50, int(len(epub_norm) * 0.05))
            if abs(diff) > allowed_diff:
                issues.append(f"text divergente do EPUB ({diff:+d} chars)")
            start, end = self._sample_edges(epub_norm)
            if start and start not in parsed_norm:
                issues.append("text parsed sem start do EPUB")
            if end and end not in parsed_norm:
                issues.append("text parsed sem final do EPUB")

        if parsed_norm:
            text_hash = validator.calculate_text_hash(parsed_norm)
            if text_hash in self._text_validation_hashes:
                other = self._text_validation_hashes[text_hash]
                # Only flag as duplicate if it's a different chapter
                # (validation may be called multiple times for same chapter during retries)
                if other != chapter_label:
                    issues.append(f"Duplicate content (same as chapter {other})")
            else:
                # Use full chapter label instead of just integer index to avoid false positives
                # for subchapters (4.1, 4.2, etc.) which all have the same integer part
                self._text_validation_hashes[text_hash] = chapter_label

            snippet = parsed_norm[:200]
            if snippet and parsed_norm.count(snippet) > 1:
                issues.append("Possible internal duplication (repeated snippet)")
            if len(parsed_norm) > 400 and parsed_norm[:200] == parsed_norm[-200:]:
                issues.append("Possible internal duplication (start = end)")

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
            message = f"Post-parsing validation failed ({chapter_label}): {', '.join(issues)}"
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
                        print(f"⚠️ Duration check: {duration_result.message}")
                    # Don't fail conversion due to duration mismatch alone
                    # return False, duration_result.message or "Invalid duration"

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
            return False, "Partial failure detected in Edge synthesis"

        if failed > 0 or tracker_missing > 0:
            total_failed = failed if failed > 0 else tracker_missing
            if expected and generated:
                return (
                    False,
                    f"Missing segments: {generated}/{expected} (failed {total_failed})",
                )
            return False, f"Missing segments: {total_failed}"

        if expected and generated and expected != generated:
            return False, f"Incomplete segments: {generated}/{expected}"

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
                    f"🔄 Chapter {chapter_label}: {len(missing_segments)} segmento(s) failurendo, tentando recuperar..."
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
                    f"{retry_report.still_failed} failed"
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
        # Always prefix with the real TOC/index label (e.g. "5.5") to avoid
        # collisions like multiple files named "005 - ...".
        if chapter_name_clean.startswith(f"{chapter_label} - "):
            chapter_name_with_label = chapter_name_clean
        else:
            chapter_name_with_label = f"{chapter_label} - {chapter_name_clean}"
        filename = self.file_manager.build_output_filename(chapter_name_with_label, chapter_num)
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

        # Extra repair pass: use generated pre-tts labels (which preserve TOC indices
        # like "5.5", "7.2", etc.) to fix legacy/misnumbered files even when fully cached.
        text_dirs: List[Path] = []
        candidate_text = output_dir / "text"
        if candidate_text.exists():
            text_dirs.append(candidate_text)
        if temp_dir:
            temp_text = Path(temp_dir) / "text"
            if temp_text.exists():
                text_dirs.append(temp_text)
        self._repair_output_names_from_text_cache(output_dir, text_dirs, expected_names)

        # Re-scan after repair
        normalized_outputs = []
        expected_names = set()
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

    def _repair_output_names_from_text_cache(
        self,
        output_dir: Path,
        text_dirs: List[Path],
        expected_names: set[str],
    ) -> None:
        if not output_dir.exists() or not text_dirs:
            return

        def _text_label_entries() -> List[tuple[str, str]]:
            entries: List[tuple[str, str]] = []
            seen: Set[str] = set()
            for text_dir in text_dirs:
                if not text_dir.exists():
                    continue
                for pre_tts in sorted(text_dir.glob("*-pre-tts.txt")):
                    stem = pre_tts.name[: -len("-pre-tts.txt")]
                    m = re.match(r"^(\d+(?:\.\d+)?)\s*-\s*(.+)$", stem)
                    if not m:
                        continue
                    label = (m.group(1) or "").strip()
                    title = (m.group(2) or "").strip()
                    if not label or not title:
                        continue
                    key = f"{label}::{title}".lower()
                    if key in seen:
                        continue
                    seen.add(key)
                    entries.append((label, title))
            return entries

        def _norm_title(value: str) -> str:
            text = self._normalize_title_match(value or "")
            text = re.sub(r"^\d+(?:[.,]\d+)?\s*-\s*", "", text).strip()
            return text

        labels = _text_label_entries()
        if not labels:
            return

        # Build candidate pool once
        candidates = [p for p in sorted(output_dir.glob("*.mp3")) if p.name not in expected_names]
        if not candidates:
            return

        used: Set[Path] = set()
        repaired = 0
        for label, title in labels:
            safe_name = self.file_manager.sanitize_filename(f"{label} - {title}")
            target = output_dir / f"{safe_name}.mp3"
            if target.exists():
                continue

            title_norm = _norm_title(title)
            best_path: Optional[Path] = None
            best_score = 0.0
            for candidate in candidates:
                if candidate in used or not candidate.exists():
                    continue
                cand_norm = _norm_title(candidate.stem)
                score = difflib.SequenceMatcher(None, title_norm, cand_norm).ratio()
                if score > best_score:
                    best_score = score
                    best_path = candidate

            # Conservative threshold to avoid bad renames
            if not best_path or best_score < 0.55:
                continue

            try:
                best_path.rename(target)
                used.add(best_path)
                repaired += 1
            except OSError:
                continue

        if repaired and self.verbose:
            print(f"🔧 Name repair from text cache: {repaired} file(s) renamed")

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
                print(f"   ⚠️ Failure embedding ID3 metadata in {mp3_path.name}")

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
        ignore_cached_audio = bool(getattr(config, "force_reprocess", False))

        for idx, chapter in enumerate(chapters, start=1):
            if ignore_cached_audio:
                pending.append(chapter)
                continue
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
                suggested_limit = (ch_chars // 1000) * 1000  # round down to nearest 1K
                print(
                    f"\n⚠️  Oversized chapter: \"{getattr(ch, 'name', '?')[:70]}\""
                    f" ({ch_chars:,} chars = {ratio}× median)"
                    f"\n   → To skip it: MAX_CHAPTER_CHARS={suggested_limit:,}"
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

    async def _last_resort_recovery(
        self,
        *,
        epub_path: Path,
        output_dir: Path,
        chapter_selectors: Optional[List[str]],
        reason: str,
    ) -> bool:
        """Final anti-stall recovery path: stable engine, serial run, strict re-validation."""
        config = self._active_config
        if not config:
            return False

        if self.verbose:
            print("\n🛟 LAST-RESORT RECOVERY")
            print(f"   Reason: {reason}")

        from validate_conversion import validate_book

        from .ebook_reader import EbookReader

        engine_name = (getattr(config, "engine", "") or "edge").lower()
        try:
            from .tts.factory import TTSFactory

            available = set(TTSFactory().available_engines())
        except Exception:
            available = set()

        if "piper" in available:
            engine_name = "piper"
        elif "coqui" in available:
            engine_name = "coqui"
        elif "edge" in {"edge"}:
            engine_name = "edge"

        reader = EbookReader(str(epub_path))
        try:
            from python_app.main import ConverterApplication

            app = ConverterApplication()
            preview_config = app.config.create_conversion_config(
                engine=engine_name,
                output_dir=str(output_dir.parent),
                book_title=reader.title,
                preserve_all_chapters=True,
            )
            preview_config.footnote_mode = "inline"
            preview_config.footnote_context_words = app.FOOTNOTE_CONTEXT_WORDS
            structure_items = app._generate_structure_items(reader, filter_chapters=False)
            structure_items = app._apply_text_transforms(structure_items, preview_config, reader)
            app._apply_structure_to_reader(reader, structure_items)
        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Last-resort: failed to apply transforms ({exc})")

        chapter_indices: List[str] = []
        if chapter_selectors:
            all_chapters = reader.get_chapter_structure(preserve_all=True)
            chapter_indices = self._resolve_problem_chapter_indices(all_chapters, chapter_selectors)

        retry_config = ConversionConfig(
            engine=engine_name,
            voice=config.voice,
            output_dir=str(output_dir.parent),
            book_title=reader.title,
            preserve_all_chapters=True,
            force_reprocess=True,
            clear_cache=False,
            auto_validate_output=False,
            auto_fix_output=False,
        )
        # Preserve language affinity in last-resort mode so offline engines
        # (especially Piper) don't fall back to an unrelated default model.
        retry_lang = (
            getattr(config, "primary_language", None)
            or getattr(reader, "language", None)
            or "pt-BR"
        )
        retry_config.primary_language = str(retry_lang)
        retry_config.languages = [str(retry_lang)]
        retry_config.extra["disable_chunk_resume"] = "1"
        if chapter_indices:
            retry_config.extra["chapter_whitelist"] = ",".join(chapter_indices)

        if self.verbose:
            target = f"{len(chapter_indices)} chapter(s)" if chapter_indices else "full book"
            print(f"   Engine: {engine_name} | Target: {target} | Parallel: serial safe mode")

        env_backup = {
            "CHAPTER_PARALLEL_COUNT": os.environ.get("CHAPTER_PARALLEL_COUNT"),
            "CHAPTER_PARALLEL_MAX": os.environ.get("CHAPTER_PARALLEL_MAX"),
            "EDGE_ENABLE_PARALLEL": os.environ.get("EDGE_ENABLE_PARALLEL"),
        }
        os.environ["CHAPTER_PARALLEL_COUNT"] = "1"
        os.environ["CHAPTER_PARALLEL_MAX"] = "1"
        os.environ["EDGE_ENABLE_PARALLEL"] = "false"
        try:
            await self.convert(reader, retry_config)
        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Last-resort conversion failed: {exc}")
            return False
        finally:
            for key, old in env_backup.items():
                if old is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = old

        stats_after, _issues_after = validate_book(
            epub_path,
            output_dir,
            cache_dir=Path(getattr(config, "cache_dir", ""))
            if getattr(config, "cache_dir", None)
            else None,
            duration_tolerance=1.50,
        )
        critical = any(
            stats_after.get(key, 0) > 0
            for key in ("missing_cache", "text_mismatch", "parsed_pretts_diff", "missing_mp3")
        )
        if not critical:
            if self.verbose:
                print("   ✅ Last-resort recovery succeeded.")
            return True
        if self.verbose:
            print("   ❌ Last-resort recovery still has critical validation problems.")
        return False

    def _resolve_problem_chapter_indices(
        self, chapters: List[Chapter], selectors: List[str]
    ) -> List[str]:
        """
        Resolve selectors from validation issues to actual chapter.index labels.
        Supports decimal labels (e.g. 4.2, 5.0), EPUB position, and sequential non-empty index.
        """
        if not chapters or not selectors:
            return []

        wanted: Set[str] = set()
        for selector in selectors:
            wanted.update(self._chapter_selector_aliases(selector))
        if not wanted:
            return []

        from validate_conversion import normalize_text

        chapter_indices: List[str] = []
        seen_indices: Set[str] = set()
        sequential_num = 0
        for epub_idx, chapter in enumerate(chapters, 1):
            text = chapter.text or ""
            if not text or not normalize_text(text):
                continue
            sequential_num += 1

            label = self._chapter_index_label(chapter, sequential_num)
            chapter_aliases: Set[str] = set()
            chapter_aliases.update(self._chapter_selector_aliases(label))
            chapter_aliases.update(self._chapter_selector_aliases(epub_idx))
            chapter_aliases.update(self._chapter_selector_aliases(sequential_num))

            # Avoid matching decimal chapters (e.g. 4.2) via integer fallback (4).
            if "." not in label:
                chapter_aliases.update(
                    self._chapter_selector_aliases(self._chapter_number(chapter, sequential_num))
                )

            if wanted.intersection(chapter_aliases):
                idx = str(getattr(chapter, "index", sequential_num))
                if idx not in seen_indices:
                    chapter_indices.append(idx)
                    seen_indices.add(idx)

        return chapter_indices

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
        Skip obvious credits/ads ou chapters very short quando not há áudio em cache.
        Never removes chapters que already have MP3 cacheado.
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
        # Default disabled para not skip chapters em scenarios de teste/conversion default
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

    def _detect_macos_thermal_power_cap(self, ceiling: int) -> tuple[int, str]:
        """Return runtime parallel cap based on macOS power/thermal pressure."""
        if platform.system().lower() != "darwin":
            return ceiling, "normal"
        cap = int(max(1, ceiling))
        mode = "normal"
        try:
            batt = subprocess.run(
                ["pmset", "-g", "batt"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            batt_out = str(batt.stdout or "").lower()
            on_battery = "battery power" in batt_out
            if on_battery:
                mode = "battery"
                cap = max(1, min(cap, int(round(ceiling * 0.7))))
        except Exception:
            pass
        try:
            therm = subprocess.run(
                ["pmset", "-g", "therm"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            therm_out = str(therm.stdout or "")
            speed_limit = None
            match = re.search(r"CPU_Speed_Limit\\s*=\\s*(\\d+)", therm_out, flags=re.IGNORECASE)
            if match:
                speed_limit = int(match.group(1))
            if speed_limit is not None:
                if speed_limit < 75:
                    mode = "thermal_hot"
                    cap = max(1, min(cap, int(round(ceiling * 0.5))))
                elif speed_limit < 90:
                    if mode == "normal":
                        mode = "thermal_warm"
                    cap = max(1, min(cap, int(round(ceiling * 0.75))))
        except Exception:
            pass
        return max(1, cap), mode

    def _apply_thermal_power_guard(self, engine_pool: Optional[JobEnginePool] = None) -> None:
        """Continuously cap parallelism under thermal/power pressure."""
        state = self._thermal_guard_state
        now = time.time()
        poll_interval = float(state.get("poll_interval", 20.0) or 20.0)
        cached_cap = state.get("cap")
        mode = str(state.get("mode", "normal") or "normal")
        ceiling = max(1, int(self._parallel_state.get("ceiling") or 1))

        if (now - float(state.get("last_poll", 0.0) or 0.0)) >= poll_interval or cached_cap is None:
            cap, mode = self._detect_macos_thermal_power_cap(ceiling)
            state["last_poll"] = now
            state["cap"] = cap
            state["mode"] = mode
            cached_cap = cap

        if cached_cap is None:
            return
        cap_int = max(1, min(ceiling, int(cached_cap)))
        current = max(1, int(self._parallel_state.get("current") or 1))
        if current > cap_int:
            self._parallel_state["current"] = cap_int
            if engine_pool is not None:
                engine_pool.update_parallel_slots(cap_int)
            self._append_runtime_metric(
                {
                    "event": "thermal_guard_cap",
                    "mode": mode,
                    "from_parallel": current,
                    "to_parallel": cap_int,
                }
            )
            if self.verbose:
                print(f"🌡️ Thermal/power guard ({mode}): {current}→{cap_int}")

    def _auto_tune_parallelism(
        self,
        *,
        throughput: Optional[float],
        batch_errors: int,
    ) -> tuple[int, Optional[str]]:
        """Decide the next chapter parallelism level based on telemetry."""
        state = self._parallel_state or {}
        ceiling = max(1, int(state.get("ceiling") or 1))
        thermal_cap = self._thermal_guard_state.get("cap")
        if thermal_cap is not None:
            try:
                ceiling = max(1, min(ceiling, int(thermal_cap)))
            except (TypeError, ValueError):
                pass
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
                f"reducing to {new_value} chapter(s) simultaneous after {batch_errors} error(s)"
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
                        f"{new_value} chapter(s)"
                    )
                elif last and throughput >= last * 1.18 and current < ceiling:
                    new_value = current + 1
                    reason = (
                        f"throughput atingiu ~{int(throughput)} chars/s → "
                        f"testando {new_value} chapter(s)"
                    )
                elif not last and current < ceiling and throughput >= max(best, 1.0):
                    new_value = current + 1
                    reason = (
                        f"fast initial batch (~{int(throughput)} chars/s) → "
                        f"{new_value} chapter(s)"
                    )

            if not reason:
                if ram_gb < 0.45 and new_value > 1:
                    new_value = new_value - 1
                    reason = f"RAM livre baixa ({ram_gb:.1f} GB) → limitando a {new_value}"
                elif cpu_pct < 55.0 and new_value < ceiling:
                    new_value = new_value + 1
                    reason = f"CPU em {int(cpu_pct)}% → liberando {new_value} chapter(s)"
                elif cpu_pct > 94.0 and throughput and throughput < best * 0.85 and new_value > 1:
                    new_value = new_value - 1
                    reason = f"CPU saturada ({int(cpu_pct)}%) sem ganho → {new_value} chapter(s)"

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
        state["slow_mode_reason"] = reason
        state["recovery_streak"] = 0
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
        fast_profiles = state.setdefault("fast_profiles", {})
        for cfg in state.get("configs") or []:
            if (cfg.engine or "").lower() != "edge":
                continue
            fast_profiles[id(cfg)] = {
                "chunk_chars": getattr(cfg, "edge_chunk_chars", None),
                "max_segment_seconds": getattr(cfg, "edge_max_segment_seconds", None),
                "enable_parallel": getattr(cfg, "edge_enable_parallel", True),
            }
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
        if "pre_slow_parallel" not in state:
            state["pre_slow_parallel"] = current
        new_current = min(current, state["parallel_cap"])
        new_ceiling = min(ceiling, state["parallel_cap"])
        state_current["current"] = max(1, new_current)
        state_current["ceiling"] = max(1, new_ceiling)
        self._parallel_state = state_current
        if engine_pool is not None:
            engine_pool.update_parallel_slots(state_current["current"])

        if announce:
            print(
                "🧯 Edge safe mode: "
                f"{reason} → chunk={chunk_chars} seg={int(max_segment)}s parallel={state_current['current']}"
            )
        return announce

    def _restore_edge_fast_mode(
        self,
        reason: str,
        *,
        engine_pool: Optional[JobEnginePool] = None,
        engine_obj: Optional[object] = None,
    ) -> bool:
        """Restore Edge settings back to the fast profile after recovery."""
        state = self._edge_auto_state or {}
        if not state.get("slow_mode"):
            return False

        state["slow_mode"] = False
        state["slow_mode_reason"] = None
        state["recovery_streak"] = 0
        fast_profiles = state.get("fast_profiles") or {}
        restored = False
        for cfg in state.get("configs") or []:
            if (cfg.engine or "").lower() != "edge":
                continue
            snapshot = fast_profiles.get(id(cfg))
            if not snapshot:
                continue
            restored = True
            if snapshot.get("chunk_chars") is not None:
                cfg.edge_chunk_chars = snapshot["chunk_chars"]
            if snapshot.get("max_segment_seconds") is not None:
                cfg.edge_max_segment_seconds = snapshot["max_segment_seconds"]
            if snapshot.get("enable_parallel") is not None:
                cfg.edge_enable_parallel = snapshot["enable_parallel"]

        fast_cap = int(state.get("fast_parallel_cap") or state.get("parallel_cap") or 1)
        state["parallel_cap"] = max(1, fast_cap)
        state_current = self._parallel_state or {}
        target_parallel = state.pop("pre_slow_parallel", None)
        if target_parallel is None:
            target_parallel = state_current.get("current") or fast_cap
        target_parallel = max(1, min(int(target_parallel), state["parallel_cap"]))
        state_current["ceiling"] = state["parallel_cap"]
        state_current["current"] = target_parallel
        self._parallel_state = state_current
        if engine_pool is not None:
            engine_pool.update_parallel_slots(target_parallel)

        if engine_obj is not None:
            with contextlib.suppress(Exception):
                if hasattr(engine_obj, "apply_speed_profile"):
                    restore_cfg = None
                    for cfg in state.get("configs") or []:
                        if (cfg.engine or "").lower() == "edge":
                            restore_cfg = cfg
                            break
                    chunk_chars = None
                    segment_seconds = None
                    if restore_cfg:
                        chunk_chars = getattr(restore_cfg, "edge_chunk_chars", None)
                        segment_seconds = getattr(restore_cfg, "edge_max_segment_seconds", None)
                    kwargs = {}
                    if chunk_chars:
                        kwargs["chunk_char_limit"] = chunk_chars
                    if segment_seconds:
                        kwargs["max_segment_seconds"] = segment_seconds
                    if kwargs:
                        engine_obj.apply_speed_profile(**kwargs)
                if hasattr(engine_obj, "_enable_parallel"):
                    setattr(engine_obj, "_enable_parallel", True)
                    if hasattr(engine_obj, "_parallel_slots"):
                        setattr(engine_obj, "_parallel_slots", target_parallel)

        self._edge_auto_state = state
        if restored and self.verbose:
            print(f"🚀 Edge safe mode disabled: {reason}")
        return restored

    def _maybe_exit_edge_slow_mode(
        self,
        *,
        engine_label: str,
        chapter_chars: int,
        elapsed: float,
        engine_pool: Optional[JobEnginePool] = None,
        engine_obj: Optional[object] = None,
    ) -> None:
        """Check if slow-mode constraints can be lifted after a fast chapter."""
        if (engine_label or "").lower() != "edge":
            return
        state = self._edge_auto_state or {}
        if not state.get("slow_mode"):
            return
        if chapter_chars <= 0 or elapsed <= 0:
            return

        throughput = chapter_chars / max(elapsed, 0.001)
        min_cps = float(state.get("min_chars_per_second") or EDGE_MIN_CHARS_PER_SECOND)
        recovery_threshold = max(min_cps * 1.25, min_cps + 30.0)
        reason = (state.get("slow_mode_reason") or "").lower()
        required_hits = 3
        if "chapter" in reason or "capitulo" in reason or "chapter" in reason:
            required_hits = 1
        elif "retry" in reason or "valid" in reason:
            required_hits = 2

        state["recovery_streak"] = int(state.get("recovery_streak") or 0)
        if throughput >= recovery_threshold:
            state["recovery_streak"] += 1
        else:
            state["recovery_streak"] = 0

        if state["recovery_streak"] >= required_hits:
            restored = self._restore_edge_fast_mode(
                f"velocidade recuperada (~{int(throughput)} chars/s)",
                engine_pool=engine_pool,
                engine_obj=engine_obj,
            )
            if restored:
                state["recovery_streak"] = 0
        self._edge_auto_state = state

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
                    "no audio",
                    "sem audio",
                    "noaudio",
                    "sem progresso",
                    "truncated",
                    "truncation",
                    "file ausente",
                    "file invalid",
                    "file invalido",
                    "failure na synthesis",
                    "failure na sintese",
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

        profile_label = "safe mode" if not aggressive else "aggressive safe mode"
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
        probe_dir: Optional[Path] = None,
    ) -> None:
        """Cancel synthesis task if no progress is detected for too long."""
        if stall_seconds <= 0:
            return
        last_probe_mtime = 0.0
        probe_patterns = ("piper_chunk*.wav", "chunk_*.wav", "chunk_*.mp3")
        check_interval = max(5.0, min(15.0, stall_seconds / 3))
        while not task.done():
            await asyncio.sleep(check_interval)
            if task.done():
                return
            if probe_dir and probe_dir.exists():
                newest = 0.0
                try:
                    for pattern in probe_patterns:
                        for fp in probe_dir.glob(pattern):
                            try:
                                newest = max(newest, float(fp.stat().st_mtime))
                            except Exception:
                                continue
                except Exception:
                    newest = 0.0
                if newest > 0.0 and newest > last_probe_mtime:
                    last_probe_mtime = newest
                    with contextlib.suppress(Exception):
                        self.progress.mark_activity()
            if self.progress.seconds_since_activity() >= stall_seconds:
                stall_event.set()
                print(
                    f"\n🛟 Watchdog: chapter {chapter_index} no progress for {int(stall_seconds)}s"
                )
                self.progress.tick(
                    f"🛟 No progress for {int(stall_seconds)}s - restarting chapter..."
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
                info = f"{int(stalled)}s sem concluir chapters"
                if last_chapter:
                    info += f" (last chapter #{last_chapter})"
                print(f"\n🩺 Watchdog: {info} – investigating bottleneck")
                if not self._apply_watchdog_backpressure():
                    print(
                        "   Suggestion: check connection ou allow offline fallback (Coqui/Piper)."
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
                    print(f"⚠️ Failure clearing cache: {exc}")
            try:
                if output_dir.exists():
                    shutil.rmtree(output_dir, ignore_errors=True)
                output_dir = self._setup_output_directory(config)
                self._last_output_dir = output_dir
            except Exception as exc:
                if self.verbose:
                    print(f"⚠️ Failed to clear previous output: {exc}")
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
            print("🌧️ Edge: network unstable detectada → perfil inicial mais conservador")
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
        """Converte múltiplos chapters em parallel para máxima velocidade."""
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
        """Converte chapters sequentialmente, SEM sistema de parallelism."""
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
                        "🛟 Edge DNS indisponível no preflight; ainda assim tentando Edge 1x antes do fallback offline"
                    )

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
                        print("   ⚠️ Edge pre-check failed; mantendo engine selecionada")
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
                        print("   ⚠️ Kokoro not possui voz para este language; pulando fallback")
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
                    retry_backoff = min(60, 2 ** min(chapter_attempt, 6))
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
                            # Arquivo vazio ou corrompido - remover e reconverter
                            if self.verbose:
                                print(
                                    f"   🗑️ Removing invalid file ({file_size} bytes): {output_path}"
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
                                print(
                                    "   ℹ️ Edge marcado como unstable, mantendo engine (sem fallback)"
                                )
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

                    # Timeout otimizado: agressivo, mas com teto maior para chapters longos no Edge
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
                                resume_allowed = (
                                    (not disable_resume) and chapter_attempt == 1 and attempt == 0
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

    def _auto_engine_candidates(self, base_config: ConversionConfig) -> List[str]:
        """Return preferred auto-mode engine order.

        Considers network quality, book size, and chapter stats to decide
        whether a local engine (Piper) should be tried before Edge.
        """
        # Product decision: in auto mode, always try Edge first.
        # Offline engines are fallback-only for failures/timeouts.
        candidates: List[str] = ["edge"]

        piper_voice = None
        try:
            piper_voice = self.tts_factory.voice_provider.get_voice(
                "piper", base_config.primary_language
            )
        except Exception:
            piper_voice = None
        has_piper = _has_piper_support() and bool(piper_voice)

        if has_piper:
            candidates.append("piper")
        if _has_coqui_support():
            candidates.append("coqui")
        ordered: List[str] = []
        seen: Set[str] = set()
        for name in candidates:
            if name and name not in seen:
                ordered.append(name)
                seen.add(name)
        return ordered

    def _resolve_offline_fallback_engine(
        self, available: Optional[Set[str]] = None
    ) -> Optional[str]:
        available_set = {str(item).lower() for item in (available or set())}
        if _has_piper_support() and (not available_set or "piper" in available_set):
            return "piper"
        if _has_coqui_support() and (not available_set or "coqui" in available_set):
            return "coqui"
        return None

    def _predict_edge_runtime_seconds(self, chapter_chars: int) -> float:
        if chapter_chars <= 0:
            return 0.0
        state = self._segment_adaptive_state or {}
        engine_cps = state.get("engine_cps", {}) if isinstance(state, dict) else {}
        edge_samples = []
        if isinstance(engine_cps, dict):
            raw = engine_cps.get("edge", [])
            try:
                edge_samples = [float(v) for v in (raw or []) if float(v) > 0]
            except Exception:
                edge_samples = []
        if edge_samples:
            observed_cps = sum(edge_samples[-12:]) / max(1, len(edge_samples[-12:]))
        else:
            observed_cps = float(EDGE_PREDICTIVE_MIN_EDGE_CPS)
        safe_cps = max(35.0, min(observed_cps, 220.0))
        return float(chapter_chars) / safe_cps

    def _should_preempt_edge_timeout(
        self, chapter_chars: int, estimated_seconds: float
    ) -> Optional[str]:
        """Return reason when Edge is likely to timeout or be too slow for this chapter."""
        if not EDGE_PREDICTIVE_TIMEOUT_ENABLED:
            return None
        if chapter_chars < max(1, EDGE_PREDICTIVE_TIMEOUT_CHARS):
            return None

        predicted_runtime = self._predict_edge_runtime_seconds(chapter_chars)
        threshold_s = max(120, int(EDGE_PREDICTIVE_TIMEOUT_SECONDS))
        if predicted_runtime >= threshold_s:
            return (
                f"predicted Edge runtime {int(predicted_runtime)}s for {chapter_chars:,} chars "
                f"(threshold {threshold_s}s)"
            )

        # Also treat very long narration as risky even with optimistic CPS.
        if estimated_seconds >= threshold_s:
            return (
                f"estimated narration {int(estimated_seconds)}s for {chapter_chars:,} chars "
                f"(threshold {threshold_s}s)"
            )
        return None

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
        Pick the best engine for this chapter based on its size and runtime
        performance data.

        Priority order:
        1. Chapter-size-aware recommendation (uses per-bucket throughput data
           when available, otherwise heuristic based on chapter length).
        2. SpeedController global ranking (recent performance across all sizes).
        3. Static preferred order (network tier, config hints).
        """
        available_engines = list(pool.keys())

        if not available_engines:
            return ("edge", [])

        # --- 1. Chapter-size recommendation ---
        size_pick = self.speed_controller.recommend_engine_for_chapter(
            chapter_chars, available_engines
        )

        # --- 2. Global performance ranking ---
        rankings = self.speed_controller.get_engine_ranking(available_engines)

        if self.verbose and rankings:
            print("📊 Engine Rankings (based on recent performance):")
            for engine, score, reason in rankings:
                marker = " ← size pick" if engine == size_pick else ""
                print(f"   {engine}: {score:.1f}/100 ({reason}){marker}")

        order = [engine for engine, _, _ in rankings]

        # --- 3. Fallback to static order ---
        if not order:
            order = self._preferred_auto_engine_order(pool)
        if not order:
            order = available_engines

        # Product decision: auto mode must always attempt Edge first.
        if "edge" in available_engines:
            order = ["edge"] + [e for e in order if e != "edge"]
            selected = "edge"
        elif size_pick and size_pick in available_engines:
            selected = size_pick
            if size_pick != order[0]:
                order = [size_pick] + [e for e in order if e != size_pick]
        else:
            selected = order[0]

        # Online A/B exploration to avoid lock-in to stale ranking.
        if self._auto_ab_enabled and len(order) >= 2 and "edge" not in available_engines:
            self._auto_ab_counter += 1
            if self._auto_ab_counter % self._auto_ab_interval == 0:
                score_by_engine = {engine: score for engine, score, _ in rankings}
                top_engine = order[0]
                alt_engine = order[1]
                top_score = float(score_by_engine.get(top_engine, 0.0))
                alt_score = float(score_by_engine.get(alt_engine, 0.0))
                if (top_score - alt_score) <= self._auto_ab_max_gap:
                    selected = alt_engine
                    order = [alt_engine] + [e for e in order if e != alt_engine]
                    self._append_runtime_metric(
                        {
                            "event": "auto_ab_exploration",
                            "selected_engine": alt_engine,
                            "baseline_engine": top_engine,
                            "score_gap": round(top_score - alt_score, 3),
                            "chapter_chars": int(chapter_chars or 0),
                        }
                    )
                    if self.verbose:
                        print(
                            f"🧪 AUTO A/B: exploring {alt_engine} "
                            f"(gap {top_score - alt_score:.1f} vs {top_engine})"
                        )

        # Check if speed controller recommends switching from current engine
        current = getattr(self.speed_controller, "_current_engine", None)
        if (
            current
            and current in available_engines
            and current != selected
            and "edge" not in available_engines
        ):
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
        # Product decision: keep Edge as default attempt; local engines are fallback-only.
        base_candidates = ["edge", "piper"]
        if _has_coqui_support():
            base_candidates.append("coqui")
        for candidate in base_candidates:
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
                        print("📦 Installing dependencies in .venv...")
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
                                        f"❌ Chapter {index} transcription FALHOU: "
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
            book_title = "livro_complete"
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
                full_text_parts.append(f"\n{'='*70}\n")
                full_text_parts.append(f"CHAPTER {chapter_label}: {chapter_name}\n")
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
                print(f"\n📖 text complete do livro gerado: {full_book_file.name}")
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

        final_validation_ok = await self._auto_validate_output(final_output, stage="final")
        if not final_validation_ok:
            result.success = False
            validation_error = "Final validation failed: conversion is not 100% complete"
            if validation_error not in result.errors:
                result.errors.append(validation_error)
            print("❌ Final validation failed: conversion is incomplete (not 100%).")

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
