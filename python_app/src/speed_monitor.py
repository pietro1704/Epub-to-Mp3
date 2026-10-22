# -*- coding: utf-8 -*-
"""Public speed-monitor API and the process-wide Edge tuner lifecycle."""

from __future__ import annotations

from typing import Callable, Optional

from .adaptive_edge_tuner import AdaptiveEdgeTuner as AdaptiveEdgeTuner
from .speed_sample_monitor import SpeedMonitor as SpeedMonitor
from .speed_tuning_contracts import CHUNK_SIZE_OPTIONS as CHUNK_SIZE_OPTIONS
from .speed_tuning_contracts import CONCURRENCY_OPTIONS as CONCURRENCY_OPTIONS
from .speed_tuning_contracts import EXCELLENT_SPEED as EXCELLENT_SPEED
from .speed_tuning_contracts import MIN_ACCEPTABLE_SPEED as MIN_ACCEPTABLE_SPEED
from .speed_tuning_contracts import MIN_SAMPLES_FOR_DETECTION as MIN_SAMPLES_FOR_DETECTION
from .speed_tuning_contracts import SEGMENT_SECONDS_OPTIONS as SEGMENT_SECONDS_OPTIONS
from .speed_tuning_contracts import SPEED_DROP_THRESHOLD as SPEED_DROP_THRESHOLD
from .speed_tuning_contracts import SPEED_RECOVERY_THRESHOLD as SPEED_RECOVERY_THRESHOLD
from .speed_tuning_contracts import STALL_DURATION_SECONDS as STALL_DURATION_SECONDS
from .speed_tuning_contracts import TARGET_CHARS_PER_SECOND as TARGET_CHARS_PER_SECOND
from .speed_tuning_contracts import WARMUP_SAMPLES as WARMUP_SAMPLES
from .speed_tuning_contracts import SpeedSample as SpeedSample
from .speed_tuning_contracts import TuningConfig as TuningConfig
from .speed_tuning_contracts import TuningResult as TuningResult

# Global tuner instance for Edge-TTS
_global_edge_tuner: Optional[AdaptiveEdgeTuner] = None


def get_edge_tuner(
    *,
    log_callback: Optional[Callable[[str], None]] = None,
    aggressive: bool = False,
    reset: bool = False,
) -> AdaptiveEdgeTuner:
    """Get or create the global Edge-TTS tuner."""
    global _global_edge_tuner

    if _global_edge_tuner is None or reset:
        _global_edge_tuner = AdaptiveEdgeTuner(
            log_callback=log_callback,
            aggressive=aggressive,
        )

    return _global_edge_tuner


def reset_edge_tuner() -> None:
    """Reset the global Edge-TTS tuner."""
    global _global_edge_tuner
    _global_edge_tuner = None


__all__ = [
    "SpeedMonitor",
    "SpeedSample",
    "TuningConfig",
    "TuningResult",
    "AdaptiveEdgeTuner",
    "get_edge_tuner",
    "reset_edge_tuner",
]
