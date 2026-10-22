# -*- coding: utf-8 -*-
"""Shared Edge adaptive control with facade-owned state."""

from __future__ import annotations

import asyncio
from typing import Callable, Dict, Optional


def _get_global_edge_limiter(loop: asyncio.AbstractEventLoop) -> asyncio.Semaphore:
    """Return a shared limiter per event loop to avoid cross-job oversubscription."""
    from . import edge_engine as _runtime
    limiter = _runtime._edge_rate_limiters.get(id(loop))
    if limiter is None:
        limiter = _runtime.asyncio.Semaphore(_runtime._edge_max_concurrency)
        _runtime._edge_rate_limiters[id(loop)] = limiter
    return limiter


def _is_rate_limit_error(exc: Exception) -> bool:
    """Check if exception indicates a 403 rate limit from Microsoft."""
    exc_str = str(exc).lower()
    exc_class = exc.__class__.__name__.lower()

    # Check for 403 status code
    if "403" in exc_str:
        return True

    # Check for rate limit indicators
    rate_limit_indicators = [
        "rate limit",
        "too many requests",
        "temporarily blocked",
        "forbidden",
        "throttl",
    ]
    return any(
        indicator in exc_str or indicator in exc_class for indicator in rate_limit_indicators
    )


async def _handle_rate_limit(log_callback: Optional[Callable] = None) -> float:
    """
    Handle rate limit by applying exponential backoff.

    Returns recommended wait time in seconds.
    """
    from . import edge_engine as _runtime

    now = _runtime.asyncio.get_event_loop().time()
    _runtime._edge_rate_limit_count += 1
    _runtime._edge_consecutive_successes = 0

    # Exponential backoff: 5s, 10s, 20s, 40s (max 60s)
    backoff = min(5.0 * (2 ** min(_runtime._edge_rate_limit_count - 1, 3)), 60.0)
    _runtime._edge_rate_limit_until = now + backoff

    # Auto-reduce parallelism on rate limit
    if _runtime._edge_rate_limit_count >= 2 and _runtime._edge_max_concurrency > 2:
        old_concurrency = _runtime._edge_max_concurrency
        _runtime._edge_max_concurrency = max(2, _runtime._edge_max_concurrency - 1)
        # Update existing limiters
        for loop_id in list(_runtime._edge_rate_limiters.keys()):
            _runtime._edge_rate_limiters[loop_id] = _runtime.asyncio.Semaphore(_runtime._edge_max_concurrency)
        if log_callback:
            log_callback(
                f"🔻 Rate limit (403), reducing parallelism: {old_concurrency} → {_runtime._edge_max_concurrency}"
            )

    # Also reduce chunk size while throttled to keep requests small
    _runtime._reduce_chunk_size(log_callback)

    if log_callback:
        log_callback(
            f"⏳ Rate limit detected, waiting {backoff:.1f}s (total: {_runtime._edge_rate_limit_count})"
        )

    return backoff


async def _record_success() -> None:
    """Record successful request for adaptive scaling."""
    from . import edge_engine as _runtime

    _runtime._edge_consecutive_successes += 1

    # Scale up after EDGE_RECOVERY_SUCCESS_THRESHOLD consecutive successes
    # and no recent rate limits. Lower threshold means concurrency/chunk-size
    # recovery is faster after a temporary rate-limit burst. Default lowered
    # from 15 → 7 (Apr 2026) after the Carl conversion showed we were
    # leaving ~5-10% throughput on the table waiting for the old threshold.
    try:
        recovery_threshold = max(1, int(_runtime.os.getenv("EDGE_RECOVERY_SUCCESS_THRESHOLD", "7") or "7"))
    except (TypeError, ValueError):
        recovery_threshold = 7
    if _runtime._edge_consecutive_successes >= recovery_threshold and _runtime._edge_rate_limit_count > 0:
        now = _runtime.asyncio.get_event_loop().time()
        time_since_limit = now - _runtime._edge_rate_limit_until + 30  # 30s buffer (was 60s)

        if time_since_limit > 60:  # was 120s
            # Scale up parallelism
            if _runtime._edge_max_concurrency < _runtime._edge_concurrency_cap:
                _runtime._edge_max_concurrency = min(_runtime._edge_concurrency_cap, _runtime._edge_max_concurrency + 1)
                # Update existing limiters
                for loop_id in list(_runtime._edge_rate_limiters.keys()):
                    _runtime._edge_rate_limiters[loop_id] = _runtime.asyncio.Semaphore(_runtime._edge_max_concurrency)

            # Scale up chunk size
            if _runtime._edge_current_chunk_size < _runtime._DEFAULT_CHUNK_SIZE:
                _runtime._edge_current_chunk_size = min(_runtime._DEFAULT_CHUNK_SIZE, _runtime._edge_current_chunk_size + 1000)

            # Clear rate limit flag after sustained recovery
            _runtime._edge_rate_limit_count = 0

            _runtime._edge_consecutive_successes = 0


