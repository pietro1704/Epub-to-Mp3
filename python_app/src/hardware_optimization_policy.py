"""Derive conversion budgets and apply legacy runtime optimization policy."""

from __future__ import annotations

import contextlib
import os
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .hardware_detector import HardwareProfile


def calculate_recommendations(profile: HardwareProfile) -> None:
    """Calculate optimal settings based on hardware profile."""

    # Performance tier calculation
    score = 0

    # CPU scoring (0-40 points)
    if profile.cpu_physical >= 8:
        score += 40
    elif profile.cpu_physical >= 4:
        score += 30
    elif profile.cpu_physical >= 2:
        score += 20
    else:
        score += 10

    # RAM scoring (0-30 points)
    if profile.ram_total_gb >= 16:
        score += 30
    elif profile.ram_total_gb >= 8:
        score += 20
    elif profile.ram_total_gb >= 4:
        score += 10
    else:
        score += 5

    # CPU frequency scoring (0-20 points)
    if profile.cpu_freq_max >= 3000:
        score += 20
    elif profile.cpu_freq_max >= 2500:
        score += 15
    elif profile.cpu_freq_max >= 2000:
        score += 10
    else:
        score += 5

    # GPU bonus (0-10 points)
    if profile.has_gpu:
        score += 10

    # Determine tier (lower thresholds for better classification)
    if score >= 70:  # Reduced from 80
        profile.performance_tier = "ultra"
    elif score >= 50:  # Reduced from 60
        profile.performance_tier = "high"
    elif score >= 35:  # Reduced from 40
        profile.performance_tier = "medium"
    else:
        profile.performance_tier = "low"

    # RAM is the hard ceiling for real-world throughput: a low-RAM machine
    # (e.g. an 8 GiB Intel laptop) can score "high" on CPU/freq yet only
    # keep ~2 GiB free, so aggressive segment/chapter concurrency thrashes
    # memory and — on shared egress IPs — trips Edge rate-limiting. The
    # score-based tier does not model absolute RAM, so cap the tier by
    # total RAM regardless of CPU score. This is deliberately conservative
    # for <=8 GiB hosts; override with a larger machine or explicit flags.
    ram_tier_cap = None
    if profile.ram_total_gb < 6:
        ram_tier_cap = "low"
    elif profile.ram_total_gb <= 8:
        # <=8 GiB (e.g. 8 GiB Intel laptop): cap at "medium" so segment
        # concurrency lands around 6 instead of 10-12, which on this class
        # of machine means fewer Edge rate-limit retries (net faster) and
        # no memory thrash.
        ram_tier_cap = "medium"
    elif profile.ram_total_gb <= 12:
        # 8-12 GiB: allow "high" but never "ultra".
        ram_tier_cap = "high"
    if ram_tier_cap is not None:
        _tier_rank = {"low": 0, "medium": 1, "high": 2, "ultra": 3}
        if _tier_rank[profile.performance_tier] > _tier_rank[ram_tier_cap]:
            profile.performance_tier = ram_tier_cap

    # Concurrency and memory budgets
    if profile.performance_tier == "ultra":
        target_ratio = 0.92
        reserve_for_os = 0.25
    elif profile.performance_tier == "high":
        target_ratio = 0.88
        reserve_for_os = 0.35
    elif profile.performance_tier == "medium":
        target_ratio = 0.80
        reserve_for_os = 0.45
    else:
        target_ratio = 0.72
        reserve_for_os = 0.6

    raw_budget = profile.ram_total_gb * target_ratio
    available_budget = profile.ram_available_gb * 0.95
    hard_cap = max(0.25, profile.ram_total_gb - reserve_for_os)
    hard_cap = min(hard_cap, profile.ram_total_gb * 0.98)

    # **FIX**: When available RAM is much lower than total RAM (e.g., <50%),
    # prioritize available RAM to prevent OOM kills
    ram_utilization = profile.ram_available_gb / profile.ram_total_gb
    if ram_utilization < 0.5:
        # Low available RAM - be conservative and prioritize available budget
        usable_ram = max(0.25, min(available_budget, hard_cap))
    else:
        # Normal situation - use the more aggressive budget
        usable_ram = max(0.25, min(max(raw_budget, available_budget), hard_cap))

    profile.ram_budget_gb = round(usable_ram, 2)

    sequential_signals = 0
    if profile.cpu_physical <= 2:
        sequential_signals += 1
    if profile.ram_total_gb <= 4:
        sequential_signals += 1
    if usable_ram <= 1.25:
        sequential_signals += 1
    if profile.performance_tier == "low":
        sequential_signals += 1
    if profile.performance_tier == "medium" and profile.cpu_freq_max < 2000:
        sequential_signals += 1

    sequential_threshold = 2
    if profile.performance_tier in ("high", "ultra") or (
        profile.cpu_physical >= 4 and profile.ram_total_gb >= 6
    ):
        sequential_threshold = 3

    profile.force_sequential = sequential_signals >= sequential_threshold
    profile.recommended_parallel = not profile.force_sequential

    if profile.performance_tier == "ultra":
        base_concurrency = max(6, min(profile.cpu_count, profile.cpu_physical * 3))
    elif profile.performance_tier == "high":
        base_concurrency = max(6, min(profile.cpu_count, profile.cpu_physical * 2 + 2))
    elif profile.performance_tier == "medium":
        base_concurrency = max(4, int(profile.cpu_physical * 1.5))
    else:
        base_concurrency = max(2, profile.cpu_physical)

    ram_per_segment = 0.18 if profile.performance_tier in ("high", "ultra") else 0.24
    ram_limit = max(1, int(usable_ram / ram_per_segment))
    profile.recommended_concurrency = max(
        4, min(12, min(base_concurrency, ram_limit))
    )  # Minimum 4, maximum 12

    if profile.force_sequential:
        profile.recommended_concurrency = min(
            profile.recommended_concurrency, max(2, profile.cpu_physical)
        )

    if profile.force_sequential:
        chapter_parallel = 1
    else:
        # **FIX**: When available RAM is low, be more conservative with chapter parallelism
        ram_utilization = profile.ram_available_gb / profile.ram_total_gb
        memory_pressure_factor = 1.0
        if ram_utilization < 0.5:
            # Low available RAM - reduce parallelism more conservatively
            memory_pressure_factor = 1.5  # Increase RAM per chapter requirement

        if profile.performance_tier == "ultra":
            ram_per_chapter = 0.35 * memory_pressure_factor
            hard_chapter_cap = 8  # Increased from 6 to 8
            cpu_guardrail = profile.cpu_physical + 2
            min_parallel = 4  # Increased from 3 to 4
        elif profile.performance_tier == "high":
            ram_per_chapter = 0.4 * memory_pressure_factor
            hard_chapter_cap = 6  # Increased from 5 to 6
            cpu_guardrail = profile.cpu_physical + 1
            min_parallel = 3  # Always 3 instead of 2-3
        elif profile.performance_tier == "medium":
            ram_per_chapter = 0.55 * memory_pressure_factor
            hard_chapter_cap = 5  # Increased from 4 to 5
            cpu_guardrail = max(3, profile.cpu_physical)  # Minimum 3
            min_parallel = 2  # Always 2 instead of 1-2
        else:
            ram_per_chapter = 0.75 * memory_pressure_factor
            hard_chapter_cap = 3  # Increased from 2 to 3
            cpu_guardrail = max(2, profile.cpu_physical)  # Minimum 2
            min_parallel = 2  # Increased from 1 to 2

        # **FIX**: Also reduce min_parallel when memory is tight
        if ram_utilization < 0.5:
            min_parallel = max(1, min_parallel - 1)

        raw_parallel = max(1, int(usable_ram / ram_per_chapter))
        chapter_parallel = min(hard_chapter_cap, raw_parallel, max(1, cpu_guardrail))

        if (
            profile.performance_tier in ("high", "ultra")
            and profile.ram_total_gb >= 8
            and usable_ram >= 1.5
        ):
            chapter_parallel = max(min_parallel, chapter_parallel)
        else:
            chapter_parallel = max(min_parallel, chapter_parallel)

    profile.recommended_chapter_parallel = max(1, chapter_parallel)


