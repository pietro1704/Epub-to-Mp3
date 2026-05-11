"""Engine selection, performance profiles, voice/language configuration helpers.

These are extracted from server.py to reduce its line count.  All server-level
globals (_has_piper_support, telemetry, tts_factory, …) are accessed via a
lazy import to avoid circular-import issues.
"""

from __future__ import annotations

import os
from dataclasses import replace
from typing import Dict, Optional

from src.config import ConversionConfig
from src.hardware_detector import HardwareProfile


def _piper_fallback_disabled() -> bool:
    return os.getenv("DISABLE_PIPER_FALLBACK", "").strip().lower() in ("1", "true", "yes")


def _engine_chain_fallback_enabled(config: Optional[object] = None) -> bool:
    """Whether to append offline engine tiers (piper) after Edge.

    Defaults to ``False``: the project's priority is to maximise Edge usage
    in both CLI and web paths, with per-chunk fallback handling isolated
    failures and the monolingual Edge tier absorbing multilingual hiccups.
    Opt back in with ``ENGINE_CHAIN_FALLBACK=1`` when operators explicitly
    want the legacy cascading behaviour (for example on HF Spaces where
    Edge is being rate-limited for a whole job).

    If ``config`` exposes ``engine_chain_fallback`` (the per-job override set
    from the web UI toggle), it wins over the env var so jobs can opt in
    without polluting process state across concurrent conversions.
    """
    if config is not None:
        override = getattr(config, "engine_chain_fallback", None)
        if override is not None:
            return bool(override)
    return os.getenv("ENGINE_CHAIN_FALLBACK", "").strip().lower() in ("1", "true", "yes")


def _fallback_engine_override() -> Optional[str]:
    """Return the operator-configured fallback engine override, if any.

    Mirrors the CLI's ``--fallback-engine`` flag on the server path: when set,
    the server's engine chain is constrained accordingly.

    ``FALLBACK_ENGINE_OVERRIDE=none`` strips all offline fallbacks; setting it
    to ``piper`` keeps only that tier.
    Unknown / empty values return None (no override → current ranking wins).
    """
    raw = (os.getenv("FALLBACK_ENGINE_OVERRIDE") or "").strip().lower()
    if not raw or raw == "auto":
        return None
    if raw in {"none", "piper"}:
        return raw
    return None


def degrade_edge_chunk_chars(
    current: Optional[int],
    *,
    floor: int = 4000,
    cap: int = 8000,
    shrink_factor: float = 0.8,
) -> int:
    """Compute a reduced ``edge_chunk_chars`` for safe/degraded mode.

    Shared by both conversion paths (``converter.py`` startup guardrail and
    ``server.py`` slow-mode entry) so the same config degrades to the same
    value regardless of entry point — avoids CLI vs Web divergence.

    The result is ``current * shrink_factor`` clamped to ``[floor, cap]``.
    ``current`` falling back to ``cap`` when missing or non-positive keeps
    callers from accidentally shrinking to the floor.
    """
    base = int(current) if current and int(current) > 0 else cap
    shrunk = int(base * shrink_factor)
    return max(floor, min(cap, shrunk))


# ---------------------------------------------------------------------------
# Performance profile helpers
# ---------------------------------------------------------------------------


def _infer_perf_profile(hw: HardwareProfile, choice: str, is_space: bool) -> str:
    """Infer performance profile automatically (HF vs local vs CLI)."""
    if choice in {"hf", "local", "cli"}:
        return choice
    if is_space:
        return "hf"
    # Small CPUs behave like HF; bigger boxes can run CLI mode safely
    if (hw.cpu_physical or 0) <= 4 and not hw.has_gpu:
        return "local"
    return "cli"


def _set_default(name: str, value: str) -> None:
    if not os.getenv(name):
        os.environ[name] = value


