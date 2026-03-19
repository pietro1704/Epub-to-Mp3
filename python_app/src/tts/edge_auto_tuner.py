# -*- coding: utf-8 -*-
"""
Edge TTS Auto-Tuner: Automatic performance detection and rate limit handling.

Based on research findings:
- Safe chunk size: 3,000-8,000 chars (max ~15,000 before issues)
- Safe parallelism: 2-4 concurrent requests (risk of 403 at higher values)
- Audio duration limit: 10 minutes per request
- Connection per request: Microsoft's design, can't pool connections
- Rate limiting: IP-based, undocumented threshold, triggers 403

References:
- https://github.com/rany2/edge-tts/issues/347 (connection pooling rejected)
- https://github.com/rany2/edge-tts/issues/190 (long text issues)
- https://pyvideotrans.com/edgetts-error (rate limit workarounds)
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from dataclasses import dataclass
from typing import Callable, Dict, Optional

logger = logging.getLogger(__name__)


@dataclass
class EdgeTTSPerformanceProfile:
    """Performance settings based on research and auto-detection."""

    # Chunk settings (research: 3000 safe, 15000 max)
    chunk_char_limit: int = 8000
    chunk_char_min: int = 4000
    chunk_char_max: int = 15000

    # Segment duration (research: 10 min max per request)
    max_segment_seconds: float = 90.0
    max_segment_min: float = 30.0
    max_segment_max: float = 600.0

    # Parallelism (research: 2-4 safe, >8 triggers rate limits)
    parallel_slots: int = 4
    parallel_min: int = 1
    parallel_max: int = 8

    # Rate limit tracking
    rate_limit_count: int = 0
    last_rate_limit_time: float = 0.0
    rate_limit_cooldown_seconds: float = 30.0

    # Exponential backoff for 403 errors
    backoff_base_seconds: float = 5.0
    backoff_max_seconds: float = 60.0
    current_backoff: float = 0.0

    # Success tracking for adaptive scaling
    consecutive_successes: int = 0
    scale_up_threshold: int = 20  # Scale up after N successes

    # Name for logging
    name: str = "default"


class EdgeTTSAutoTuner:
    """
    Automatic performance tuner for Edge TTS.

    Monitors rate limits and adjusts settings dynamically to maximize
    throughput while avoiding 403 blocks.
    """

    # Class-level shared state for rate limiting across instances
    _global_rate_limit_count: int = 0
    _global_last_rate_limit: float = 0.0
    _global_lock: Optional[asyncio.Lock] = None

    # Research-based default profiles
    PROFILES = {
        "conservative": EdgeTTSPerformanceProfile(
            chunk_char_limit=6000,
            max_segment_seconds=75.0,
            parallel_slots=2,
            name="conservative",
        ),
        "balanced": EdgeTTSPerformanceProfile(
            chunk_char_limit=8000,
            max_segment_seconds=90.0,
            parallel_slots=4,
            name="balanced",
        ),
        "aggressive": EdgeTTSPerformanceProfile(
            chunk_char_limit=4000,
            max_segment_seconds=70.0,
            parallel_slots=8,
            name="aggressive",
        ),
    }

    def __init__(
        self,
        initial_profile: str = "balanced",
        log_callback: Optional[Callable[[str], None]] = None,
        verbose: bool = False,
    ):
        self.verbose = verbose
        self.log_callback = log_callback

        # Start with specified profile
        if initial_profile in self.PROFILES:
            self.profile = EdgeTTSPerformanceProfile(**vars(self.PROFILES[initial_profile]))
        else:
            self.profile = EdgeTTSPerformanceProfile(name=initial_profile)

        # Override from environment if set
        self._apply_env_overrides()

        # Request tracking
        self._request_times: list[float] = []
        self._request_window_seconds: float = 60.0

    def _log(self, message: str) -> None:
        """Log message using callback or logger."""
        if self.log_callback:
            self.log_callback(message)
        elif self.verbose:
            print(message)
        logger.debug(message)

    def _apply_env_overrides(self) -> None:
        """Apply environment variable overrides to profile."""
        env_chunk = os.getenv("EDGE_CHUNK_CHARS")
        if env_chunk:
            try:
                self.profile.chunk_char_limit = max(
                    self.profile.chunk_char_min, min(int(env_chunk), self.profile.chunk_char_max)
                )
            except ValueError:
                pass

        env_segment = os.getenv("EDGE_MAX_SEGMENT_SECONDS")
        if env_segment:
            try:
                self.profile.max_segment_seconds = max(
                    self.profile.max_segment_min,
                    min(float(env_segment), self.profile.max_segment_max),
                )
            except ValueError:
                pass

        env_parallel = os.getenv("EDGE_MAX_CONCURRENCY")
        if env_parallel:
            try:
                self.profile.parallel_slots = max(
                    self.profile.parallel_min, min(int(env_parallel), self.profile.parallel_max)
                )
            except ValueError:
                pass

    @classmethod
    async def _get_global_lock(cls) -> asyncio.Lock:
        """Get or create global lock for thread-safe rate limit tracking."""
        if cls._global_lock is None:
            cls._global_lock = asyncio.Lock()
        return cls._global_lock

    async def record_rate_limit(self, error_code: int = 403) -> float:
        """
        Record a rate limit event and calculate backoff time.

        Returns:
            Recommended wait time in seconds before next request.
        """
        lock = await self._get_global_lock()
        async with lock:
            now = time.time()

            # Update global tracking
            EdgeTTSAutoTuner._global_rate_limit_count += 1
            EdgeTTSAutoTuner._global_last_rate_limit = now

            # Update instance tracking
            self.profile.rate_limit_count += 1
            self.profile.last_rate_limit_time = now
            self.profile.consecutive_successes = 0

            # Calculate exponential backoff
            backoff = min(
                self.profile.backoff_base_seconds
                * (2 ** min(self.profile.rate_limit_count - 1, 4)),
                self.profile.backoff_max_seconds,
            )
            self.profile.current_backoff = backoff

            # Auto-reduce parallelism on rate limit
            if self.profile.parallel_slots > self.profile.parallel_min:
                old_slots = self.profile.parallel_slots
                self.profile.parallel_slots = max(
                    self.profile.parallel_min, self.profile.parallel_slots - 1
                )
                self._log(
                    f"🔻 Rate limit detectado (403), reduzindo paralelismo: {old_slots} → {self.profile.parallel_slots}"
                )

            # Auto-reduce chunk size if many rate limits
            if (
                self.profile.rate_limit_count >= 3
                and self.profile.chunk_char_limit > self.profile.chunk_char_min
            ):
                old_chunk = self.profile.chunk_char_limit
                self.profile.chunk_char_limit = max(
                    self.profile.chunk_char_min, int(self.profile.chunk_char_limit * 0.8)
                )
                self._log(
                    f"🔻 Muitos rate limits, reduzindo chunks: {old_chunk} → {self.profile.chunk_char_limit}"
                )

            self._log(
                f"⏳ Backoff recomendado: {backoff:.1f}s (rate limits: {self.profile.rate_limit_count})"
            )

            return backoff

    async def record_success(self) -> None:
        """Record a successful request and potentially scale up."""
        lock = await self._get_global_lock()
        async with lock:
            self.profile.consecutive_successes += 1

            # Reset backoff on success
            if self.profile.current_backoff > 0:
                self.profile.current_backoff = max(0, self.profile.current_backoff - 1)

            # Scale up after many consecutive successes
            if self.profile.consecutive_successes >= self.profile.scale_up_threshold:
                # Check if enough time has passed since last rate limit
                time_since_limit = time.time() - self.profile.last_rate_limit_time

                if time_since_limit > self.profile.rate_limit_cooldown_seconds * 2:
                    # Safe to try scaling up
                    if self.profile.parallel_slots < self.profile.parallel_max:
                        old_slots = self.profile.parallel_slots
                        self.profile.parallel_slots = min(
                            self.profile.parallel_max, self.profile.parallel_slots + 1
                        )
                        self._log(
                            f"🔺 Stable performance, increasing parallelism: {old_slots} → {self.profile.parallel_slots}"
                        )
                        self.profile.consecutive_successes = 0

    def is_rate_limited(self) -> bool:
        """Check if currently in rate limit cooldown."""
        if self.profile.last_rate_limit_time == 0:
            return False

        time_since_limit = time.time() - self.profile.last_rate_limit_time
        return time_since_limit < self.profile.rate_limit_cooldown_seconds

    def get_current_backoff(self) -> float:
        """Get current recommended backoff time."""
        if not self.is_rate_limited():
            return 0.0

        time_since_limit = time.time() - self.profile.last_rate_limit_time
        remaining = max(0, self.profile.current_backoff - time_since_limit)
        return remaining

    async def wait_if_rate_limited(self) -> bool:
        """
        Wait if currently rate limited.

        Returns:
            True if had to wait, False otherwise.
        """
        backoff = self.get_current_backoff()
        if backoff > 0:
            self._log(f"⏸️ Waiting for rate limit: {backoff:.1f}s")
            await asyncio.sleep(backoff)
            return True
        return False

    def get_settings(self) -> Dict[str, any]:
        """Get current tuned settings for EdgeTTSEngine."""
        return {
            "chunk_char_limit": self.profile.chunk_char_limit,
            "max_segment_seconds": self.profile.max_segment_seconds,
            "parallel_slots": self.profile.parallel_slots,
        }

    def apply_to_engine(self, engine) -> None:
        """Apply current settings to an EdgeTTSEngine instance."""
        engine.apply_speed_profile(
            chunk_char_limit=self.profile.chunk_char_limit,
            max_segment_seconds=self.profile.max_segment_seconds,
        )
        engine._parallel_slots = self.profile.parallel_slots

        if self.verbose:
            self._log(
                f"⚡ Auto-tuner aplicado: chunks={self.profile.chunk_char_limit}, "
                f"segment={self.profile.max_segment_seconds:.0f}s, "
                f"parallel={self.profile.parallel_slots}"
            )

    def get_status(self) -> str:
        """Get human-readable status string."""
        status = f"Profile: {self.profile.name}"
        status += f" | Chunks: {self.profile.chunk_char_limit}"
        status += f" | Parallel: {self.profile.parallel_slots}"
        status += f" | Rate limits: {self.profile.rate_limit_count}"
        if self.is_rate_limited():
            status += f" | Cooldown: {self.get_current_backoff():.1f}s"
        return status


# Global auto-tuner instance for shared rate limit tracking
_global_auto_tuner: Optional[EdgeTTSAutoTuner] = None


def get_global_auto_tuner(
    profile: str = "balanced",
    verbose: bool = False,
    log_callback: Optional[Callable[[str], None]] = None,
) -> EdgeTTSAutoTuner:
    """Get or create global auto-tuner instance."""
    global _global_auto_tuner

    if _global_auto_tuner is None:
        _global_auto_tuner = EdgeTTSAutoTuner(
            initial_profile=profile,
            verbose=verbose,
            log_callback=log_callback,
        )

    return _global_auto_tuner


def reset_global_auto_tuner() -> None:
    """Reset global auto-tuner (useful for testing)."""
    global _global_auto_tuner
    _global_auto_tuner = None
    EdgeTTSAutoTuner._global_rate_limit_count = 0
    EdgeTTSAutoTuner._global_last_rate_limit = 0.0


__all__ = [
    "EdgeTTSAutoTuner",
    "EdgeTTSPerformanceProfile",
    "get_global_auto_tuner",
    "reset_global_auto_tuner",
]