def apply_optimizations(profile: HardwareProfile, *, network_profiles, thermal_cap) -> None:
    """Apply optimizations to environment."""

    def _env_truthy(name: str, default: bool = False) -> bool:
        raw = os.getenv(name)
        if raw is None:
            return default
        return raw.strip().lower() in {"1", "true", "on", "yes"}

    def _env_int(name: str, default: int) -> int:
        raw = os.getenv(name)
        if raw is None:
            return default
        raw = raw.strip()
        if raw == "":
            return default
        try:
            return int(raw)
        except ValueError:
            return default

    def _env_float(name: str, default: float) -> float:
        raw = os.getenv(name)
        if raw is None or raw.strip() == "":
            return default
        try:
            return float(raw)
        except ValueError:
            return default

    def _set_env_max(name: str, minimum: int) -> None:
        current = os.getenv(name)
        try:
            if current is None or int(current) < minimum:
                os.environ[name] = str(minimum)
        except ValueError:
            os.environ[name] = str(minimum)

    turbo_mode = _env_truthy("MAX_PERFORMANCE", True)  # Turbo mode ALWAYS active by default

    edge_concurrency = profile.recommended_concurrency
    chapter_parallel = profile.recommended_chapter_parallel
    requested_edge_concurrency = os.getenv("EDGE_MAX_CONCURRENCY")
    explicit_edge_override = bool(
        requested_edge_concurrency
        and requested_edge_concurrency.strip()
        and requested_edge_concurrency.strip() != "0"
    )
    requested_chapter_parallel = os.getenv("CHAPTER_PARALLEL_COUNT")
    explicit_chapter_override = bool(
        requested_chapter_parallel
        and requested_chapter_parallel.strip()
        and requested_chapter_parallel.strip() != "0"
    )

    if turbo_mode:
        # **PERFORMANCE**: Increase to use maximum available CPU/RAM
        if profile.performance_tier in ("ultra", "high"):
            edge_concurrency = max(edge_concurrency, 16)  # Increased from 10 to 16
            chapter_parallel = max(chapter_parallel, 8)  # Increased from 5 to 8
        elif profile.performance_tier == "medium":
            edge_concurrency = max(edge_concurrency, 12)  # Increased from 7 to 12
            chapter_parallel = max(chapter_parallel, 6)  # Increased from 3 to 6
        else:
            edge_concurrency = max(edge_concurrency, 8)  # Increased from 5 to 8
            chapter_parallel = max(chapter_parallel, 4)  # Increased from 2 to 4

    if explicit_chapter_override:
        chapter_parallel = max(1, _env_int("CHAPTER_PARALLEL_COUNT", chapter_parallel))

    # Keep chapter-level pressure protection separate from Edge request concurrency.
    # An explicit operator value remains authoritative and is reported downstream.
    pressure_ram_gb = _env_float("RESOURCE_PRESSURE_RAM_GB", 0.65)
    if not explicit_chapter_override and (
        profile.ram_total_gb <= 8.5 or profile.ram_available_gb <= pressure_ram_gb
    ):
        chapter_parallel = min(chapter_parallel, 2)

    network_tier = (profile.network_speed_estimate or "fast").strip().lower()
    edge_profile = dict(
        network_profiles.get(
            network_tier,
            network_profiles["fast"],
        )
    )
    turbo_min_concurrency = _env_int("EDGE_TURBO_MIN_CONCURRENCY", 8)
    turbo_chunk_chars = _env_int("EDGE_TURBO_CHUNK_CHARS", 4000)
    turbo_segment_seconds = _env_int("EDGE_TURBO_MAX_SEGMENT_SECONDS", 45)
    turbo_ignore_caps = _env_truthy("EDGE_TURBO_IGNORE_NETWORK_CAPS", True)

    if turbo_mode:
        edge_profile["chunk_chars"] = max(
            int(edge_profile.get("chunk_chars") or 0), turbo_chunk_chars
        )
        edge_profile["max_segment_seconds"] = max(
            int(edge_profile.get("max_segment_seconds") or 0),
            turbo_segment_seconds,
        )
        edge_profile["edge_parallel"] = True
    try:
        scaled = float(edge_profile.get("concurrency_scale", 1.0))
    except (TypeError, ValueError):
        scaled = 1.0
    edge_concurrency = max(1, int(round(edge_concurrency * scaled)))
    try:
        cap = int(edge_profile.get("concurrency_cap", edge_concurrency))
    except (TypeError, ValueError):
        cap = edge_concurrency
    edge_concurrency = max(1, min(edge_concurrency, cap))
    if turbo_mode:
        if turbo_ignore_caps:
            edge_concurrency = max(edge_concurrency, turbo_min_concurrency)
        else:
            edge_concurrency = max(edge_concurrency, min(turbo_min_concurrency, cap))

    os.environ["EDGE_MAX_CONCURRENCY"] = str(edge_concurrency)
    os.environ["EDGE_MAX_CONCURRENCY_SOURCE"] = (
        "explicit" if explicit_edge_override else "detected"
    )
    os.environ["CHAPTER_PARALLEL_COUNT"] = str(chapter_parallel)
    os.environ["CHAPTER_PARALLEL_COUNT_SOURCE"] = (
        "explicit" if explicit_chapter_override else "detected"
    )
    os.environ["EDGE_FORCE_SEQUENTIAL"] = "true" if profile.force_sequential else "false"
    os.environ["EDGE_CHUNK_CHARS"] = str(edge_profile.get("chunk_chars", 20000))
    os.environ["EDGE_MAX_SEGMENT_SECONDS"] = str(edge_profile.get("max_segment_seconds", 75))
    os.environ["EDGE_ENABLE_PARALLEL"] = (
        "true" if edge_profile.get("edge_parallel", True) else "false"
    )
    if turbo_mode:
        os.environ.setdefault("EDGE_MAX_CONCURRENCY_CAP", str(max(8, turbo_min_concurrency)))

    # Set other performance hints
    if profile.performance_tier in ("ultra", "high"):
        os.environ["EDGE_AGGRESSIVE_MODE"] = "false"  # Parallel mode is better

    # Platform-specific optimizations
    if profile.is_macos and not profile.has_gpu:
        # Mac without dedicated GPU - use efficient settings
        # Intel Macs benefit from slightly lower concurrency
        if "Intel" in profile.cpu_brand:
            adjusted = max(2, edge_concurrency - 1)
            os.environ["EDGE_MAX_CONCURRENCY"] = str(adjusted)

    if turbo_mode:
        # **PERFORMANCE**: More workers for maximum CPU utilization
        desired_workers = max(
            2,
            min(
                16,  # Increased from 8 to 16
                profile.cpu_physical * 2,  # Use logical cores
                chapter_parallel * 2,
            ),
        )
        _set_env_max("JOB_WORKERS", desired_workers)

    piper_procs = max(1, min(6, max(2, (profile.cpu_physical or 1) // 2)))
    if profile.performance_tier in ("high", "ultra"):
        piper_procs = max(piper_procs, 3)
    os.environ["PIPER_MAX_PROCS"] = str(piper_procs)

    with contextlib.suppress(Exception):
        from .benchmark_profile import apply_global_overrides

        apply_global_overrides()

    # macOS thermal/power hint for runtime guard (converter polls dynamically too).
    if profile.is_macos:
        cap, mode = thermal_cap(
            int(os.getenv("CHAPTER_PARALLEL_COUNT", str(chapter_parallel)) or chapter_parallel)
        )
        os.environ["THERMAL_PARALLEL_CAP"] = str(cap)
        os.environ["THERMAL_POWER_MODE"] = mode
