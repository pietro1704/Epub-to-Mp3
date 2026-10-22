"""Infer legacy server deployment profiles and fill only unset environment defaults."""

from __future__ import annotations

import os

from src.hardware_detector import HardwareProfile


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
