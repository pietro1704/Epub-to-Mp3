# -*- coding: utf-8 -*-
"""Load and apply benchmark-derived performance profiles."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Dict, Optional

from .paths import CACHE_DIR

DEFAULT_PROFILE_PATH = CACHE_DIR / "telemetry" / "benchmark_profiles.json"


def _env_truthy(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _profile_mode() -> str:
    raw = os.getenv("BENCHMARK_PROFILE_MODE", "auto").strip().lower()
    if raw in {"off", "disable", "false", "0"}:
        return "off"
    if raw in {"force", "always"}:
        return "force"
    return "auto"


def _resolve_profile_path(path: Optional[Path] = None) -> Path:
    if path is not None:
        return Path(path)
    env_path = os.getenv("BENCHMARK_PROFILE_PATH")
    if env_path:
        return Path(env_path)
    return DEFAULT_PROFILE_PATH


def load_profile(path: Optional[Path] = None) -> Optional[Dict[str, object]]:
    if _profile_mode() == "off" and not _env_truthy("BENCHMARK_PROFILE_FORCE", False):
        return None
    profile_path = _resolve_profile_path(path)
    if not profile_path.exists():
        return None
    try:
        data = json.loads(profile_path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    if "engines" not in data and any(isinstance(v, dict) for v in data.values()):
        data = {"engines": {k: v for k, v in data.items() if isinstance(v, dict)}}
    if "engines" not in data:
        return None
    return data


def resolve_engine_profile(
    profile: Dict[str, object], engine: Optional[str]
) -> Optional[Dict[str, object]]:
    if not profile:
        return None
    engines = profile.get("engines", {})
    if not isinstance(engines, dict):
        return None
    key = (engine or "").lower()
    if key == "auto":
        key = str(profile.get("default_engine") or "edge").lower()
    entry = engines.get(key)
    return entry if isinstance(entry, dict) else None


def _set_env(name: str, value: object, *, force: bool) -> None:
    if value is None:
        return
    if not force and os.getenv(name):
        return
    os.environ[name] = str(value)


def apply_env_overrides(
    engine_profile: Dict[str, object],
    *,
    force: bool = False,
    apply_chapter_parallel: bool = False,
) -> None:
    if not engine_profile:
        return
    _set_env("EDGE_MAX_CONCURRENCY", engine_profile.get("edge_max_concurrency"), force=force)
    _set_env("EDGE_CHUNK_CHARS", engine_profile.get("edge_chunk_chars"), force=force)
    _set_env(
        "EDGE_MAX_SEGMENT_SECONDS", engine_profile.get("edge_max_segment_seconds"), force=force
    )
    if "edge_enable_parallel" in engine_profile:
        value = "true" if bool(engine_profile.get("edge_enable_parallel")) else "false"
        _set_env("EDGE_ENABLE_PARALLEL", value, force=force)
    _set_env("COQUI_MAX_WORKERS", engine_profile.get("coqui_max_workers"), force=force)
    _set_env("PIPER_MAX_PROCS", engine_profile.get("piper_max_procs"), force=force)

    if apply_chapter_parallel:
        chapter_parallel = engine_profile.get("chapter_parallel")
        _set_env("CHAPTER_PARALLEL_COUNT", chapter_parallel, force=force)
        _set_env("CHAPTER_PARALLEL_MAX", chapter_parallel, force=force)


def apply_global_overrides(
    profile: Optional[Dict[str, object]] = None,
) -> Optional[Dict[str, object]]:
    profile = profile or load_profile()
    if not profile:
        return None
    mode = _profile_mode()
    force = mode == "force"
    edge_profile = resolve_engine_profile(profile, "edge")
    if edge_profile:
        apply_env_overrides(edge_profile, force=force, apply_chapter_parallel=True)
    coqui_profile = resolve_engine_profile(profile, "coqui")
    if coqui_profile:
        apply_env_overrides(coqui_profile, force=force, apply_chapter_parallel=False)
    piper_profile = resolve_engine_profile(profile, "piper")
    if piper_profile:
        apply_env_overrides(piper_profile, force=force, apply_chapter_parallel=False)
    return profile


def apply_benchmark_profile(
    engine: str,
    *,
    config: Optional[object] = None,
    profile: Optional[Dict[str, object]] = None,
) -> Optional[Dict[str, object]]:
    profile = profile or load_profile()
    if not profile:
        return None
    engine_profile = resolve_engine_profile(profile, engine)
    if not engine_profile:
        return None
    mode = _profile_mode()
    force = mode == "force"
    apply_env_overrides(engine_profile, force=force, apply_chapter_parallel=True)
    if config is not None and (engine or "").lower() in {"edge", "auto"}:
        if engine_profile.get("edge_chunk_chars"):
            config.edge_chunk_chars = int(engine_profile["edge_chunk_chars"])
        if engine_profile.get("edge_max_segment_seconds"):
            config.edge_max_segment_seconds = int(engine_profile["edge_max_segment_seconds"])
        if "edge_enable_parallel" in engine_profile:
            config.edge_enable_parallel = bool(engine_profile.get("edge_enable_parallel"))
    return engine_profile


def recommend_parallel_slots(
    engine: str,
    default_slots: int,
    *,
    profile: Optional[Dict[str, object]] = None,
) -> int:
    profile = profile or load_profile()
    if not profile:
        return default_slots
    engine_profile = resolve_engine_profile(profile, engine)
    if not engine_profile:
        return default_slots
    try:
        value = int(engine_profile.get("chapter_parallel") or 0)
    except (TypeError, ValueError):
        return default_slots
    return max(1, value) if value else default_slots


__all__ = [
    "DEFAULT_PROFILE_PATH",
    "load_profile",
    "resolve_engine_profile",
    "apply_env_overrides",
    "apply_global_overrides",
    "apply_benchmark_profile",
    "recommend_parallel_slots",
]
