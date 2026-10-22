"""Observe sample windows, detect stalls and recommend tuning configurations."""

from __future__ import annotations

import time
from collections import deque
from typing import Callable, Deque, Dict, List, Optional, Tuple

from .speed_tuning_contracts import (
    CHUNK_SIZE_OPTIONS,
    CONCURRENCY_OPTIONS,
    EXCELLENT_SPEED,
    MIN_ACCEPTABLE_SPEED,
    MIN_SAMPLES_FOR_DETECTION,
    SEGMENT_SECONDS_OPTIONS,
    SPEED_DROP_THRESHOLD,
    SPEED_RECOVERY_THRESHOLD,
    STALL_DURATION_SECONDS,
    TARGET_CHARS_PER_SECOND,
    WARMUP_SAMPLES,
    SpeedSample,
    TuningConfig,
    TuningResult,
)


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
        # Require N consecutive stalls before signalling — single jittery sample
        # on a small chunk is not representative.
        self._pending_stalls: int = 0
        self._stall_confirm_threshold: int = 2
        # Below this chunk size a slow sample is not representative — small
        # chunks are dominated by request setup, not throughput.
        self._stall_min_chars: int = 2000

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
        is_stall_candidate = (
            duration >= STALL_DURATION_SECONDS
            and speed < self.min_speed
            and chars >= self._stall_min_chars
        )
        if is_stall_candidate:
            self._pending_stalls += 1
            if self._pending_stalls >= self._stall_confirm_threshold:
                self._last_stall_time = time.time()
                self._pending_stalls = 0
                stall_action = (
                    f"STALL_DETECTED: {duration:.0f}s for {chars} chars ({speed:.0f} chars/s)"
                )
        elif speed >= self.min_speed:
            self._pending_stalls = 0
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
                        f"SPEED_DROP: {drop_pct:.0f}% drop ({avg_speed:.0f} chars/s){jitter_note}"
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
