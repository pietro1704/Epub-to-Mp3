"""Shared speed samples, tuning results and literal benchmark policy defaults."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List

# Configuracoes de monitoramento - baseado em benchmark (Jan 2026)
# Benchmark results: best config = chunk 10k, conc 6, parallel -> 68 chars/s
MIN_SAMPLES_FOR_DETECTION = 1  # Detect asap after first sample
WARMUP_SAMPLES = 1  # Shorter warmup to react earlier
SPEED_DROP_THRESHOLD = 0.65  # 35% drop triggers earlier slow mode
SPEED_RECOVERY_THRESHOLD = 0.75  # 75% of target = recovered
TARGET_CHARS_PER_SECOND = 200.0  # Aggressive throughput target
MIN_ACCEPTABLE_SPEED = 100.0  # Higher floor to react sooner
EXCELLENT_SPEED = 250.0  # Above this, increase aggressiveness
STALL_DURATION_SECONDS = 45.0  # Treat long segments as stalls sooner

# Configuracoes de auto-tuning - ordenadas por performance do benchmark
CHUNK_SIZE_OPTIONS = [4000, 6000, 8000]  # Focus on fastest buckets
CONCURRENCY_OPTIONS = [2, 4, 6, 8]  # Prefer even jumps for Edge
SEGMENT_SECONDS_OPTIONS = [45, 65, 85]  # Keep within reliable bands


@dataclass
class SpeedSample:
    """Single speed measurement."""

    timestamp: float
    chars: int
    duration: float
    chars_per_second: float
    config_snapshot: Dict[str, float] = field(default_factory=dict)


@dataclass
class TuningConfig:
    """Current tuning configuration."""

    chunk_size: int = 8000
    concurrency: int = 4
    max_segment_seconds: int = 75

    def to_dict(self) -> Dict[str, int]:
        return {
            "chunk_size": self.chunk_size,
            "concurrency": self.concurrency,
            "max_segment_seconds": self.max_segment_seconds,
        }

    def __hash__(self) -> int:
        return hash((self.chunk_size, self.concurrency, self.max_segment_seconds))


@dataclass
class TuningResult:
    """Result of a tuning configuration test."""

    config: TuningConfig
    samples: List[SpeedSample]
    avg_speed: float
    success_rate: float
    score: float  # Combined metric
