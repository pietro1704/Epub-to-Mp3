"""Network classification and bounded engine-concurrency grids."""

from __future__ import annotations

import socket
import statistics
import time
from typing import Dict, Iterable, List


def _probe_edge_latency(
    host: str = "api.msedgeservices.com",
    *,
    attempts: int = 5,
    timeout: float = 2.5,
    pause: float = 0.2,
) -> Dict[str, object]:
    latencies_ms: List[float] = []
    errors = 0
    for _ in range(max(1, attempts)):
        start = time.perf_counter()
        try:
            sock = socket.create_connection((host, 443), timeout=timeout)
            sock.close()
            latencies_ms.append((time.perf_counter() - start) * 1000.0)
        except OSError:
            errors += 1
        time.sleep(pause)
    tier = _classify_latency(latencies_ms)
    return {
        "host": host,
        "attempts": attempts,
        "errors": errors,
        "latencies_ms": latencies_ms,
        "median_ms": statistics.median(latencies_ms) if latencies_ms else None,
        "tier": tier,
    }


def _classify_latency(latencies_ms: List[float]) -> str:
    if not latencies_ms:
        return "unknown"
    median = statistics.median(latencies_ms)
    if median <= 30:
        return "ultra"
    if median <= 70:
        return "fast"
    if median <= 140:
        return "medium"
    return "slow"


def _dedupe_sorted(values: Iterable[int]) -> List[int]:
    return sorted({int(v) for v in values if int(v) > 0})


def _default_chapter_parallel(recommended: int) -> List[int]:
    rec = max(1, int(recommended or 1))
    values = [
        1,
        max(2, rec // 2),
        rec,
        min(16, rec * 2),
    ]
    return _dedupe_sorted(values)


def _default_edge_concurrency(recommended: int) -> List[int]:
    rec = max(1, int(recommended or 1))
    values = [
        1,
        max(2, rec // 2),
        rec,
        min(32, rec * 2),
    ]
    return _dedupe_sorted(values)


def _default_coqui_workers(cpu_count: int) -> List[int]:
    default = max(1, min(4, cpu_count))
    values = [1, default, min(8, default + 1), min(8, default * 2)]
    return _dedupe_sorted(values)


def _default_piper_procs(cpu_count: int) -> List[int]:
    default = max(1, min(3, cpu_count))
    values = [1, default, min(6, default + 1), min(6, default * 2)]
    return _dedupe_sorted(values)

NETWORK_PROFILES: Dict[str, Dict[str, float]] = {
    "slow": {"chunk_chars": 8000, "max_segment_seconds": 40, "concurrency_scale": 0.5},
    "medium": {"chunk_chars": 11000, "max_segment_seconds": 60, "concurrency_scale": 0.75},
    "fast": {"chunk_chars": 16000, "max_segment_seconds": 75, "concurrency_scale": 1.0},
    "ultra": {"chunk_chars": 20000, "max_segment_seconds": 85, "concurrency_scale": 1.25},
}
