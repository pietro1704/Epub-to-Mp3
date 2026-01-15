# -*- coding: utf-8 -*-
"""Real-time speed monitoring and dynamic tuning for TTS engines."""

from __future__ import annotations

import time
from collections import deque
from dataclasses import dataclass, field
from typing import Callable, Deque, Dict, List, Optional, Tuple

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


class SpeedMonitor:
    """
    Real-time speed monitor with automatic tuning.

    Tracks synthesis speed and automatically adjusts configuration
    when performance drops. Includes warmup detection to avoid
    calibrating on cold-start latency.
    """

    def __init__(
        self,
        *,
        target_speed: float = TARGET_CHARS_PER_SECOND,
        min_speed: float = MIN_ACCEPTABLE_SPEED,
        window_size: int = 10,
        log_callback: Optional[Callable[[str], None]] = None,
    ) -> None:
        self.target_speed = target_speed
        self.min_speed = min_speed
        self.window_size = window_size
        self._log_callback = log_callback

        # Speed tracking
        self._samples: Deque[SpeedSample] = deque(maxlen=window_size)
        self._all_samples: List[SpeedSample] = []

        # Warmup tracking - first few segments are often slower (cold start)
        self._warmup_samples: int = 0
        self._warmup_complete: bool = False
        self._warmup_speeds: List[float] = []

        # Tuning state
        self._current_config = TuningConfig()
        self._config_history: Dict[TuningConfig, TuningResult] = {}
        self._tuning_in_progress = False
        self._last_tuning_time = 0.0
        self._tuning_cooldown = 15.0  # Reduced from 30s for faster adaptation

        # Performance state
        self._slow_mode = False
        self._recovery_mode = False
        self._consecutive_slow = 0
        self._consecutive_fast = 0

        # Jitter detection - Edge-TTS has high latency variance
        self._speed_variance: float = 0.0
        self._high_jitter_mode: bool = False
        self._last_stall_time: float = 0.0

        # Best known configuration
        self._best_config: Optional[TuningConfig] = None
        self._best_score: float = 0.0

    def _log(self, message: str) -> None:
        """Log message using callback or print."""
        if self._log_callback:
            self._log_callback(message)
        else:
            print(message)

    def record_sample(
        self,
        chars: int,
        duration: float,
        *,
        config: Optional[Dict[str, float]] = None,
    ) -> Optional[str]:
        """
        Record a speed sample and return any action message.

        Returns:
            Action message if tuning is recommended, None otherwise
        """
        if duration <= 0 or chars <= 0:
            return None

        speed = chars / duration
        stall_action = None
        if duration >= STALL_DURATION_SECONDS and speed < self.min_speed:
            self._last_stall_time = time.time()
            stall_action = (
                f"STALL_DETECTED: {duration:.0f}s for {chars} chars ({speed:.0f} chars/s)"
            )
        sample = SpeedSample(
            timestamp=time.time(),
            chars=chars,
            duration=duration,
            chars_per_second=speed,
            config_snapshot=config or self._current_config.to_dict(),
        )

        self._samples.append(sample)
        self._all_samples.append(sample)

        # Track warmup phase
        if not self._warmup_complete:
            self._warmup_samples += 1
            self._warmup_speeds.append(speed)
            if self._warmup_samples >= WARMUP_SAMPLES:
                self._warmup_complete = True
                avg_warmup = sum(self._warmup_speeds) / len(self._warmup_speeds)
                self._log(f"WARMUP_COMPLETE: avg={avg_warmup:.0f} chars/s")

        # Calculate speed variance for jitter detection
        if len(self._samples) >= 3:
            speeds = [s.chars_per_second for s in list(self._samples)[-5:]]
            avg = sum(speeds) / len(speeds)
            variance = sum((s - avg) ** 2 for s in speeds) / len(speeds)
            self._speed_variance = variance**0.5  # Standard deviation
            self._high_jitter_mode = self._speed_variance > 50  # High variance

        # Check speed status (skip during warmup)
        if self._warmup_complete:
            action = self._check_speed_status(speed)
        else:
            action = None

        return stall_action or action

    def _check_speed_status(self, current_speed: float) -> Optional[str]:
        """Check speed and determine if action is needed."""

        if len(self._samples) < MIN_SAMPLES_FOR_DETECTION:
            return None

        avg_speed = self.get_average_speed()

        # Adjust thresholds for high jitter mode
        drop_threshold = SPEED_DROP_THRESHOLD
        recovery_threshold = SPEED_RECOVERY_THRESHOLD
        if self._high_jitter_mode:
            # Be more tolerant when there's high variance
            drop_threshold = 0.4  # More tolerant
            recovery_threshold = 0.65

        # Check for excellent speed - can be more aggressive
        if avg_speed >= EXCELLENT_SPEED:
            self._consecutive_fast += 1
            self._consecutive_slow = 0
            if self._consecutive_fast >= 2 and not self._recovery_mode:
                self._recovery_mode = True
                self._slow_mode = False
                return f"EXCELLENT_SPEED: {avg_speed:.0f} chars/s - can increase aggressiveness"

        # Check for slow mode
        elif avg_speed < self.min_speed:
            self._consecutive_slow += 1
            self._consecutive_fast = 0

            if self._consecutive_slow >= 2 and not self._slow_mode:
                self._slow_mode = True
                self._recovery_mode = False
                return f"SLOW_DETECTED: {avg_speed:.0f} chars/s (min: {self.min_speed:.0f})"

        # Check for speed drop from target
        elif avg_speed < self.target_speed * drop_threshold:
            self._consecutive_slow += 1
            self._consecutive_fast = 0

            if self._consecutive_slow >= 2:
                if not self._slow_mode:
                    self._slow_mode = True
                    drop_pct = (1 - avg_speed / self.target_speed) * 100
                    jitter_note = " [high-jitter]" if self._high_jitter_mode else ""
                    return (
                        f"SPEED_DROP: {drop_pct:.0f}% queda ({avg_speed:.0f} chars/s){jitter_note}"
                    )

        # Check for recovery
        elif avg_speed >= self.target_speed * recovery_threshold:
            self._consecutive_fast += 1
            self._consecutive_slow = 0

            if self._slow_mode and self._consecutive_fast >= 2:
                self._slow_mode = False
                self._recovery_mode = True
                return f"SPEED_RECOVERED: {avg_speed:.0f} chars/s"

        else:
            # Normal operation
            self._consecutive_slow = max(0, self._consecutive_slow - 1)
            self._consecutive_fast = max(0, self._consecutive_fast - 1)

        return None

    def get_average_speed(self, window: Optional[int] = None) -> float:
        """Get average speed over recent samples."""
        samples = list(self._samples)
        if window:
            samples = samples[-window:]

        if not samples:
            return 0.0

        total_chars = sum(s.chars for s in samples)
        total_duration = sum(s.duration for s in samples)

        if total_duration <= 0:
            return 0.0

        return total_chars / total_duration

    def get_speed_trend(self) -> Tuple[float, str]:
        """
        Get speed trend.

        Returns:
            (trend_value, description) where trend_value is positive for improving
        """
        samples = list(self._samples)
        if len(samples) < 4:
            return (0.0, "insufficient_data")

        # Compare first half to second half
        mid = len(samples) // 2
        first_half = samples[:mid]
        second_half = samples[mid:]

        first_avg = sum(s.chars_per_second for s in first_half) / len(first_half)
        second_avg = sum(s.chars_per_second for s in second_half) / len(second_half)

        if first_avg <= 0:
            return (0.0, "no_baseline")

        change = (second_avg - first_avg) / first_avg

        if change > 0.1:
            return (change, "improving")
        elif change < -0.1:
            return (change, "degrading")
        else:
            return (change, "stable")

    def should_tune(self) -> bool:
        """Check if we should attempt tuning."""
        if self._tuning_in_progress:
            return False

        if len(self._samples) < MIN_SAMPLES_FOR_DETECTION:
            return False

        # Respect cooldown
        if time.time() - self._last_tuning_time < self._tuning_cooldown:
            return False

        # Tune if slow mode active
        if self._slow_mode:
            return True

        # Tune if speed dropping
        trend, status = self.get_speed_trend()
        if status == "degrading" and trend < -0.2:
            return True

        return False

    def suggest_config_adjustment(self) -> Optional[TuningConfig]:
        """
        Suggest a configuration adjustment based on current performance.

        Returns:
            New configuration to try, or None if no adjustment needed
        """
        if not self.should_tune():
            return None

        current = self._current_config
        avg_speed = self.get_average_speed()

        # Strategy based on current performance
        if avg_speed < self.min_speed:
            # Very slow - try more conservative settings
            new_config = self._suggest_conservative_config()
        elif avg_speed < self.target_speed * 0.7:
            # Moderately slow - try balancing
            new_config = self._suggest_balanced_config()
        else:
            # Slightly slow - try more aggressive
            new_config = self._suggest_aggressive_config()

        # Don't suggest same config
        if new_config and hash(new_config) == hash(current):
            return None

        return new_config

    def _suggest_conservative_config(self) -> TuningConfig:
        """Suggest conservative settings for slow conditions."""
        current = self._current_config

        # Find smaller chunk size
        current_chunk_idx = (
            CHUNK_SIZE_OPTIONS.index(current.chunk_size)
            if current.chunk_size in CHUNK_SIZE_OPTIONS
            else 1
        )
        new_chunk_idx = max(0, current_chunk_idx - 1)

        # Lower concurrency
        current_conc_idx = (
            CONCURRENCY_OPTIONS.index(current.concurrency)
            if current.concurrency in CONCURRENCY_OPTIONS
            else 2
        )
        new_conc_idx = max(0, current_conc_idx - 1)

        # Lower segment seconds
        current_seg_idx = (
            SEGMENT_SECONDS_OPTIONS.index(current.max_segment_seconds)
            if current.max_segment_seconds in SEGMENT_SECONDS_OPTIONS
            else 2
        )
        new_seg_idx = max(0, current_seg_idx - 1)

        return TuningConfig(
            chunk_size=CHUNK_SIZE_OPTIONS[new_chunk_idx],
            concurrency=CONCURRENCY_OPTIONS[new_conc_idx],
            max_segment_seconds=SEGMENT_SECONDS_OPTIONS[new_seg_idx],
        )

    def _suggest_balanced_config(self) -> TuningConfig:
        """Suggest balanced settings."""
        current = self._current_config

        # If current is small, try bigger
        if current.chunk_size <= 8000:
            new_chunk = 10000
        else:
            new_chunk = 8000

        # Keep concurrency but try different segment time
        current_seg_idx = (
            SEGMENT_SECONDS_OPTIONS.index(current.max_segment_seconds)
            if current.max_segment_seconds in SEGMENT_SECONDS_OPTIONS
            else 2
        )

        # Try adjacent segment option
        if current_seg_idx < len(SEGMENT_SECONDS_OPTIONS) - 1:
            new_seg_idx = current_seg_idx + 1
        else:
            new_seg_idx = current_seg_idx - 1

        return TuningConfig(
            chunk_size=new_chunk,
            concurrency=current.concurrency,
            max_segment_seconds=SEGMENT_SECONDS_OPTIONS[new_seg_idx],
        )

    def _suggest_aggressive_config(self) -> TuningConfig:
        """Suggest aggressive settings for good conditions."""
        current = self._current_config

        # Find larger chunk size
        current_chunk_idx = (
            CHUNK_SIZE_OPTIONS.index(current.chunk_size)
            if current.chunk_size in CHUNK_SIZE_OPTIONS
            else 1
        )
        new_chunk_idx = min(len(CHUNK_SIZE_OPTIONS) - 1, current_chunk_idx + 1)

        # Higher concurrency
        current_conc_idx = (
            CONCURRENCY_OPTIONS.index(current.concurrency)
            if current.concurrency in CONCURRENCY_OPTIONS
            else 2
        )
        new_conc_idx = min(len(CONCURRENCY_OPTIONS) - 1, current_conc_idx + 1)

        return TuningConfig(
            chunk_size=CHUNK_SIZE_OPTIONS[new_chunk_idx],
            concurrency=CONCURRENCY_OPTIONS[new_conc_idx],
            max_segment_seconds=current.max_segment_seconds,
        )

    def apply_config(self, config: TuningConfig) -> None:
        """Apply a new configuration."""
        self._current_config = config
        self._last_tuning_time = time.time()
        self._tuning_in_progress = False

        self._log(
            f"CONFIG_APPLIED: chunk={config.chunk_size}, "
            f"concurrency={config.concurrency}, "
            f"segment={config.max_segment_seconds}s"
        )

    def record_config_result(
        self,
        config: TuningConfig,
        samples: List[SpeedSample],
        successes: int,
        total: int,
    ) -> None:
        """Record the result of testing a configuration."""
        if not samples:
            return

        avg_speed = sum(s.chars_per_second for s in samples) / len(samples)
        success_rate = successes / max(total, 1)

        # Score = speed * success_rate (prioritize reliability)
        score = avg_speed * (success_rate**2)

        result = TuningResult(
            config=config,
            samples=samples,
            avg_speed=avg_speed,
            success_rate=success_rate,
            score=score,
        )

        self._config_history[config] = result

        # Update best config
        if score > self._best_score:
            self._best_score = score
            self._best_config = config
            self._log(
                f"NEW_BEST_CONFIG: score={score:.1f} "
                f"(speed={avg_speed:.0f}, success={success_rate * 100:.0f}%)"
            )

    def get_best_config(self) -> Optional[TuningConfig]:
        """Get the best known configuration."""
        return self._best_config

    def get_stats(self) -> Dict[str, any]:
        """Get current monitoring statistics."""
        avg_speed = self.get_average_speed()
        trend, trend_status = self.get_speed_trend()

        return {
            "average_speed": avg_speed,
            "target_speed": self.target_speed,
            "min_speed": self.min_speed,
            "samples_count": len(self._samples),
            "total_samples": len(self._all_samples),
            "slow_mode": self._slow_mode,
            "recovery_mode": self._recovery_mode,
            "consecutive_slow": self._consecutive_slow,
            "consecutive_fast": self._consecutive_fast,
            "trend": trend,
            "trend_status": trend_status,
            "current_config": self._current_config.to_dict(),
            "best_config": self._best_config.to_dict() if self._best_config else None,
            "best_score": self._best_score,
            "configs_tested": len(self._config_history),
        }


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
        self._tune_every_n_segments = 2  # Faster adaptation

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
        if avg_speed >= self._monitor.target_speed and trend_status != "degrading":
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
