# -*- coding: utf-8 -*-
"""
Network-aware Auto-Tuner for Edge-TTS.

Automatically detects network conditions and adjusts parameters:
- Chunk size (2K-15K chars)
- Concurrency (2-8 parallel requests)
- Segment duration (30-95 seconds)
- Retry delays (exponential backoff)

Key features:
- Starts aggressive (max speed settings)
- Reduces on errors, rate limits, timeouts
- Gradually recovers after success streak
- Persists tuned settings across chapters
- Logs tuning decisions for user visibility
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Dict, List, Optional


class NetworkCondition(Enum):
    """Detected network condition."""

    EXCELLENT = "excellent"  # Low latency, no errors
    GOOD = "good"  # Normal latency, rare errors
    DEGRADED = "degraded"  # High latency or occasional errors
    POOR = "poor"  # Frequent errors, rate limits
    CRITICAL = "critical"  # Consistent failures


@dataclass
class TuningConfig:
    """Current tuning configuration."""

    chunk_size: int = 10000  # chars per request
    concurrency: int = 8  # parallel requests
    segment_seconds: float = 85.0  # max segment duration
    retry_delay: float = 1.0  # base retry delay (seconds)
    max_retries: int = 5  # max retries per segment

    # Limits
    min_chunk_size: int = 2000
    max_chunk_size: int = 15000
    min_concurrency: int = 2
    max_concurrency: int = 8
    min_segment_seconds: float = 30.0
    max_segment_seconds: float = 95.0


@dataclass
class NetworkStats:
    """Statistics for network condition detection."""

    requests: int = 0
    successes: int = 0
    failures: int = 0
    rate_limits: int = 0
    timeouts: int = 0
    total_latency: float = 0.0

    # Tracking windows
    recent_successes: List[float] = field(default_factory=list)  # timestamps
    recent_failures: List[float] = field(default_factory=list)
    recent_latencies: List[float] = field(default_factory=list)

    # Window size (seconds)
    window_size: float = 60.0

    def record_success(self, latency: float) -> None:
        """Record a successful request."""
        now = time.time()
        self.requests += 1
        self.successes += 1
        self.total_latency += latency
        self.recent_successes.append(now)
        self.recent_latencies.append(latency)
        self._cleanup_old_data(now)

    def record_failure(self, is_rate_limit: bool = False, is_timeout: bool = False) -> None:
        """Record a failed request."""
        now = time.time()
        self.requests += 1
        self.failures += 1
        self.recent_failures.append(now)
        if is_rate_limit:
            self.rate_limits += 1
        if is_timeout:
            self.timeouts += 1
        self._cleanup_old_data(now)

    def _cleanup_old_data(self, now: float) -> None:
        """Remove data older than window."""
        cutoff = now - self.window_size
        self.recent_successes = [t for t in self.recent_successes if t > cutoff]
        self.recent_failures = [t for t in self.recent_failures if t > cutoff]
        self.recent_latencies = self.recent_latencies[-50:]  # Keep last 50

    def get_recent_success_rate(self) -> float:
        """Get success rate in recent window."""
        total = len(self.recent_successes) + len(self.recent_failures)
        if total == 0:
            return 1.0
        return len(self.recent_successes) / total

    def get_avg_latency(self) -> float:
        """Get average latency from recent requests."""
        if not self.recent_latencies:
            return 0.0
        return sum(self.recent_latencies) / len(self.recent_latencies)

    def get_consecutive_failures(self) -> int:
        """Count consecutive recent failures."""
        if not self.recent_failures:
            return 0

        time.time()
        last_success = max(self.recent_successes) if self.recent_successes else 0
        return sum(1 for t in self.recent_failures if t > last_success)


class NetworkTuner:
    """
    Network-aware auto-tuner for Edge-TTS.

    Automatically adjusts parameters based on network conditions.
    """

    def __init__(
        self,
        log_callback: Optional[Callable[[str], None]] = None,
        verbose: bool = False,
    ):
        self.config = TuningConfig()
        self.stats = NetworkStats()
        self.log_callback = log_callback
        self.verbose = verbose

        # State tracking
        self.condition = NetworkCondition.GOOD
        self.consecutive_successes = 0
        self.consecutive_failures = 0
        self.last_adjustment_time = 0.0
        self.adjustment_cooldown = 5.0  # seconds between adjustments

        # Recovery tracking
        self.recovery_mode = False
        self.recovery_start_time = 0.0
        self.pre_failure_config: Optional[TuningConfig] = None

    def _log(self, message: str) -> None:
        """Log a message."""
        if self.log_callback:
            self.log_callback(message)
        if self.verbose:
            print(f"[NetworkTuner] {message}")

    def detect_condition(self) -> NetworkCondition:
        """Detect current network condition based on stats."""
        success_rate = self.stats.get_recent_success_rate()
        avg_latency = self.stats.get_avg_latency()
        consecutive_failures = self.stats.get_consecutive_failures()

        # Critical: many consecutive failures
        if consecutive_failures >= 3:
            return NetworkCondition.CRITICAL

        # Poor: low success rate or many rate limits
        if success_rate < 0.7 or self.stats.rate_limits > 2:
            return NetworkCondition.POOR

        # Degraded: moderate issues
        if success_rate < 0.9 or avg_latency > 5.0:
            return NetworkCondition.DEGRADED

        # Excellent: high success, low latency
        if success_rate >= 0.98 and avg_latency < 2.0:
            return NetworkCondition.EXCELLENT

        return NetworkCondition.GOOD

    def record_success(self, latency: float) -> None:
        """Record a successful request and potentially tune up."""
        self.stats.record_success(latency)
        self.consecutive_successes += 1
        self.consecutive_failures = 0

        # Update condition
        self.condition = self.detect_condition()

        # Try to recover speed after success streak
        if self.consecutive_successes >= 5 and self._can_adjust():
            self._try_increase_speed()

    def record_failure(
        self,
        is_rate_limit: bool = False,
        is_timeout: bool = False,
        error_msg: str = "",
    ) -> None:
        """Record a failed request and tune down."""
        self.stats.record_failure(is_rate_limit, is_timeout)
        self.consecutive_failures += 1
        self.consecutive_successes = 0

        # Update condition
        old_condition = self.condition
        self.condition = self.detect_condition()

        # Log condition change
        if self.condition != old_condition:
            self._log(f"📡 Rede: {old_condition.value} → {self.condition.value}")

        # Reduce speed based on failure type and condition
        if self._can_adjust():
            self._reduce_speed(is_rate_limit, is_timeout, error_msg)

    def _can_adjust(self) -> bool:
        """Check if enough time has passed since last adjustment."""
        now = time.time()
        return now - self.last_adjustment_time >= self.adjustment_cooldown

    def _reduce_speed(
        self,
        is_rate_limit: bool = False,
        is_timeout: bool = False,
        error_msg: str = "",
    ) -> None:
        """Reduce speed settings based on error type."""
        now = time.time()
        self.last_adjustment_time = now

        # Save pre-failure config for recovery
        if not self.recovery_mode:
            self.pre_failure_config = TuningConfig(
                chunk_size=self.config.chunk_size,
                concurrency=self.config.concurrency,
                segment_seconds=self.config.segment_seconds,
            )
            self.recovery_mode = True
            self.recovery_start_time = now

        changes = []

        if self.condition == NetworkCondition.CRITICAL:
            # Aggressive reduction for critical
            old_chunk = self.config.chunk_size
            old_conc = self.config.concurrency
            old_seg = self.config.segment_seconds

            self.config.chunk_size = max(
                self.config.min_chunk_size, int(self.config.chunk_size * 0.5)
            )
            self.config.concurrency = self.config.min_concurrency
            self.config.segment_seconds = max(
                self.config.min_segment_seconds, self.config.segment_seconds * 0.6
            )

            if old_chunk != self.config.chunk_size:
                changes.append(f"chunk: {old_chunk}→{self.config.chunk_size}")
            if old_conc != self.config.concurrency:
                changes.append(f"concurrency: {old_conc}→{self.config.concurrency}")
            if old_seg != self.config.segment_seconds:
                changes.append(f"segment: {old_seg:.0f}s→{self.config.segment_seconds:.0f}s")

        elif is_rate_limit:
            # Rate limit: reduce concurrency and chunk size
            old_conc = self.config.concurrency
            old_chunk = self.config.chunk_size

            self.config.concurrency = max(self.config.min_concurrency, self.config.concurrency - 2)
            self.config.chunk_size = max(
                self.config.min_chunk_size, int(self.config.chunk_size * 0.7)
            )

            if old_conc != self.config.concurrency:
                changes.append(f"concurrency: {old_conc}→{self.config.concurrency}")
            if old_chunk != self.config.chunk_size:
                changes.append(f"chunk: {old_chunk}→{self.config.chunk_size}")

        elif is_timeout:
            # Timeout: reduce chunk size and segment duration
            old_chunk = self.config.chunk_size
            old_seg = self.config.segment_seconds

            self.config.chunk_size = max(
                self.config.min_chunk_size, int(self.config.chunk_size * 0.8)
            )
            self.config.segment_seconds = max(
                self.config.min_segment_seconds, self.config.segment_seconds * 0.8
            )

            if old_chunk != self.config.chunk_size:
                changes.append(f"chunk: {old_chunk}→{self.config.chunk_size}")
            if old_seg != self.config.segment_seconds:
                changes.append(f"segment: {old_seg:.0f}s→{self.config.segment_seconds:.0f}s")

        else:
            # Generic failure: moderate reduction
            old_chunk = self.config.chunk_size
            self.config.chunk_size = max(
                self.config.min_chunk_size, int(self.config.chunk_size * 0.85)
            )
            if old_chunk != self.config.chunk_size:
                changes.append(f"chunk: {old_chunk}→{self.config.chunk_size}")

        if changes:
            self._log(f"⚠️ Ajustando: {', '.join(changes)}")

    def _try_increase_speed(self) -> None:
        """Try to increase speed after success streak."""
        now = time.time()
        self.last_adjustment_time = now

        # Don't increase if still in poor/critical
        if self.condition in (NetworkCondition.POOR, NetworkCondition.CRITICAL):
            return

        changes = []

        # Increase chunk size
        if self.config.chunk_size < self.config.max_chunk_size:
            old_chunk = self.config.chunk_size
            increment = 2000 if self.condition == NetworkCondition.EXCELLENT else 1000
            self.config.chunk_size = min(
                self.config.max_chunk_size, self.config.chunk_size + increment
            )
            if old_chunk != self.config.chunk_size:
                changes.append(f"chunk: {old_chunk}→{self.config.chunk_size}")

        # Increase concurrency
        if self.condition == NetworkCondition.EXCELLENT:
            if self.config.concurrency < self.config.max_concurrency:
                old_conc = self.config.concurrency
                self.config.concurrency = min(
                    self.config.max_concurrency, self.config.concurrency + 1
                )
                if old_conc != self.config.concurrency:
                    changes.append(f"concurrency: {old_conc}→{self.config.concurrency}")

        # Increase segment duration
        if self.config.segment_seconds < self.config.max_segment_seconds:
            if self.condition == NetworkCondition.EXCELLENT:
                old_seg = self.config.segment_seconds
                self.config.segment_seconds = min(
                    self.config.max_segment_seconds, self.config.segment_seconds + 10
                )
                if old_seg != self.config.segment_seconds:
                    changes.append(f"segment: {old_seg:.0f}s→{self.config.segment_seconds:.0f}s")

        if changes:
            self._log(f"✨ Aumentando velocidade: {', '.join(changes)}")

        # Check if fully recovered
        if (
            self.config.chunk_size >= self.config.max_chunk_size
            and self.config.concurrency >= self.config.max_concurrency
        ):
            if self.recovery_mode:
                self._log("🚀 Maximum speed recovered!")
                self.recovery_mode = False

        self.consecutive_successes = 0

    def get_retry_delay(self, attempt: int) -> float:
        """Get retry delay with exponential backoff."""
        base_delay = self.config.retry_delay

        # Increase base delay in poor conditions
        if self.condition == NetworkCondition.CRITICAL:
            base_delay *= 3
        elif self.condition == NetworkCondition.POOR:
            base_delay *= 2

        # Exponential backoff with jitter
        import random

        delay = base_delay * (2**attempt)
        jitter = random.uniform(0.5, 1.5)
        return min(delay * jitter, 30.0)  # Max 30 seconds

    def should_retry(self, attempt: int) -> bool:
        """Check if we should retry based on attempt count and conditions."""
        if attempt >= self.config.max_retries:
            return False

        # Always retry in excellent/good conditions
        if self.condition in (NetworkCondition.EXCELLENT, NetworkCondition.GOOD):
            return True

        # Fewer retries in poor/critical conditions
        if self.condition == NetworkCondition.CRITICAL:
            return attempt < 2

        return True

    def get_config_dict(self) -> Dict[str, any]:
        """Get current config as dictionary for engine."""
        return {
            "chunk_char_limit": self.config.chunk_size,
            "max_concurrency": self.config.concurrency,
            "max_segment_seconds": self.config.segment_seconds,
        }

    def get_status_message(self) -> str:
        """Get human-readable status message."""
        condition_icons = {
            NetworkCondition.EXCELLENT: "🟢",
            NetworkCondition.GOOD: "🟢",
            NetworkCondition.DEGRADED: "🟡",
            NetworkCondition.POOR: "🟠",
            NetworkCondition.CRITICAL: "🔴",
        }

        icon = condition_icons.get(self.condition, "⚪")
        success_rate = self.stats.get_recent_success_rate() * 100
        avg_latency = self.stats.get_avg_latency()

        return (
            f"{icon} Rede: {self.condition.value} | "
            f"Taxa: {success_rate:.0f}% | "
            f"Latency: {avg_latency:.1f}s | "
            f"Config: {self.config.chunk_size} chars, "
            f"{self.config.concurrency} parallel"
        )

    def reset(self) -> None:
        """Reset tuner to initial state."""
        self.config = TuningConfig()
        self.stats = NetworkStats()
        self.condition = NetworkCondition.GOOD
        self.consecutive_successes = 0
        self.consecutive_failures = 0
        self.recovery_mode = False
        self.pre_failure_config = None


# Global tuner instance (per-job tuners should be created separately)
_global_tuner: Optional[NetworkTuner] = None


def get_global_tuner(log_callback: Optional[Callable[[str], None]] = None) -> NetworkTuner:
    """Get or create global network tuner."""
    global _global_tuner
    if _global_tuner is None:
        _global_tuner = NetworkTuner(log_callback=log_callback)
    elif log_callback and _global_tuner.log_callback is None:
        _global_tuner.log_callback = log_callback
    return _global_tuner


def reset_global_tuner() -> None:
    """Reset global tuner."""
    global _global_tuner
    if _global_tuner:
        _global_tuner.reset()
    _global_tuner = None


__all__ = [
    "NetworkTuner",
    "NetworkCondition",
    "TuningConfig",
    "NetworkStats",
    "get_global_tuner",
    "reset_global_tuner",
]
