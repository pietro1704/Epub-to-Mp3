"""Adapt Edge engine settings using the public speed monitor factory."""

from __future__ import annotations

from typing import Callable, Dict, List, Optional

from .speed_tuning_contracts import (
    CHUNK_SIZE_OPTIONS,
    CONCURRENCY_OPTIONS,
    SEGMENT_SECONDS_OPTIONS,
    TuningConfig,
)


class AdaptiveEdgeTuner:
    """
    Automatic tuner specifically for Edge-TTS.

    Monitors real-time speed and automatically adjusts:
    - Chunk size
    - Concurrency
    - Segment duration

    Throughput-focused auto-tuning (Jan 2026):
    - Aggressive target: 200+ chars/s with higher concurrency/segment sizes
    - Falls back quickly on failures and rate limits
    """

    def __init__(
        self,
        *,
        log_callback: Optional[Callable[[str], None]] = None,
        aggressive: bool = False,
    ) -> None:
        from .speed_monitor import SpeedMonitor

        self._log_callback = log_callback
        self._aggressive = aggressive

        # Initialize monitor with throughput targets
        self._monitor = SpeedMonitor(
            target_speed=220.0 if aggressive else 180.0,
            min_speed=80.0,
            log_callback=log_callback,
        )

        # Auto-tune state
        self._auto_tune_enabled = True
        self._segments_since_last_tune = 0
        self._tune_every_n_segments = 5  # Avoid oscillation; let settings stabilize

        # Current settings - start aggressive for throughput
        self._chunk_size = 4000
        self._concurrency = 8
        self._max_segment_seconds = 45 if aggressive else 65

        # Performance tracking per config
        self._config_speeds: Dict[str, List[float]] = {}

        # Track if we've found good settings
        self._optimal_found = False
        self._failures_since_optimal = 0
        self._consecutive_under_target = 0

    def _log(self, message: str) -> None:
        if self._log_callback:
            self._log_callback(message)

    @property
    def chunk_size(self) -> int:
        return self._chunk_size

    @property
    def concurrency(self) -> int:
        return self._concurrency

    @property
    def max_segment_seconds(self) -> int:
        return self._max_segment_seconds

    def record_segment(
        self,
        chars: int,
        duration: float,
        success: bool = True,
    ) -> Optional[Dict[str, int]]:
        """
        Record a segment synthesis result.

        Returns:
            New configuration dict if adjustment recommended, None otherwise
        """
        # Handle failures - may need to reduce aggressiveness
        if not success:
            self._failures_since_optimal += 1
            if self._failures_since_optimal >= 1:
                # Fail fast - reduce aggressiveness immediately
                self._log("FAILURE_DETECTED: reducing chunk size")
                return self._reduce_aggressiveness()
            return None

        if duration <= 0 or chars <= 0:
            return None

        speed = chars / duration
        self._failures_since_optimal = 0  # Reset on success

        # Record in monitor
        config_dict = {
            "chunk_size": self._chunk_size,
            "concurrency": self._concurrency,
            "max_segment_seconds": self._max_segment_seconds,
        }

        action = self._monitor.record_sample(chars, duration, config=config_dict)
        avg_speed = self._monitor.get_average_speed()
        if avg_speed < self._monitor.target_speed:
            self._consecutive_under_target += 1
        else:
            self._consecutive_under_target = 0

        # Track speed for current config
        config_key = f"{self._chunk_size}_{self._concurrency}_{self._max_segment_seconds}"
        if config_key not in self._config_speeds:
            self._config_speeds[config_key] = []
        self._config_speeds[config_key].append(speed)

        self._segments_since_last_tune += 1

        # Handle stalls/slowdowns aggressively
        if action and (
            "STALL_DETECTED" in action or "SLOW_DETECTED" in action or "SPEED_DROP" in action
        ):
            self._log(f"{action} -> reducing aggressiveness")
            return self._reduce_aggressiveness()

        # Check if we should auto-tune
        if (
            self._auto_tune_enabled
            and self._segments_since_last_tune >= self._tune_every_n_segments
        ):
            new_config = self._check_and_tune()
            if new_config:
                return new_config

        # Handle excellent speed - can increase aggressiveness
        if action and "EXCELLENT_SPEED" in action:
            self._optimal_found = True
            return self._increase_aggressiveness()

        # Log action if any
        if action:
            self._log(f"MONITOR: {action}")

        return None

    def _reduce_aggressiveness(self) -> Dict[str, int]:
        """Reduce settings when experiencing failures."""
        # Reduce chunk size first
        if self._chunk_size > CHUNK_SIZE_OPTIONS[0]:
            idx = (
                CHUNK_SIZE_OPTIONS.index(self._chunk_size)
                if self._chunk_size in CHUNK_SIZE_OPTIONS
                else 2
            )
            self._chunk_size = CHUNK_SIZE_OPTIONS[max(0, idx - 1)]
        # Then reduce concurrency
        elif self._concurrency > CONCURRENCY_OPTIONS[0]:
            idx = (
                CONCURRENCY_OPTIONS.index(self._concurrency)
                if self._concurrency in CONCURRENCY_OPTIONS
                else 2
            )
            self._concurrency = CONCURRENCY_OPTIONS[max(0, idx - 1)]

        self._log(f"REDUCED: chunk={self._chunk_size}, conc={self._concurrency}")
        # Reset tune counter so the next tune waits a full interval
        self._segments_since_last_tune = 0
        return {
            "chunk_size": self._chunk_size,
            "concurrency": self._concurrency,
            "max_segment_seconds": self._max_segment_seconds,
        }

    def _increase_aggressiveness(self) -> Optional[Dict[str, int]]:
        """Increase settings when performance is excellent."""
        changed = False

        # Increase concurrency first (most impactful from benchmark)
        if self._concurrency < CONCURRENCY_OPTIONS[-1]:
            idx = (
                CONCURRENCY_OPTIONS.index(self._concurrency)
                if self._concurrency in CONCURRENCY_OPTIONS
                else 2
            )
            if idx < len(CONCURRENCY_OPTIONS) - 1:
                self._concurrency = CONCURRENCY_OPTIONS[idx + 1]
                changed = True

        # Then increase chunk size
        if not changed and self._chunk_size < CHUNK_SIZE_OPTIONS[-1]:
            idx = (
                CHUNK_SIZE_OPTIONS.index(self._chunk_size)
                if self._chunk_size in CHUNK_SIZE_OPTIONS
                else 2
            )
            if idx < len(CHUNK_SIZE_OPTIONS) - 1:
                self._chunk_size = CHUNK_SIZE_OPTIONS[idx + 1]
                changed = True

        # Finally increase max segment seconds
        if not changed and self._max_segment_seconds < SEGMENT_SECONDS_OPTIONS[-1]:
            idx = (
                SEGMENT_SECONDS_OPTIONS.index(self._max_segment_seconds)
                if self._max_segment_seconds in SEGMENT_SECONDS_OPTIONS
                else 1
            )
            if idx < len(SEGMENT_SECONDS_OPTIONS) - 1:
                self._max_segment_seconds = SEGMENT_SECONDS_OPTIONS[idx + 1]
                changed = True

        if changed:
            self._log(f"INCREASED: chunk={self._chunk_size}, conc={self._concurrency}")
            # Reset tune counter so the next tune waits a full interval
            self._segments_since_last_tune = 0
            return {
                "chunk_size": self._chunk_size,
                "concurrency": self._concurrency,
                "max_segment_seconds": self._max_segment_seconds,
            }
        return None

    def _check_and_tune(self) -> Optional[Dict[str, int]]:
        """Check performance and tune if needed."""
        self._segments_since_last_tune = 0

        avg_speed = self._monitor.get_average_speed()
        trend, trend_status = self._monitor.get_speed_trend()

        # If under target for a few segments, try to push higher settings first.
        if self._consecutive_under_target >= 2:
            increased = self._increase_aggressiveness()
            if increased:
                self._monitor.apply_config(
                    TuningConfig(
                        chunk_size=self._chunk_size,
                        concurrency=self._concurrency,
                        max_segment_seconds=self._max_segment_seconds,
                    )
                )
                self._log(f"AUTO_TUNE_UP: speed={avg_speed:.0f}, trend={trend_status}")
                return increased

        # If things are good, no tune.
        # Use the same -0.2 threshold as should_tune() to avoid oscillation on natural variance.
        if avg_speed >= self._monitor.target_speed and not (
            trend_status == "degrading" and trend < -0.2
        ):
            return None

        # Fall back to monitor suggestion.
        suggested = self._monitor.suggest_config_adjustment()
        if not suggested:
            return None

        old_config = (
            f"chunk={self._chunk_size}, conc={self._concurrency}, seg={self._max_segment_seconds}"
        )

        self._chunk_size = suggested.chunk_size
        self._concurrency = suggested.concurrency
        self._max_segment_seconds = suggested.max_segment_seconds

        new_config = (
            f"chunk={self._chunk_size}, conc={self._concurrency}, seg={self._max_segment_seconds}"
        )

        self._log(
            f"AUTO_TUNE: {old_config} -> {new_config} (speed={avg_speed:.0f}, trend={trend_status})"
        )

        self._monitor.apply_config(suggested)

        return {
            "chunk_size": self._chunk_size,
            "concurrency": self._concurrency,
            "max_segment_seconds": self._max_segment_seconds,
        }

    def force_tune(self, strategy: str = "auto") -> Dict[str, int]:
        """
        Force a tuning adjustment.

        Args:
            strategy: "conservative", "balanced", "aggressive", or "auto"

        Returns:
            New configuration dict
        """
        if strategy == "conservative":
            config = self._monitor._suggest_conservative_config()
        elif strategy == "aggressive":
            config = self._monitor._suggest_aggressive_config()
        elif strategy == "balanced":
            config = self._monitor._suggest_balanced_config()
        else:
            # Auto - based on current performance
            config = self._monitor.suggest_config_adjustment()
            if not config:
                config = self._monitor._suggest_balanced_config()

        self._chunk_size = config.chunk_size
        self._concurrency = config.concurrency
        self._max_segment_seconds = config.max_segment_seconds

        self._monitor.apply_config(config)

        return {
            "chunk_size": self._chunk_size,
            "concurrency": self._concurrency,
            "max_segment_seconds": self._max_segment_seconds,
        }

    def get_optimal_config(self) -> Dict[str, int]:
        """Get the optimal configuration based on history."""
        best = self._monitor.get_best_config()
        if best:
            return {
                "chunk_size": best.chunk_size,
                "concurrency": best.concurrency,
                "max_segment_seconds": best.max_segment_seconds,
            }

        # Default to current
        return {
            "chunk_size": self._chunk_size,
            "concurrency": self._concurrency,
            "max_segment_seconds": self._max_segment_seconds,
        }

    def get_stats(self) -> Dict[str, any]:
        """Get tuner statistics."""
        base_stats = self._monitor.get_stats()
        base_stats.update(
            {
                "auto_tune_enabled": self._auto_tune_enabled,
                "segments_since_tune": self._segments_since_last_tune,
                "tune_interval": self._tune_every_n_segments,
                "aggressive_mode": self._aggressive,
                "configs_with_data": len(self._config_speeds),
            }
        )
        return base_stats