def _apply_perf_defaults(profile: str, hw: HardwareProfile) -> None:
    """Auto-apply sane defaults per profile without overriding explicit envs."""
    if profile == "hf":
        # HF Spaces uses shared egress IPs — many Spaces share the same Edge-TTS
        # rate-limit budget. Minimize request count:
        #   - 1 concurrent request (no parallel Edge chunks within a chapter)
        #   - Larger chunks (12K chars) → fewer requests per chapter
        #   - 1 chapter at a time to avoid compounding rate limits
        _set_default("EDGE_MAX_CONCURRENCY", "1")
        _set_default("EDGE_MAX_CONCURRENCY_CAP", "2")
        _set_default("CHAPTER_PARALLEL_COUNT", "1")
        _set_default("CHAPTER_PARALLEL_MAX", "1")
        _set_default("EDGE_CHUNK_CHARS", "12000")  # was 9000 — fewer requests
        _set_default("EDGE_MAX_SEGMENT_SECONDS", "180")
        _set_default("EDGE_ENABLE_PARALLEL", "false")  # force serial chunks
        _set_default("PIPER_MAX_PROCS", "1")
        # Healthcheck: detect rate-limit slowdowns faster on HF
        _set_default("JOB_HEALTHCHECK_INTERVAL_SECONDS", "10")
        _set_default("JOB_HEALTHCHECK_SLOW_STREAK", "1")
        # Safe mode (fallback when Edge is slow): use very small chunks on HF
        # so each request completes quickly and rate limits clear faster.
        _set_default("EDGE_SAFE_CHUNK_CHARS", "5000")
        _set_default("EDGE_SAFE_MAX_SEGMENT_SECONDS", "120")
        _set_default("EDGE_SAFE_CHAPTER_PARALLEL", "1")
        _set_default("EDGE_SAFE_TIMEOUT_MAX", "180")
    elif profile == "cli":
        # Favor throughput on multi-core hosts while keeping caps sane
        edge_cap = max(4, min(8, (hw.cpu_physical or 2) * 2))
        _set_default("EDGE_MAX_CONCURRENCY", str(min(6, edge_cap)))
        _set_default("EDGE_MAX_CONCURRENCY_CAP", str(edge_cap))
        _set_default("CHAPTER_PARALLEL_COUNT", str(min(4, max(2, (hw.cpu_physical or 2) // 2 + 1))))
        _set_default("CHAPTER_PARALLEL_MAX", str(min(6, (hw.cpu_physical or 2) * 2)))
        _set_default("EDGE_CHUNK_CHARS", "11000")
        _set_default("EDGE_MAX_SEGMENT_SECONDS", "300")
        _set_default("EDGE_ENABLE_PARALLEL", "true")
        _set_default("EDGE_SAFE_CHUNK_CHARS", "4000")
        _set_default("EDGE_SAFE_MAX_SEGMENT_SECONDS", "90")
        _set_default("EDGE_SAFE_CHAPTER_PARALLEL", "1")
        _set_default("EDGE_SAFE_TIMEOUT_MAX", "120")
        _set_default("PIPER_MAX_PROCS", str(min(4, max(2, (hw.cpu_physical or 2) // 2 + 1))))
    else:  # local (balanced default)
        edge_cap = max(3, min(6, (hw.cpu_physical or 2) + 2))
        _set_default("EDGE_MAX_CONCURRENCY", str(edge_cap - 1))
        _set_default("EDGE_MAX_CONCURRENCY_CAP", str(edge_cap))
        _set_default("CHAPTER_PARALLEL_COUNT", "2")
        _set_default("CHAPTER_PARALLEL_MAX", "3")
        _set_default("EDGE_CHUNK_CHARS", "10000")
        _set_default("EDGE_MAX_SEGMENT_SECONDS", "240")
        _set_default("EDGE_ENABLE_PARALLEL", "true")
        _set_default("EDGE_SAFE_CHUNK_CHARS", "4000")
        _set_default("EDGE_SAFE_MAX_SEGMENT_SECONDS", "90")
        _set_default("EDGE_SAFE_CHAPTER_PARALLEL", "1")
        _set_default("EDGE_SAFE_TIMEOUT_MAX", "120")
        _set_default("PIPER_MAX_PROCS", "2")


# ---------------------------------------------------------------------------
# Voice / language normalisation
# ---------------------------------------------------------------------------


def _normalise_languages(
    primary_language: Optional[str], languages: Optional[list[str]] = None
) -> list[str]:
    values: list[str] = []
    if languages:
        for lang in languages:
            clean = (lang or "").strip()
            if clean:
                values.append(clean)
    primary = (primary_language or "").strip()
    if primary and primary.lower() != "auto":
        values.insert(0, primary)
    normalised: list[str] = []
    for lang in values:
        if lang not in normalised:
            normalised.append(lang)
    return normalised


def _ensure_voice_and_languages(config: ConversionConfig) -> None:
    from python_app import server as _srv  # lazy to avoid circular import

    languages = _normalise_languages(config.primary_language, config.languages)
    config.languages = languages
    provider = _srv.tts_factory.voice_provider
    fallback_voice = config.voice or provider.get_voice(config.engine, config.primary_language)
    config.voice = fallback_voice
    config.language_voices = provider.build_language_voice_map(
        config.engine,
        languages,
        fallback_voice,
        primary_language=config.primary_language,
    )


def _clone_config_for_engine(base: ConversionConfig, engine_name: str) -> ConversionConfig:
    cloned = replace(base, engine=engine_name, voice=None, model_path=None)
    cloned.languages = list(base.languages)
    cloned.language_voices = {}
    _ensure_voice_and_languages(cloned)
    return cloned


# ---------------------------------------------------------------------------
# Engine chain / auto pool
# ---------------------------------------------------------------------------


def _build_engine_chain(config: ConversionConfig) -> list[ConversionConfig]:
    from python_app import server as _srv  # lazy to avoid circular import

    _ensure_voice_and_languages(config)
    chain = [config]

    def _rank_fallbacks(candidates: list[str]) -> list[str]:
        # Prefer language-aware speeds when telemetry has them — pt-BR Edge
        # is markedly slower than EN Edge on the same hardware, and ranking
        # against an undifferentiated average pollutes the chain.
        avg_speed_for = getattr(_srv.telemetry, "avg_speed_for", None)
        summary = _srv.telemetry.summary() if not callable(avg_speed_for) else None
        lang = getattr(config, "primary_language", None)
        reliability = getattr(_srv.telemetry, "reliability_factor", None)

        def _score(name: str) -> float:
            if callable(avg_speed_for):
                cps = float(avg_speed_for(name, lang) or 0.0)
            else:
                cps = (summary or {}).get(name, {}).get("avg_chars_per_second", 0.0)
            factor = reliability(name) if callable(reliability) else 1.0
            return cps * factor

        ranked = sorted(
            ((name, _score(name)) for name in candidates),
            key=lambda item: item[1],
            reverse=True,
        )
        ordered = [name for name, _ in ranked if name in candidates]
        for name in candidates:
            if name not in ordered:
                ordered.append(name)
        return ordered

    if (config.engine or "").lower() == "edge":
        # Tier 2: Edge monolingual — mirrors the CLI four-tier fallback chain.
        # Insert a second Edge entry with a monolingual voice when the primary voice
        # is multilingual and a monolingual alternative exists for the language.
        provider = _srv.tts_factory.voice_provider
        is_multilingual = provider.edge_voice_is_multilingual(config.voice)
        if is_multilingual is not False:  # True or None (unknown) → try to insert mono tier
            mono_voice = provider.get_monolingual_voice(config.primary_language)
            if mono_voice and mono_voice != config.voice:
                mono_config = replace(config, voice=mono_voice)
                mono_config.language_voices = provider.build_language_voice_map(
                    "edge",
                    list(config.languages or []),
                    mono_voice,
                    primary_language=config.primary_language,
                )
                chain.append(mono_config)

        override = _fallback_engine_override()
        if override == "none":
            return chain
        # Edge-only by default: skip the offline tier unless the operator
        # explicitly opts into the legacy cascade or names a specific engine.
        if override is None and not _engine_chain_fallback_enabled(config):
            return chain
        fallback_candidates = []
        if _srv._has_piper_support() and not _piper_fallback_disabled():
            fallback_candidates.append("piper")
        if override and override in fallback_candidates:
            fallback_candidates = [override]
        fallback_engines = _rank_fallbacks(fallback_candidates)
        for engine_name in fallback_engines:
            if engine_name == "piper" and not _srv._has_piper_support():
                continue
            clone = _clone_config_for_engine(config, engine_name)
            if clone.engine.lower() == "edge":
                clone.edge_aggressive_mode = True
            chain.append(clone)
    return chain


def _prepare_auto_engine_pool(config: ConversionConfig) -> dict[str, ConversionConfig]:
    pool: dict[str, ConversionConfig] = {}
    # Priority: edge (fast cloud). Piper excluded from auto due to lower quality.
    candidate_order = ["edge"]
    for name in candidate_order:
        try:
            candidate = _clone_config_for_engine(config, name)
            pool[name] = candidate
        except Exception:
            continue
    return pool


def _auto_tune_engine_pool(
    pool: dict[str, ConversionConfig],
    *,
    hardware_profile: HardwareProfile,
    network_tier: str,
    total_chars: int,
    force_sequential: bool,
) -> dict[str, dict[str, object]]:
    from python_app import server as _srv  # lazy to avoid circular import

    def _env_int(name: str) -> Optional[int]:
        raw = os.getenv(name, "").strip()
        if not raw:
            return None
        try:
            return int(raw)
        except ValueError:
            return None

    def _env_bool(name: str) -> Optional[bool]:
        raw = os.getenv(name)
        if raw is None:
            return None
        raw = raw.strip().lower()
        if raw == "":
            return None
        return raw in {"1", "true", "yes", "on"}

    summary: dict[str, dict[str, object]] = {}
    tier = (network_tier or "fast").strip().lower()
    total_chars = max(int(total_chars or 0), 0)
    turbo_mode = _srv.FORCE_TURBO or os.getenv("MAX_PERFORMANCE", "true").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }

    edge_cfg = pool.get("edge")
    if edge_cfg:
        if turbo_mode:
            # Research-based: 8k chars, 90s segments (safe: 3k-8k)
            default_chunk, default_seg, default_wpm = 8000, 90, 185
            if tier == "ultra":
                default_chunk, default_seg, default_wpm = 24000, 95, 200
            elif tier == "fast":
                default_chunk, default_seg, default_wpm = 22000, 90, 190
            elif tier == "medium":
                default_chunk, default_seg, default_wpm = 18000, 85, 180
            elif tier == "slow":
                default_chunk, default_seg, default_wpm = 14000, 75, 170
        else:
            default_chunk, default_seg, default_wpm = 16000, 80, 175
            if tier == "ultra":
                # Research-based: 8k chars, 90s segments (safe: 3k-8k)
                default_chunk, default_seg, default_wpm = 8000, 90, 185
            elif tier == "fast":
                default_chunk, default_seg, default_wpm = 18000, 85, 180
            elif tier == "medium":
                default_chunk, default_seg, default_wpm = 14000, 75, 170
            elif tier == "slow":
                # Turbo mode uses slightly larger chunks
                default_chunk, default_seg, default_wpm = 10000, 65, 160

        if total_chars and total_chars < 8000:
            default_chunk = min(default_chunk, 12000)
            default_seg = min(default_seg, 75)

        chunk_override = _env_int("EDGE_CHUNK_CHARS")
        seg_override = _env_int("EDGE_MAX_SEGMENT_SECONDS")
        parallel_override = _env_bool("EDGE_ENABLE_PARALLEL")

        edge_cfg.edge_chunk_chars = int(chunk_override or default_chunk)
        edge_cfg.edge_max_segment_seconds = int(seg_override or default_seg)
        # Research-based: safe range 3,000-12,000 chars
        edge_cfg.edge_chunk_chars = max(3000, min(edge_cfg.edge_chunk_chars, 12000))
        edge_cfg.edge_max_segment_seconds = max(45, min(edge_cfg.edge_max_segment_seconds, 600))
        if parallel_override is None:
            edge_cfg.edge_enable_parallel = not force_sequential
        else:
            edge_cfg.edge_enable_parallel = parallel_override and not force_sequential

        edge_cfg.extra = dict(edge_cfg.extra or {})
        edge_cfg.extra["edge_auto_wpm"] = int(default_wpm)
        summary["edge"] = {
            "chunk_chars": edge_cfg.edge_chunk_chars,
            "max_segment_seconds": edge_cfg.edge_max_segment_seconds,
            "words_per_minute": int(default_wpm),
            "parallel": edge_cfg.edge_enable_parallel,
        }

    return summary


def _pick_auto_engine(
    chapter_chars: int,
    estimated_seconds: float,
    pool: dict[str, ConversionConfig],
    telemetry_speeds: Optional[Dict[str, object]] = None,
    preferred_engine: Optional[str] = None,
) -> tuple[str, list[str]]:
    def _speed_value(entry: object) -> float:
        if isinstance(entry, dict):
            return float(entry.get("avg_chars_per_second") or 0.0)
        try:
            return float(entry or 0.0)
        except (TypeError, ValueError):
            return 0.0

    def _sample_count(entry: object) -> int:
        if isinstance(entry, dict):
            return int(entry.get("samples") or 0)
        return 0

    def append(order: list[str], candidate: str) -> None:
        if candidate in pool and candidate not in order:
            order.append(candidate)

    # Order from fastest to slowest: edge
    order: list[str] = []
    if telemetry_speeds:
        ranked = sorted(
            ((name, _speed_value(telemetry_speeds.get(name, 0.0))) for name in pool.keys()),
            key=lambda item: item[1],
            reverse=True,
        )
        for name, _ in ranked:
            append(order, name)
    else:
        append(order, "edge")

    for name in pool.keys():
        append(order, name)

    if not order:
        order = list(pool.keys())
    if "edge" in order:
        best_name = order[0]
        edge_speed = _speed_value(telemetry_speeds.get("edge", 0.0)) if telemetry_speeds else 0.0
        best_speed = _speed_value(telemetry_speeds.get(best_name, 0.0)) if telemetry_speeds else 0.0
        edge_samples = _sample_count(telemetry_speeds.get("edge", 0)) if telemetry_speeds else 0
        best_samples = _sample_count(telemetry_speeds.get(best_name, 0)) if telemetry_speeds else 0
        prefer_best = (
            best_name != "edge"
            and best_samples >= 3
            and (edge_speed <= 0 or (edge_samples >= 3 and best_speed >= edge_speed * 1.25))
        )
        if not prefer_best:
            order = ["edge"] + [name for name in order if name != "edge"]
    if preferred_engine:
        normalized = preferred_engine.lower()
        if normalized in order:
            order = [normalized] + [name for name in order if name != normalized]

    selected = order[0]
    return selected, order


def _resolve_auto_preferred_engine(config: ConversionConfig) -> Optional[str]:
    primary = (config.primary_language or "").lower()
    if primary.startswith("pt"):
        return "edge"
    return None


def _next_auto_engine(
    order: list[str], attempted: set[str], pool: dict[str, ConversionConfig]
) -> Optional[str]:
    for name in order:
        if name in pool and name not in attempted:
            return name
    return None


# ---------------------------------------------------------------------------
# Multi-engine parallel slot affinity
# ---------------------------------------------------------------------------


def _build_multi_engine_slot_map(
    parallel_slots: int,
    available_engines: list[str],
    *,
    edge_fraction: float = 0.67,
) -> list[str]:
    """Return a slot-to-engine affinity list for multi-engine parallel conversion.

    Each entry is the engine name that slot should prefer.  Edge gets the
    majority of slots (``edge_fraction``), remaining slots go to the next
    available engines round-robin.  Returns ``[]`` (disabled) if fewer than
    two engines are available or ``parallel_slots < 2``.
    """
    if len(available_engines) < 2 or parallel_slots < 2:
        return []
    primary = available_engines[0]
    secondary = available_engines[1:]
    primary_count = max(1, round(parallel_slots * edge_fraction))
    secondary_count = parallel_slots - primary_count
    affinity: list[str] = [primary] * primary_count
    for i in range(secondary_count):
        affinity.append(secondary[i % len(secondary)])
    return affinity
