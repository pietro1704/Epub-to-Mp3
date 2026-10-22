# -*- coding: utf-8 -*-
"""Converter resources, initialization and result reporting."""

from __future__ import annotations

import asyncio
import weakref
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

from .adaptive_performance import AdaptivePerformanceController
from .auto_tuner import AutoTuner
from .config import ConversionConfig
from .converter_models import ConversionResult
from .ebook_reader import Chapter
from .hardware_detector import HardwareProfile
from .i18n import Localization


class ConverterLifecycle:
    """Converter resources, initialization and result reporting."""

    # Resource annotations belong to this owner, even when construction is
    # routed through the converter facade to preserve runtime monkeypatching.
    hardware_profile: Optional[HardwareProfile]
    _auto_tuner: Optional[AutoTuner]
    _adaptive_controller: Optional[AdaptivePerformanceController]
    _thread_pools: List[weakref.ref]

    def __init__(self, localization: Optional[Localization] = None) -> None:
        from . import converter as _runtime
        self.tts_factory = _runtime.TTSFactory()
        self.audio_processor = _runtime.AudioProcessor()
        self.file_manager = _runtime.FileManager()
        self.progress = _runtime.ProgressTracker()
        self.cache_manager = _runtime.CacheManager()
        self.speed_controller = _runtime.AdaptiveSpeedController()
        self._requirements_attempted = False
        self.loc = localization or _runtime.get_localization()
        self.verbose = False
        self._current_book_path: Optional[Path] = None
        self._active_config: Optional[ConversionConfig] = None
        self._runtime_run_id = ""
        self._runtime_metric_dedupe: Dict[str, Dict[str, Any]] = {}
        # Persistent chapter checkpoint — survives process restarts
        self._checkpoint_done_set: set[int] = set()
        self._checkpoint_total: int = 0
        self._checkpoint_interval: int = int(_runtime.os.getenv("CHECKPOINT_INTERVAL", "5"))
        self._auto_fix_guard: bool = False
        self._final_validation_passed: bool = True
        self._last_validation_stats: Optional[Dict[str, int]] = None
        self._last_validation_issues: Optional[List[str]] = None
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
        # Track in-flight chapter tasks so the health watchdog can force-cancel
        # stuck chapters once backpressure alone can't unstick the pipeline.
        self._inflight_chapter_tasks: set = set()
        self._auto_tuner: Optional[AutoTuner] = None
        self._auto_tuning_enabled = _runtime._env_bool("ENABLE_AUTO_TUNING", True)
        self._auto_tuning_initialized = False
        self._adaptive_controller: Optional[AdaptivePerformanceController] = None
        self._adaptive_enabled = _runtime._env_bool(
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
            "pre_check_base_interval": max(1, _runtime._env_int("PRE_SEGMENT_CHECK_BASE_INTERVAL", 1)),
            "pre_check_max_interval": max(1, _runtime._env_int("PRE_SEGMENT_CHECK_MAX_INTERVAL", 4)),
            "pre_check_promote_streak": max(2, _runtime._env_int("PRE_SEGMENT_CHECK_PROMOTE_STREAK", 6)),
        }
        self._edge_circuit_state: Dict[str, Any] = {
            "open": False,
            "failures": 0,
            "threshold": 2,
            "opened_at": 0.0,
            "cooldown_seconds": 900.0,
            "last_reason": "",
        }
        self._auto_ab_enabled = _runtime._env_bool("AUTO_ENGINE_AB_ENABLED", True)
        self._auto_ab_interval = max(2, _runtime._env_int("AUTO_ENGINE_AB_INTERVAL", 6))
        self._auto_ab_max_gap = max(1.0, _runtime._env_float("AUTO_ENGINE_AB_MAX_GAP", 15.0))
        self._auto_ab_counter = 0
        self._resource_budget_enabled = _runtime._env_bool("ENGINE_RESOURCE_BUDGET_ENABLED", True)
        self._engine_resource_budget: Dict[str, Dict[str, int]] = {}
        self._resource_budget_min_share = max(
            0.15, min(0.8, _runtime._env_float("ENGINE_RESOURCE_BUDGET_MIN_SHARE", 0.3))
        )
        self._best_param_store = _runtime.PerformanceProfileStore()
        self._persist_best_params = _runtime._env_bool("PERSIST_BEST_ENGINE_PARAMS", True)
        # Warmup is opt-in to avoid changing synthesis semantics unexpectedly.
        self._warmup_before_first_chapter = _runtime._env_bool("ENGINE_WARMUP_ENABLED", False)
        self._engine_warmup_done: Set[str] = set()
        self._warm_start_enabled = _runtime.ENGINE_WARM_START_ENABLED
        self._warm_start_ttl_seconds = _runtime.ENGINE_WARM_START_TTL_SECONDS
        self._warm_start_path = self._best_param_store.path.with_name("engine-warm-start.json")
        self._eta_baseline_path = self._best_param_store.path.with_name("eta-baselines.json")
        self._eta_baseline_key: Optional[str] = None
        self._startup_guardrail_path = self._best_param_store.path.with_name(
            "startup-guardrail.json"
        )
        self._startup_guardrail_applied = False
        self._canary_profile_done = False
        self._chapter_prefetch_enabled = _runtime._env_bool("CHAPTER_PREFETCH_ENABLED", True)
        self._adaptive_checkpoint_enabled = _runtime._env_bool("ADAPTIVE_STATE_CHECKPOINT_ENABLED", True)
        self._adaptive_checkpoint_interval = max(
            1, _runtime._env_int("ADAPTIVE_STATE_CHECKPOINT_INTERVAL", 1)
        )
        self._adaptive_checkpoint_dirty = 0
        thermal_cap_env = _runtime._env_int("THERMAL_PARALLEL_CAP", 0)
        self._thermal_guard_state: Dict[str, Any] = {
            "last_poll": 0.0,
            "poll_interval": max(10.0, _runtime._env_float("THERMAL_GUARD_POLL_SECONDS", 20.0)),
            "cap": thermal_cap_env if thermal_cap_env > 0 else None,
            "mode": str(_runtime.os.getenv("THERMAL_POWER_MODE", "normal") or "normal"),
        }

    def _optimize_memory_settings(self) -> None:
        """
        Optimize memory settings for better performance.

        - Enables aggressive garbage collection
        - Sets memory limits on macOS/Linux
        - Optimizes thread stack size
        """
        from . import converter as _runtime
        if self._memory_optimized:
            return

        try:
            # Enable aggressive garbage collection to reduce memory peaks
            _runtime.gc.set_threshold(700, 10, 5)  # More aggressive than default (700, 10, 10)

            # On Unix systems, limit memory growth
            if hasattr(_runtime.resource, "RLIMIT_AS"):
                try:
                    # Get available memory
                    available_mem = _runtime.psutil.virtual_memory().available
                    # Set soft limit to 80% of available memory
                    mem_limit = int(available_mem * 0.8)
                    _runtime.resource.setrlimit(_runtime.resource.RLIMIT_AS, (mem_limit, mem_limit))
                except (ValueError, OSError):
                    pass  # Ignore if we can't set limits

            # Reduce thread stack size for better memory efficiency
            try:
                _runtime.threading.stack_size(1024 * 1024)  # 1MB stack (default is often 8MB)
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
        from . import converter as _runtime
        try:
            # Clean up dead thread pool references
            self._thread_pools = [ref for ref in self._thread_pools if ref() is not None]

            # Clear temporary validation data
            if hasattr(self, "_text_validation_hashes"):
                if len(self._text_validation_hashes) > 100:  # Clear if too large
                    self._text_validation_hashes.clear()

            # Force garbage collection if requested or if memory usage is high
            if force_gc:
                _runtime.gc.collect(generation=2)  # Full collection
            else:
                # Check memory usage and collect if high
                mem = _runtime.psutil.virtual_memory()
                if mem.percent > 80:  # If using more than 80% of RAM
                    _runtime.gc.collect(generation=1)  # Collect generations 0 and 1

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
        from . import converter as _runtime
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
        warmup_chars = max(160, _runtime._env_int("ENGINE_WARMUP_CHARS", 420))
        warmup_text = ("Warmup segment. " * 40)[:warmup_chars]
        warmup_timeout = max(10.0, _runtime._env_float("ENGINE_WARMUP_TIMEOUT_SECONDS", 45.0))
        warmup_dir = _runtime.Path(output_dir) / ".warmup"
        warmup_dir.mkdir(parents=True, exist_ok=True)
        warmup_path = self._warmup_output_path(warmup_dir, engine_name)
        try:
            await _runtime.asyncio.wait_for(
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
            with _runtime.contextlib.suppress(Exception):
                if warmup_path.exists():
                    warmup_path.unlink()

    async def _initialize_auto_tuning(self) -> None:
        """Initialize performance auto-tuning based on HW and network."""
        from . import converter as _runtime
        if self._auto_tuning_initialized or not self._auto_tuning_enabled:
            return

        try:
            self._auto_tuner = _runtime.AutoTuner(verbose=self.verbose)

            # Only measure network if not in batch/silent mode
            measure_network = self.verbose and _runtime._env_bool("AUTO_TUNE_MEASURE_NETWORK", True)

            # Auto-configure (does not overwrite manually set vars)
            await self._auto_tuner.auto_configure(force=False, measure_network=measure_network)

            # Kick off the Piper fallback model download in the background so
            # it overlaps with auto-tuning / network probing. When the fallback
            # actually triggers mid-conversion the model is already on disk.
            self._kick_off_piper_prefetch()

            self._auto_tuning_initialized = True

        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Auto-tuning failed (using default configs): {exc}")

    def _kick_off_piper_prefetch(self) -> None:
        """Best-effort, fire-and-forget pre-download of the Piper fallback model.

        Runs in a background thread so it overlaps with auto-tuning, engine
        warmup, and EPUB parsing. The TTSFactory's own download path is a
        no-op when the file already exists, so a hit here simply removes
        latency the first time Piper fallback is actually needed.
        """
        from . import converter as _runtime
        if _runtime.os.getenv("DISABLE_PIPER_FALLBACK", "").strip().lower() in {"1", "true", "yes"}:
            return
        if str(getattr(self, "_cli_fallback_engine", "") or "").lower() != "piper":
            return
        if getattr(self, "_piper_prefetch_started", False):
            return
        self._piper_prefetch_started = True

        def _run() -> None:
            try:
                from .tts.factory import TTSFactory

                preferred = _runtime.os.getenv("PIPER_PREFETCH_LANG", "pt")
                TTSFactory()._download_default_piper_model(preferred)
            except Exception:
                # Prefetch is best-effort; factory will retry on real use.
                return

        try:
            import threading

            threading.Thread(target=_run, name="piper-prefetch", daemon=True).start()
        except Exception:
            pass

    def _initialize_adaptive_performance(self) -> None:
        """Initialize adaptive performance controller."""
        from . import converter as _runtime
        if not self._adaptive_enabled:
            return

        try:
            self._adaptive_controller = _runtime.AdaptivePerformanceController(verbose=self.verbose)
            self._adaptive_controller.start_conversion()
        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Adaptive Performance failed (continuing without adjustments): {exc}")
            self._adaptive_controller = None

    async def _report_results(self, result: ConversionResult) -> None:
        from . import converter as _runtime
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
            _runtime.Path(self._active_config.output_dir) if self._active_config else None
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
            stats = self._last_validation_stats
            if stats:
                bad_buckets = {
                    key: count
                    for key, count in stats.items()
                    if key != "perfect" and key != "total_chapters" and count
                }
                if bad_buckets:
                    breakdown = ", ".join(f"{k}={v}" for k, v in sorted(bad_buckets.items()))
                    validation_error += f" ({breakdown})"
            if validation_error not in result.errors:
                result.errors.append(validation_error)
            print(f"❌ {validation_error}")

    def _announce_stage(self, index: int, chapter_name: str, status: str) -> None:
        clean_status = status.strip()
        if not clean_status:
            return
        print(f"   → [{index}] {chapter_name}: {clean_status}", flush=True)

    @staticmethod
    def _should_reduce_parallel(outcome) -> bool:
        from . import converter as _runtime
        return isinstance(outcome, _runtime.ChapterConversionOutcome) and bool(outcome.slowdown)

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