def _reduce_chunk_size(log_callback: Optional[Callable] = None) -> int:
    """Reduce chunk size on failure. Returns new chunk size."""
    from . import edge_engine as _runtime

    _runtime._edge_chunk_failure_count += 1

    # Reduce by 20% on each failure, minimum 3000
    old_size = _runtime._edge_current_chunk_size
    reduction = max(1000, int(_runtime._edge_current_chunk_size * 0.2))
    _runtime._edge_current_chunk_size = max(_runtime._SAFE_CHUNK_MIN, _runtime._edge_current_chunk_size - reduction)

    if log_callback and old_size != _runtime._edge_current_chunk_size:
        log_callback(f"🔻 Reducing chunk size: {old_size} → {_runtime._edge_current_chunk_size}")

    return _runtime._edge_current_chunk_size


def get_adaptive_chunk_size() -> int:
    """Get current adaptive chunk size."""
    from . import edge_engine as _runtime
    return _runtime._edge_current_chunk_size


def get_adaptive_concurrency() -> int:
    """Get current adaptive concurrency."""
    from . import edge_engine as _runtime
    return _runtime._edge_max_concurrency


def reset_adaptive_settings() -> None:
    """Reset adaptive settings to defaults (for new conversion)."""
    from . import edge_engine as _runtime

    _runtime._edge_current_chunk_size = _runtime._DEFAULT_CHUNK_SIZE
    _runtime._edge_chunk_failure_count = 0
    _runtime._edge_rate_limit_count = 0
    _runtime._edge_consecutive_successes = 0
    _runtime._edge_max_concurrency = _runtime._DEFAULT_CONCURRENCY

    # Update existing limiters
    for loop_id in list(_runtime._edge_rate_limiters.keys()):
        _runtime._edge_rate_limiters[loop_id] = _runtime.asyncio.Semaphore(_runtime._edge_max_concurrency)

    # Reset the global tuner
    from ..speed_monitor import reset_edge_tuner

    reset_edge_tuner()


async def _wait_if_rate_limited() -> bool:
    """Wait if currently in rate limit cooldown. Returns True if waited."""
    from . import edge_engine as _runtime

    now = _runtime.asyncio.get_event_loop().time()
    if now < _runtime._edge_rate_limit_until:
        wait_time = _runtime._edge_rate_limit_until - now
        await _runtime.asyncio.sleep(wait_time)
        return True
    return False


def get_edge_performance_stats() -> Dict[str, any]:
    """Get current Edge TTS performance statistics for monitoring."""
    from . import edge_engine as _runtime
    try:
        loop_time = _runtime.asyncio.get_event_loop().time()
        is_limited = loop_time < _runtime._edge_rate_limit_until if _runtime._edge_rate_limit_until > 0 else False
    except RuntimeError:
        is_limited = False

    return {
        "current_concurrency": _runtime._edge_max_concurrency,
        "concurrency_cap": _runtime._edge_concurrency_cap,
        "current_chunk_size": _runtime._edge_current_chunk_size,
        "chunk_size_default": _runtime._DEFAULT_CHUNK_SIZE,
        "chunk_size_range": (_runtime._SAFE_CHUNK_MIN, _runtime._SAFE_CHUNK_MAX),
        "batch_delay_ms": _runtime._edge_batch_delay * 1000,
        "rate_limit_count": _runtime._edge_rate_limit_count,
        "chunk_failure_count": _runtime._edge_chunk_failure_count,
        "consecutive_successes": _runtime._edge_consecutive_successes,
        "is_rate_limited": is_limited,
    }
