# -*- coding: utf-8 -*-
"""Edge TTS engine wrapper used by the converter and tests."""

from __future__ import annotations

import asyncio
import importlib
import inspect
import os
import re

# **SSL BYPASS**: Monkeypatch SSL BEFORE importing edge_tts
# IMPORTANT: Required because Microsoft certificate (api.msedgeservices.com) is expired
# Edge-TTS uses ssl.create_default_context(cafile=certifi.where())
import ssl as _ssl_module
from contextlib import AsyncExitStack, suppress
from pathlib import Path
from typing import Callable, Dict, List, Optional, Set, Tuple
from unittest.mock import Mock

from ..speed_monitor import AdaptiveEdgeTuner, get_edge_tuner
from ..synthesis_tracker import SynthesisTracker
from ..utils import TextValidator
from .network_tuner import NetworkTuner

# Save original function
_original_create_default_context = _ssl_module.create_default_context


# Replace with unverified version
def _create_unverified_context_wrapper(*args, **kwargs):
    """Always returns unverified SSL context, ignoring parameters"""
    ctx = _ssl_module._create_unverified_context()
    return ctx


_ssl_module.create_default_context = _create_unverified_context_wrapper
_ssl_module._create_default_https_context = _ssl_module._create_unverified_context

edge_tts = None

try:
    _segment_seconds_env = float(os.getenv("EDGE_MAX_SEGMENT_SECONDS", "85"))
except (TypeError, ValueError):
    _segment_seconds_env = 75.0

MAX_EDGE_SEGMENT_SECONDS = 600.0  # Align with Edge's ~10 min per request limit
DEFAULT_EDGE_SEGMENT_SECONDS = max(30.0, min(_segment_seconds_env, MAX_EDGE_SEGMENT_SECONDS))
WORDS_PER_MINUTE = 150
MIN_WORDS_PER_SEGMENT = 40
MAX_SEGMENT_SPLIT_ATTEMPTS = 2
MIN_SEGMENT_RETRY_CHARS = 600
SIMPLIFIED_SEGMENT_MAX_CHARS = 1800
_SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+")

# If Edge returns no audio at all, it's often a connectivity / service issue.
# Use a short circuit-breaker to avoid spending minutes retrying the same request.
EDGE_NOAUDIO_COOLDOWN_SECONDS = float(os.getenv("EDGE_NOAUDIO_COOLDOWN_SECONDS", "60"))

# Import SSL/Certificate error types
try:
    import ssl

    from aiohttp import ClientConnectorCertificateError, ClientConnectorError
except ImportError:
    ClientConnectorCertificateError = None  # type: ignore
    ClientConnectorError = None  # type: ignore
    ssl = None  # type: ignore

# ==============================================================================
# **PERFORMANCE**: Research-based settings for Edge-TTS optimization
# ==============================================================================
# Research (Jan 2026):
#
# CHUNK SIZE:
#   - Safe range: 3,000-8,000 chars (recommended)
#   - Max safe: 15,000 chars (Obsidian Edge-TTS plugin limit)
#   - 39k+ chars: Audio often incomplete (GitHub #190)
#   - Audio limit: 10 minutes per request
#
# PARALLELISM:
#   - Safe: 2-4 concurrent connections
#   - When rate limited: 1 concurrent + 5s delays (pyVideoTrans)
#   - Max tested: 8 (above triggers 403 errors)
#   - Microsoft uses new WebSocket per request (no connection pooling)
#
# RATE LIMITING:
#   - IP-based blocking (undocumented threshold)
#   - 403 errors = too many requests from same IP
#   - Solution: Exponential backoff + reduce parallelism
#
# Sources:
#   - github.com/rany2/edge-tts/issues/190 (chunk limits)
#   - github.com/rany2/edge-tts/issues/290 (403 errors)
#   - github.com/travisvn/obsidian-edge-tts (15k char limit)
#   - pyvideotrans.com/edgetts-error (rate limiting)
#   - learn.microsoft.com/azure/ai-services/speech-service (Azure limits)
# ==============================================================================

# Defaults based on research + aggressive throughput target (Jan 2026)
# Target: 200+ chars/s with higher concurrency/segment sizes.
# Benchmark (Jan 2026): 10K chunks + 8 concurrent = 62.6 chars/s (best)
_DEFAULT_CHUNK_SIZE = 10000  # Maximum speed from benchmark testing
_DEFAULT_CONCURRENCY = 8
_SAFE_CHUNK_MIN = 2000  # Minimum safe chunk size (reduced for rate-limit recovery)
_SAFE_CHUNK_MAX = 15000  # Upper bound for throughput testing
_SAFE_CONCURRENCY_MIN = 2  # Always use some parallelism
_SAFE_CONCURRENCY_MAX = 8  # Hard cap to avoid rate limiting

# Inter-batch delay for HF/web deployments (helps avoid rate limits)
try:
    _edge_batch_delay = float(os.getenv("EDGE_BATCH_DELAY_MS", "0").strip() or "0")
except (TypeError, ValueError):
    _edge_batch_delay = 0.0
_edge_batch_delay = max(0.0, min(_edge_batch_delay, 5000.0)) / 1000.0  # Convert to seconds

try:
    _edge_max_concurrency = int(
        os.getenv("EDGE_MAX_CONCURRENCY", str(_DEFAULT_CONCURRENCY)).strip()
        or str(_DEFAULT_CONCURRENCY)
    )
except (TypeError, ValueError):
    _edge_max_concurrency = _DEFAULT_CONCURRENCY
try:
    _edge_concurrency_cap = int(
        os.getenv("EDGE_MAX_CONCURRENCY_CAP", str(_SAFE_CONCURRENCY_MAX)).strip()
        or str(_SAFE_CONCURRENCY_MAX)
    )
except (TypeError, ValueError):
    _edge_concurrency_cap = _SAFE_CONCURRENCY_MAX
_edge_concurrency_cap = max(_SAFE_CONCURRENCY_MIN, min(_edge_concurrency_cap, 8))
_edge_max_concurrency = max(
    _SAFE_CONCURRENCY_MIN, min(_edge_max_concurrency, _edge_concurrency_cap)
)
_edge_rate_limiters: Dict[int, asyncio.Semaphore] = {}

# Global rate limit tracking
_edge_rate_limit_until: float = 0.0
_edge_rate_limit_count: int = 0
_edge_consecutive_successes: int = 0

# Adaptive chunk size tracking
_edge_current_chunk_size: int = _DEFAULT_CHUNK_SIZE
_edge_chunk_failure_count: int = 0
_EDGE_RATE_LIMIT_TRIGGER_CHARS: int = int(
    os.getenv("EDGE_RATE_LIMIT_TRIGGER_CHARS", "20000") or 20000
)


def _get_global_edge_limiter(loop: asyncio.AbstractEventLoop) -> asyncio.Semaphore:
    """Return a shared limiter per event loop to avoid cross-job oversubscription."""
    limiter = _edge_rate_limiters.get(id(loop))
    if limiter is None:
        limiter = asyncio.Semaphore(_edge_max_concurrency)
        _edge_rate_limiters[id(loop)] = limiter
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
    global \
        _edge_rate_limit_until, \
        _edge_rate_limit_count, \
        _edge_consecutive_successes, \
        _edge_max_concurrency

    now = asyncio.get_event_loop().time()
    _edge_rate_limit_count += 1
    _edge_consecutive_successes = 0

    # Exponential backoff: 5s, 10s, 20s, 40s (max 60s)
    backoff = min(5.0 * (2 ** min(_edge_rate_limit_count - 1, 3)), 60.0)
    _edge_rate_limit_until = now + backoff

    # Auto-reduce parallelism on rate limit
    if _edge_rate_limit_count >= 2 and _edge_max_concurrency > 2:
        old_concurrency = _edge_max_concurrency
        _edge_max_concurrency = max(2, _edge_max_concurrency - 1)
        # Update existing limiters
        for loop_id in list(_edge_rate_limiters.keys()):
            _edge_rate_limiters[loop_id] = asyncio.Semaphore(_edge_max_concurrency)
        if log_callback:
            log_callback(
                f"🔻 Rate limit (403), reducing parallelism: {old_concurrency} → {_edge_max_concurrency}"
            )

    # Also reduce chunk size while throttled to keep requests small
    _reduce_chunk_size(log_callback)

    if log_callback:
        log_callback(
            f"⏳ Rate limit detected, waiting {backoff:.1f}s (total: {_edge_rate_limit_count})"
        )

    return backoff


async def _record_success() -> None:
    """Record successful request for adaptive scaling."""
    global \
        _edge_consecutive_successes, \
        _edge_rate_limit_count, \
        _edge_max_concurrency, \
        _edge_concurrency_cap
    global _edge_current_chunk_size, _edge_chunk_failure_count

    _edge_consecutive_successes += 1

    # Scale up after 30 consecutive successes and no recent rate limits
    if _edge_consecutive_successes >= 30 and _edge_rate_limit_count > 0:
        now = asyncio.get_event_loop().time()
        time_since_limit = now - _edge_rate_limit_until + 60  # Add 60s buffer

        if time_since_limit > 120:
            # Scale up parallelism
            if _edge_max_concurrency < _edge_concurrency_cap:
                _edge_max_concurrency = min(_edge_concurrency_cap, _edge_max_concurrency + 1)
                # Update existing limiters
                for loop_id in list(_edge_rate_limiters.keys()):
                    _edge_rate_limiters[loop_id] = asyncio.Semaphore(_edge_max_concurrency)

            # Scale up chunk size
            if _edge_current_chunk_size < _DEFAULT_CHUNK_SIZE:
                _edge_current_chunk_size = min(_DEFAULT_CHUNK_SIZE, _edge_current_chunk_size + 1000)

            # Clear rate limit flag after sustained recovery
            _edge_rate_limit_count = 0

            _edge_consecutive_successes = 0


def _reduce_chunk_size(log_callback: Optional[Callable] = None) -> int:
    """Reduce chunk size on failure. Returns new chunk size."""
    global _edge_current_chunk_size, _edge_chunk_failure_count

    _edge_chunk_failure_count += 1

    # Reduce by 20% on each failure, minimum 3000
    old_size = _edge_current_chunk_size
    reduction = max(1000, int(_edge_current_chunk_size * 0.2))
    _edge_current_chunk_size = max(_SAFE_CHUNK_MIN, _edge_current_chunk_size - reduction)

    if log_callback and old_size != _edge_current_chunk_size:
        log_callback(f"🔻 Reducing chunk size: {old_size} → {_edge_current_chunk_size}")

    return _edge_current_chunk_size


def get_adaptive_chunk_size() -> int:
    """Get current adaptive chunk size."""
    return _edge_current_chunk_size


def get_adaptive_concurrency() -> int:
    """Get current adaptive concurrency."""
    return _edge_max_concurrency


def reset_adaptive_settings() -> None:
    """Reset adaptive settings to defaults (for new conversion)."""
    global _edge_current_chunk_size, _edge_chunk_failure_count
    global _edge_rate_limit_count, _edge_consecutive_successes, _edge_max_concurrency

    _edge_current_chunk_size = _DEFAULT_CHUNK_SIZE
    _edge_chunk_failure_count = 0
    _edge_rate_limit_count = 0
    _edge_consecutive_successes = 0
    _edge_max_concurrency = _DEFAULT_CONCURRENCY

    # Update existing limiters
    for loop_id in list(_edge_rate_limiters.keys()):
        _edge_rate_limiters[loop_id] = asyncio.Semaphore(_edge_max_concurrency)

    # Reset the global tuner
    from ..speed_monitor import reset_edge_tuner

    reset_edge_tuner()


async def _wait_if_rate_limited() -> bool:
    """Wait if currently in rate limit cooldown. Returns True if waited."""
    global _edge_rate_limit_until

    now = asyncio.get_event_loop().time()
    if now < _edge_rate_limit_until:
        wait_time = _edge_rate_limit_until - now
        await asyncio.sleep(wait_time)
        return True
    return False


def get_edge_performance_stats() -> Dict[str, any]:
    """Get current Edge TTS performance statistics for monitoring."""
    try:
        loop_time = asyncio.get_event_loop().time()
        is_limited = loop_time < _edge_rate_limit_until if _edge_rate_limit_until > 0 else False
    except RuntimeError:
        is_limited = False

    return {
        "current_concurrency": _edge_max_concurrency,
        "concurrency_cap": _edge_concurrency_cap,
        "current_chunk_size": _edge_current_chunk_size,
        "chunk_size_default": _DEFAULT_CHUNK_SIZE,
        "chunk_size_range": (_SAFE_CHUNK_MIN, _SAFE_CHUNK_MAX),
        "batch_delay_ms": _edge_batch_delay * 1000,
        "rate_limit_count": _edge_rate_limit_count,
        "chunk_failure_count": _edge_chunk_failure_count,
        "consecutive_successes": _edge_consecutive_successes,
        "is_rate_limited": is_limited,
    }


try:  # pragma: no cover - lazily loaded
    from ..language import LanguageMarkup
    from ..text_formatting import TextFormattingProcessor
except ImportError:  # pragma: no cover - during optional dependency resolution
    LanguageMarkup = None  # type: ignore
    TextFormattingProcessor = None  # type: ignore


class EdgeTTSEngine:
    """Small facade around ``edge_tts`` with predictable behaviour."""

    _noaudio_backoff_until: float = 0.0

    def __init__(
        self,
        voice: str,
        *,
        primary_language: Optional[str] = None,
        language_voices: Optional[Dict[str, str]] = None,
        verbose: bool = False,
        max_segment_seconds: Optional[float] = None,
        chunk_char_limit: Optional[int] = None,
        enable_parallel: bool = True,
        formatting_cues_enabled: bool = True,
        formatting_locale: str = "pt",
        log_callback: Optional[Callable[[str], None]] = None,
    ) -> None:
        global edge_tts

        if isinstance(edge_tts, Mock):
            if getattr(edge_tts, "side_effect", None):
                raise ImportError("Edge-TTS not installed")
            module = edge_tts
        else:
            if edge_tts is None:
                try:
                    edge_tts = importlib.import_module("edge_tts")  # type: ignore
                except ImportError as exc:
                    raise ImportError("Edge-TTS not installed") from exc
            module = edge_tts

        # Per-instance rate limiter (instead of global) for better multi-chapter performance
        # This prevents artificial serialization when processing multiple chapters in parallel
        self._rate_limiter = asyncio.Semaphore(_edge_max_concurrency)
        self._global_rate_limiter: Optional[asyncio.Semaphore] = None
        self._global_rate_limiter_loop: Optional[asyncio.AbstractEventLoop] = None

        self.voice = voice
        self._edge_tts = module
        self.primary_language = (primary_language or "auto").split("-", 1)[0].lower()
        self.language_voices = {
            (key or "").split("-", 1)[0].lower(): value
            for key, value in (language_voices or {}).items()
            if value
        }
        locale_root = (formatting_locale or "pt").split("-", 1)[0].lower()
        if locale_root not in {"pt", "en"}:
            locale_root = "en"
        self.formatting_locale = locale_root
        self.formatting_cues_enabled = bool(formatting_cues_enabled)
        self.last_error: Optional[str] = None
        self.verbose = verbose
        self.log_callback = log_callback
        max_seconds = (
            max_segment_seconds if max_segment_seconds is not None else DEFAULT_EDGE_SEGMENT_SECONDS
        )
        self._max_segment_seconds = max(30.0, min(float(max_seconds), MAX_EDGE_SEGMENT_SECONDS))
        # Use adaptive chunk size if no override provided
        if chunk_char_limit is not None:
            try:
                chunk_limit = int(chunk_char_limit)
            except (TypeError, ValueError):
                chunk_limit = _edge_current_chunk_size
        else:
            chunk_limit = _edge_current_chunk_size  # Use adaptive setting
        self._chunk_char_limit = max(
            _SAFE_CHUNK_MIN, min(chunk_limit, _SAFE_CHUNK_MAX)
        )  # Clamp to safe range
        self._chunk_log_every = max(25, int(self._chunk_char_limit / 400))
        self._words_per_minute = WORDS_PER_MINUTE
        self.partial_failure_detected: bool = False
        self.last_segment_report: Dict[str, int] = {"expected": 0, "generated": 0, "failed": 0}
        self._enable_parallel = enable_parallel
        # Stable view of how many tasks we *intend* to run in parallel regardless of current semaphore value
        self._parallel_slots = _edge_max_concurrency if self._enable_parallel else 1

        # Network-aware auto-tuner for adaptive parameter adjustment
        self._network_tuner = NetworkTuner(
            log_callback=self._log if (verbose or log_callback) else None,
            verbose=verbose,
        )
        # Initialize tuner with current settings
        self._network_tuner.config.chunk_size = self._chunk_char_limit
        self._network_tuner.config.concurrency = self._parallel_slots
        self._network_tuner.config.segment_seconds = self._max_segment_seconds

        # Initialize adaptive tuner for real-time speed monitoring
        self._tuner: Optional[AdaptiveEdgeTuner] = None
        self._auto_tune_enabled = True
        self._segment_timings: List[Tuple[int, float]] = []  # (chars, duration)

        # Initialize synthesis tracker for integrity validation
        self._synthesis_tracker: Optional[SynthesisTracker] = None

        if self.verbose:
            parallel_mode = "enabled" if self._enable_parallel else "disabled"
            max_concurrent = self._parallel_slots if self._enable_parallel else 1
            self._log(f"🔧 EdgeTTS initialized: {voice}")
            self._log(f"   Parallel: {parallel_mode} (max {max_concurrent} concurrent)")
            self._log(
                f"   Limits: {self._max_segment_seconds:.0f}s/segment, {self._chunk_char_limit} chars/chunk"
            )

    def _log(self, message: str) -> None:
        """Log message using callback if available, otherwise print."""
        if self.log_callback:
            self.log_callback(message)
        else:
            print(message)

    def get_synthesis_log(self) -> List[Dict]:
        """Return log of all segments processed during last synthesis."""
        if self._synthesis_tracker is None:
            return []
        return self._synthesis_tracker.get_synthesis_log()

    def get_synthesis_tracker(self) -> Optional[SynthesisTracker]:
        """Return the SynthesisTracker instance used for last synthesis."""
        return self._synthesis_tracker

    def _get_tuner(self) -> AdaptiveEdgeTuner:
        """Get or create the adaptive tuner for this engine."""
        if self._tuner is None:
            self._tuner = get_edge_tuner(
                log_callback=self._log if self.verbose else None,
                aggressive=True,  # Use aggressive mode for faster conversion
            )
        return self._tuner

    def _record_segment_timing(self, chars: int, duration: float, success: bool) -> None:
        """Record segment timing and check for auto-tuning."""
        if not self._auto_tune_enabled or duration <= 0 or chars <= 0:
            return

        self._segment_timings.append((chars, duration))

        # Use tuner to track and potentially adjust settings
        tuner = self._get_tuner()
        new_config = tuner.record_segment(chars, duration, success=success)

        if new_config:
            # Apply new configuration
            self._apply_tuning(new_config)

    def _apply_tuning(self, config: Dict[str, int]) -> None:
        """Apply tuning configuration from the adaptive tuner."""
        global _edge_max_concurrency, _edge_current_chunk_size

        changed = []

        new_chunk = config.get("chunk_size")
        if new_chunk and new_chunk != self._chunk_char_limit:
            old_chunk = self._chunk_char_limit
            self._chunk_char_limit = max(_SAFE_CHUNK_MIN, min(new_chunk, _SAFE_CHUNK_MAX))
            _edge_current_chunk_size = self._chunk_char_limit
            changed.append(f"chunk: {old_chunk} -> {self._chunk_char_limit}")

        new_conc = config.get("concurrency")
        if new_conc and new_conc != _edge_max_concurrency:
            old_conc = _edge_max_concurrency
            _edge_max_concurrency = max(_SAFE_CONCURRENCY_MIN, min(new_conc, _SAFE_CONCURRENCY_MAX))
            self._parallel_slots = _edge_max_concurrency
            # Update rate limiters
            for loop_id in list(_edge_rate_limiters.keys()):
                _edge_rate_limiters[loop_id] = asyncio.Semaphore(_edge_max_concurrency)
            changed.append(f"concurrency: {old_conc} -> {_edge_max_concurrency}")

        new_seg = config.get("max_segment_seconds")
        if new_seg and new_seg != self._max_segment_seconds:
            old_seg = self._max_segment_seconds
            self._max_segment_seconds = max(30.0, min(float(new_seg), MAX_EDGE_SEGMENT_SECONDS))
            changed.append(f"segment: {old_seg:.0f}s -> {self._max_segment_seconds:.0f}s")

        if changed and self.verbose:
            self._log(f"🔧 AUTO-TUNE: {', '.join(changed)}")

    def _apply_network_tuning(self) -> None:
        """Apply settings from network tuner to engine."""
        global _edge_max_concurrency, _edge_current_chunk_size

        config = self._network_tuner.config
        changed = []

        # Apply chunk size
        if config.chunk_size != self._chunk_char_limit:
            old = self._chunk_char_limit
            self._chunk_char_limit = max(
                config.min_chunk_size, min(config.chunk_size, config.max_chunk_size)
            )
            _edge_current_chunk_size = self._chunk_char_limit
            changed.append(f"chunk: {old}→{self._chunk_char_limit}")

        # Apply concurrency
        if config.concurrency != self._parallel_slots:
            old = self._parallel_slots
            self._parallel_slots = max(
                config.min_concurrency, min(config.concurrency, config.max_concurrency)
            )
            _edge_max_concurrency = self._parallel_slots
            # Update rate limiters
            for loop_id in list(_edge_rate_limiters.keys()):
                _edge_rate_limiters[loop_id] = asyncio.Semaphore(_edge_max_concurrency)
            changed.append(f"concurrency: {old}→{self._parallel_slots}")

        # Apply segment duration
        if config.segment_seconds != self._max_segment_seconds:
            old = self._max_segment_seconds
            self._max_segment_seconds = max(
                config.min_segment_seconds, min(config.segment_seconds, config.max_segment_seconds)
            )
            changed.append(f"segment: {old:.0f}s→{self._max_segment_seconds:.0f}s")

        if changed:
            self._log(f"🔧 Network: {', '.join(changed)}")

    def _record_network_result(
        self,
        success: bool,
        latency: float,
        is_rate_limit: bool = False,
        is_timeout: bool = False,
        error_msg: str = "",
    ) -> None:
        """Record result to network tuner and apply adjustments."""
        if success:
            self._network_tuner.record_success(latency)
        else:
            self._network_tuner.record_failure(
                is_rate_limit=is_rate_limit,
                is_timeout=is_timeout,
                error_msg=error_msg,
            )
            # Apply adjusted settings immediately after failure
            self._apply_network_tuning()

    def get_network_status(self) -> str:
        """Get human-readable network status."""
        return self._network_tuner.get_status_message()

    def supports_multilingual(self) -> bool:
        """Edge TTS supports multilingual via voice switching and [[lang:]] tags"""
        return True

    def supports_emphasis(self) -> bool:
        """Edge TTS supports emphasis via SSML when voice is Neural"""
        return self._supports_emphasis()

    def apply_speed_profile(
        self,
        *,
        chunk_char_limit: Optional[int] = None,
        max_segment_seconds: Optional[float] = None,
        words_per_minute: Optional[int] = None,
    ) -> None:
        """Runtime hook used by the converter to nudge chunk sizes/timeouts."""
        updates: list[str] = []
        if chunk_char_limit is not None:
            try:
                limit = int(chunk_char_limit)
            except (TypeError, ValueError):
                limit = self._chunk_char_limit
            limit = max(4000, min(limit, 25_000))
            if limit != self._chunk_char_limit:
                self._chunk_char_limit = limit
                self._chunk_log_every = max(25, int(self._chunk_char_limit / 400))
                updates.append(f"chunk={limit}")

        if max_segment_seconds is not None:
            try:
                seconds = float(max_segment_seconds)
            except (TypeError, ValueError):
                seconds = self._max_segment_seconds
            seconds = max(30.0, min(seconds, 100.0))
            if seconds != self._max_segment_seconds:
                self._max_segment_seconds = seconds
                updates.append(f"segment={seconds:.0f}s")

        if words_per_minute is not None:
            try:
                wpm = int(words_per_minute)
            except (TypeError, ValueError):
                wpm = self._words_per_minute
            wpm = max(120, min(wpm, 260))
            if wpm != self._words_per_minute:
                self._words_per_minute = wpm
                updates.append(f"wpm={wpm}")

        if updates and self.verbose:
            self._log(f"⚡ EdgeTTS speed profile updated: {', '.join(updates)}")

    @property
    def speed_profile(self) -> Dict[str, float]:
        """Expose active chunk/timing limits for telemetry/logging."""
        return {
            "chunk_char_limit": float(self._chunk_char_limit),
            "max_segment_seconds": float(self._max_segment_seconds),
            "words_per_minute": float(self._words_per_minute),
        }

    async def _probe_edge_health(self, voice: str) -> bool:
        """
        Attempt a minimal synthesis to differentiate content error vs service unavailability.
        If even the test text fails, we assume an outage on the Edge backend.
        """
        test_text = "Quick Edge TTS test."
        timeout = 8
        try:
            async with self._rate_limiter:
                communicator = self._edge_tts.Communicate(test_text, voice or self.voice)
                stream_candidate = communicator.stream()
                stream = (
                    await stream_candidate
                    if inspect.isawaitable(stream_candidate)
                    else stream_candidate
                )

                async def _consume_probe():
                    got_audio = False
                    async for chunk in stream:
                        if chunk.get("type") == "audio":
                            got_audio = True
                            break
                    with suppress(Exception):
                        await stream.aclose()
                    return got_audio

                return await asyncio.wait_for(_consume_probe(), timeout=timeout)
        except Exception as exc:
            if self.verbose:
                self._log(f"🔍 [VERBOSE] EdgeTTS health-check failed: {exc}")
            return False

    @staticmethod
    def _sanitize_for_edge(text: str) -> str:
        """
        Remove control/zero-width characters and normalize whitespace.
        Edge often returns NoAudioReceived when it receives invisible control chars or line separators.
        """
        cleaned = re.sub(r"[\u0000-\u001f\u007f-\u009f]", " ", text)
        cleaned = cleaned.replace("\u2028", " ").replace("\u2029", " ").replace("\ufeff", " ")
        cleaned = cleaned.replace("\u00a0", " ")
        cleaned = re.sub(r"[ \t\u200b\u200c\u200d\u2060]+", " ", cleaned)
        cleaned = re.sub(r"\s+\n", "\n", cleaned)
        cleaned = re.sub(r"\n\s+", "\n", cleaned)
        cleaned = cleaned.strip()
        return cleaned

    async def synthesize_async(
        self,
        text: str,
        output_path: Path,
        formatting_segments=None,
        progress_callback=None,
        chunk_callback=None,
        resume_chunks_dir: Optional[Path] = None,
    ) -> Optional[Path]:
        if not text:
            return None

        if self.verbose:
            text_preview = text[:150] + "..." if len(text) > 150 else text
            self._log(f"\n📝 EdgeTTS starting synthesis for {output_path.name}")
            self._log(f"   Size: {len(text)} characters")
            self._log(f"   Preview: {text_preview}")

        self.last_error = None
        self.partial_failure_detected = False
        self.last_segment_report = {"expected": 0, "generated": 0, "failed": 0}

        # **INTEGRITY TRACKING**: Initialize synthesis tracker
        from ..synthesis_tracker import SynthesisTracker

        self._synthesis_tracker = SynthesisTracker(chapter_title=output_path.stem)

        # Use formatting segments if available
        payload_text = text or ""

        if TextFormattingProcessor:
            formatter = TextFormattingProcessor(
                cues_enabled=self.formatting_cues_enabled,
                cue_locale=self.formatting_locale,
            )
            payload_text = formatter.to_audible_text(payload_text, formatting_segments)

        sanitized = self._sanitize_for_edge(payload_text)
        payload_text = sanitized

        if self.verbose and payload_text != text:
            self._log(f"   ⚙️ Text processed (sanitized/formatted): {len(payload_text)} chars")

        force_plain_segments = self._should_force_plain_text(payload_text)
        if force_plain_segments:
            payload_text = self._simplify_segment_text(payload_text, limit_chars=None)

        segments = self._prepare_segments(payload_text)

        if not segments:
            return None

        if self.verbose:
            self._log(f"   📦 Split into {len(segments)} segments")

        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)

        try:
            if output_path.exists():
                output_path.unlink()
        except OSError:
            pass

        total_segments = 0
        failed_segments = 0
        segments_to_process: List[Tuple[str, str]] = [
            (voice, segment_text)
            for voice, segment_text in segments
            if segment_text and segment_text.strip()
        ]
        segment_split_attempts: Dict[str, int] = {}
        micro_split_tracker: Set[str] = set()
        idx = 0
        total_text_chars = None
        if progress_callback:
            total_text_chars = sum(len(text) for _, text in segments_to_process)

        # **RESUME**: Detect pre-existing chunks to resume from
        pre_existing_chunks: Dict[int, Path] = {}
        if resume_chunks_dir and resume_chunks_dir.exists():
            for chunk_file in resume_chunks_dir.glob("chunk_*.mp3"):
                try:
                    # Extract segment index from filename: chunk_0000.mp3 -> 0
                    chunk_idx = int(chunk_file.stem.split("_")[1])
                    # Validate chunk file is not empty/corrupt (min 1KB)
                    if chunk_file.stat().st_size >= 1024:
                        pre_existing_chunks[chunk_idx] = chunk_file
                except (ValueError, IndexError, OSError):
                    pass
            if pre_existing_chunks:
                self._log(
                    f"♻️ [RESUME] Found {len(pre_existing_chunks)}/{len(segments_to_process)} "
                    f"segments already processed, resuming from the rest"
                )

        use_chunk_files = bool(chunk_callback) or bool(resume_chunks_dir)

        def _append_chunk_file(chunk_path: Path, first: bool) -> bool:
            try:
                mode = "wb" if first else "ab"
                with output_path.open(mode) as outfile, chunk_path.open("rb") as infile:
                    while True:
                        block = infile.read(1024 * 1024)
                        if not block:
                            break
                        outfile.write(block)
                return True
            except Exception as exc:
                self.last_error = f"append_failed:{exc}"
                if self.verbose:
                    self._log(f"❌ Failed to append chunk: {exc}")
                return False

        # **PARALLEL OPTIMIZATION**: Process segments in batches when parallel mode is enabled
        if self._enable_parallel and self._rate_limiter and len(segments_to_process) > 1:
            if self.verbose:
                batch_size = self._determine_parallel_batch_size(len(segments_to_process))
                self._log(f"🚀 [VERBOSE] Parallel processing enabled (batch size: {batch_size})")
            return await self._synthesize_parallel(
                output_path,
                segments_to_process,
                force_plain_segments,
                progress_callback=progress_callback,
                chunk_callback=chunk_callback,
                pre_existing_chunks=pre_existing_chunks,
            )

        # **SEQUENTIAL MODE**: Original logic for compatibility
        try:
            while idx < len(segments_to_process):
                voice, segment_text = segments_to_process[idx]
                # Validate segment data
                if voice is None:
                    voice = self.voice or "en-US-GuyNeural"

                if segment_text is None:
                    continue

                segment_text = segment_text.strip("\n\r")
                if not segment_text:
                    continue

                if force_plain_segments or self._should_force_plain_text(segment_text):
                    simplified_segment = self._simplify_segment_text(segment_text, limit_chars=None)
                    if simplified_segment:
                        segment_text = simplified_segment
                        force_plain_segments = True

                if use_chunk_files:
                    existing_chunk = pre_existing_chunks.get(idx)
                    if existing_chunk and existing_chunk.exists():
                        if self.verbose:
                            self._log(f"♻️ [RESUME] Segment {idx + 1} already exists, appending")
                        if not _append_chunk_file(existing_chunk, total_segments == 0):
                            return None
                        if chunk_callback:
                            try:
                                chunk_callback(idx, existing_chunk, segment_text)
                            except TypeError:
                                try:
                                    chunk_callback(idx, existing_chunk)
                                except Exception:
                                    pass
                        if progress_callback:
                            progress_callback(segment_text, total_text_chars or 0)
                        total_segments += 1
                        idx += 1
                        continue

                if self.verbose:
                    text_preview = (
                        segment_text[:200] + "..." if len(segment_text) > 200 else segment_text
                    )
                    self._log(
                        f"\n🎙️ Segment {idx + 1}/{len(segments_to_process)} ({len(segment_text)} chars, voice: {voice})"
                    )
                    self._log(f"   Text: {text_preview}")

                # **CRITICAL FIX**: Try to process segment with retries
                segment_output_path = output_path
                temp_segment_path: Optional[Path] = None
                if use_chunk_files:
                    if resume_chunks_dir:
                        segment_output_path = Path(resume_chunks_dir) / f"chunk_{idx:04d}.mp3"
                    else:
                        import tempfile

                        temp_file = tempfile.NamedTemporaryFile(
                            delete=False, suffix=".mp3", dir=output_path.parent
                        )
                        temp_file.close()
                        temp_segment_path = Path(temp_file.name)
                        segment_output_path = temp_segment_path

                success = await self._synthesize_segment(
                    segment_text,
                    voice,
                    segment_output_path,
                    append=False if use_chunk_files else (total_segments > 0),
                )

                if use_chunk_files and not success:
                    with suppress(OSError):
                        if segment_output_path != output_path:
                            segment_output_path.unlink(missing_ok=True)

                if not success:
                    # If the Edge service is returning *no audio at all*, splitting/cleaning won't help.
                    # Fail fast so the converter can move on instead of spending minutes in retries.
                    if (
                        idx == 0
                        and self.last_error
                        and (
                            "noaudioreceived" in self.last_error.lower()
                            or "service_unavailable" in self.last_error.lower()
                            or "no_audio" == self.last_error.lower()
                        )
                    ):
                        if self.verbose:
                            self._log(f"   ⛔ Abortando: {self.last_error}")
                        return None

                    retry_segments = self._split_failed_segment(
                        voice, segment_text, segment_split_attempts
                    )
                    if retry_segments:
                        if self.verbose:
                            self._log(
                                f"   ⚠️ Failed, splitting into {len(retry_segments)} sub-segments..."
                            )
                        segments_to_process[idx : idx + 1] = retry_segments
                        continue

                    simplified_text = self._simplify_segment_text(segment_text)
                    if simplified_text and simplified_text != segment_text:
                        if self.verbose:
                            self._log("   ⚠️ Retrying with simplified text...")
                        success = await self._synthesize_segment(
                            simplified_text,
                            voice,
                            segment_output_path if use_chunk_files else output_path,
                            append=False if use_chunk_files else (total_segments > 0),
                        )
                        if success:
                            if use_chunk_files:
                                if chunk_callback:
                                    try:
                                        chunk_callback(idx, segment_output_path, simplified_text)
                                    except TypeError:
                                        try:
                                            chunk_callback(idx, segment_output_path)
                                        except Exception:
                                            pass
                                if not _append_chunk_file(segment_output_path, total_segments == 0):
                                    return None
                                if temp_segment_path is not None:
                                    with suppress(OSError):
                                        temp_segment_path.unlink(missing_ok=True)
                            if self.verbose:
                                self._log("   ✅ Success with simplified text")
                            force_plain_segments = True
                            if progress_callback:
                                progress_callback(simplified_text, total_text_chars or 0)
                            total_segments += 1
                            idx += 1
                            continue
                        if use_chunk_files and not success:
                            with suppress(OSError):
                                if segment_output_path != output_path:
                                    segment_output_path.unlink(missing_ok=True)

                    failed_segments += 1
                    if self.verbose:
                        self._log(f"   ❌ FAILED: {self.last_error}")

                    # Retry with shorter exponential backoff (1s, 2s)
                    if failed_segments <= 2:
                        backoff = min(1.0 * (2 ** (failed_segments - 1)), 3.0)
                        if self.verbose:
                            self._log(f"   🔄 Retrying after {backoff}s...")
                        await asyncio.sleep(backoff)

                        success = await self._synthesize_segment(
                            segment_text,
                            voice,
                            segment_output_path if use_chunk_files else output_path,
                            append=False if use_chunk_files else (total_segments > 0),
                        )

                        if use_chunk_files and not success:
                            with suppress(OSError):
                                if segment_output_path != output_path:
                                    segment_output_path.unlink(missing_ok=True)

                        if success:
                            if self.verbose:
                                self._log("   ✅ Success on retry")
                            failed_segments = max(0, failed_segments - 1)

                    # Fail if more than 2 consecutive segments failed
                    if failed_segments > 2:
                        last_error_text = (self.last_error or "").lower()
                        is_network_like = any(
                            token in last_error_text
                            for token in (
                                "ssl",
                                "clientconnector",
                                "connection",
                                "dns",
                                "timeout",
                                "network",
                            )
                        )
                        if is_network_like:
                            self._log(
                                f"❌ Edge TTS: consecutive network/SSL failures ({failed_segments}), aborting"
                            )
                            raise RuntimeError("edge_network_abort")
                        micro_segments = self._force_micro_segments(
                            voice, segment_text, micro_split_tracker
                        )
                        if micro_segments:
                            if self.verbose:
                                self._log(
                                    f"   ⚡ Forcing split into {len(micro_segments)} micro-segments"
                                )
                            segments_to_process[idx : idx + 1] = micro_segments
                            force_plain_segments = True
                            failed_segments = 0
                            continue
                        self._log(
                            f"❌ Edge TTS: too many consecutive failures ({failed_segments}), aborting"
                        )
                        return None

                    idx += 1
                    continue

                if use_chunk_files:
                    if chunk_callback:
                        try:
                            chunk_callback(idx, segment_output_path, segment_text)
                        except TypeError:
                            try:
                                chunk_callback(idx, segment_output_path)
                            except Exception:
                                pass
                    if not _append_chunk_file(segment_output_path, total_segments == 0):
                        return None
                    if temp_segment_path is not None:
                        with suppress(OSError):
                            temp_segment_path.unlink(missing_ok=True)

                # Success!
                total_segments += 1
                if progress_callback:
                    progress_callback(segment_text, total_text_chars or 0)
                idx += 1
        except asyncio.TimeoutError:
            self.last_error = "timeout"
            return None
        except Exception as exc:  # pragma: no cover - defensive logging
            self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
            return None

        if total_segments == 0 or not output_path.exists():
            self.last_error = "no_audio"
            return None

        expected_segments = total_segments + failed_segments
        self.last_segment_report = {
            "expected": expected_segments,
            "generated": total_segments,
            "failed": failed_segments,
        }

        # **FIXED**: Accept audio only if at least 95% of segments were generated successfully
        success_rate = total_segments / max(expected_segments, 1)

        if success_rate < 0.95:
            # Less than 95% of segments -> critical failure
            self.partial_failure_detected = True

            # Adaptive: reduce chunk size for next attempt
            new_chunk = _reduce_chunk_size(self._log if self.verbose else None)
            self._chunk_char_limit = new_chunk

            if failed_segments > 0:
                self._log(f"⚠️ Edge TTS: {failed_segments} segment(s) falharam durante a síntese")
                self._log(
                    f"   Processados: {total_segments}/{expected_segments} segmentos ({success_rate * 100:.0f}%)"
                )
                if self.verbose:
                    self._log("   Use --verbose para mais detalhes sobre os segmentos com falha")
            else:
                self._log(
                    f"⚠️ Edge TTS: somente {total_segments}/{expected_segments} segmentos foram gerados (saída incompleta)"
                )
            self.last_error = f"incomplete_segments:{total_segments}/{expected_segments}"
            with suppress(OSError):
                output_path.unlink(missing_ok=True)
            return None
        elif failed_segments > 0 and success_rate < 1.0:
            # Entre 95-100% dos segmentos -> avisar mas aceitar o áudio
            self._log(
                f"⚠️ Edge TTS: {failed_segments} segment(s) falharam, mas {success_rate * 100:.1f}% foi gerado com sucesso"
            )
            if self.verbose:
                self._log(f"   Processados: {total_segments}/{expected_segments} segmentos")

        return output_path

    async def _synthesize_parallel(
        self,
        output_path: Path,
        segments_to_process: List[Tuple[str, str]],
        force_plain_segments: bool,
        progress_callback=None,
        chunk_callback=None,
        pre_existing_chunks: Optional[Dict[int, Path]] = None,
    ) -> Optional[Path]:
        """Process segments in parallel batches for faster synthesis."""
        import tempfile
        from pathlib import Path

        total_segments = len(segments_to_process)
        batch_size = self._determine_parallel_batch_size(total_segments)
        successful_segments = 0
        # Use dict to maintain segment order
        segment_files: Dict[int, Optional[Path]] = {i: None for i in range(total_segments)}

        # **RESUME**: Pre-populate with existing chunks
        if pre_existing_chunks:
            for idx, existing_path in pre_existing_chunks.items():
                if 0 <= idx < total_segments and existing_path.exists():
                    segment_files[idx] = existing_path
                    successful_segments += 1

        # **OPTIMIZED**: Process in fixed batches to avoid semaphore queue explosion
        # asyncio.gather respects rate limiter naturally without creating excessive queue
        completed_count = 0

        if self.verbose:
            resumed_count = len(pre_existing_chunks) if pre_existing_chunks else 0
            remaining = total_segments - resumed_count
            if resumed_count > 0:
                self._log(
                    f"🚀 [PARALLEL] Processando {remaining} segmentos restantes "
                    f"(♻️ {resumed_count} já prontos) em batches de {batch_size}"
                )
            else:
                self._log(
                    f"🚀 [PARALLEL] Processando {total_segments} segmentos em batches de {batch_size}"
                )

        # Process segments in fixed batches
        for batch_idx, batch_start in enumerate(range(0, total_segments, batch_size)):
            # Inter-batch delay to avoid rate limits (configurable via EDGE_BATCH_DELAY_MS)
            if batch_idx > 0 and _edge_batch_delay > 0:
                await asyncio.sleep(_edge_batch_delay)

            batch_end = min(batch_start + batch_size, total_segments)
            batch_segments = segments_to_process[batch_start:batch_end]

            tasks = []
            task_metadata = []  # (segment_idx, temp_path)

            for i, (voice, segment_text) in enumerate(batch_segments, start=batch_start):
                # **RESUME**: Skip segments that already have files
                if segment_files.get(i) is not None:
                    completed_count += 1
                    if self.verbose:
                        self._log(f"♻️ [RESUME] Segment {i + 1} already exists, skipping")
                    # **INTEGRITY TRACKING**: Mark resumed segment as success
                    if self._synthesis_tracker:
                        try:
                            from ..audio_validator import AudioValidator

                            validator = AudioValidator()
                            duration = validator.get_audio_duration(segment_files[i])
                            _, seg_text = segments_to_process[i]
                            self._synthesis_tracker.record_segment(
                                index=i,
                                text=seg_text,
                                audio_path=segment_files[i],
                                duration=duration,
                                status="success",
                            )
                        except Exception:
                            pass  # Non-critical
                    continue

                # Validate and prepare segment
                if voice is None:
                    voice = self.voice or "en-US-GuyNeural"

                segment_text = segment_text.strip("\n\r") if segment_text else ""
                if not segment_text:
                    continue

                if force_plain_segments or self._should_force_plain_text(segment_text):
                    simplified = self._simplify_segment_text(segment_text, limit_chars=None)
                    if simplified:
                        segment_text = simplified

                # **INTEGRITY TRACKING**: Record segment as pending before synthesis
                if self._synthesis_tracker:
                    try:
                        self._synthesis_tracker.record_segment(
                            index=i, text=segment_text, status="pending"
                        )
                    except Exception:
                        pass  # Non-critical

                # Create temp file
                temp_file = tempfile.NamedTemporaryFile(
                    delete=False, suffix=".mp3", dir=output_path.parent
                )
                temp_file.close()
                temp_path = Path(temp_file.name)

                # Add synthesis task
                task = self._synthesize_segment(segment_text, voice, temp_path, append=False)
                tasks.append(task)
                task_metadata.append((i, temp_path))

            # Process batch - gather respects rate limiter without queueing
            results = await asyncio.gather(*tasks, return_exceptions=True)

            # Process results
            for (segment_idx, temp_file), result in zip(task_metadata, results):
                segment_num = segment_idx + 1
                completed_count += 1

                try:
                    if isinstance(result, Exception):
                        raise result

                    if result:  # Success
                        successful_segments += 1
                        segment_files[segment_idx] = temp_file

                        # **INTEGRITY TRACKING**: Record successful segment
                        if self._synthesis_tracker:
                            try:
                                from ..audio_validator import AudioValidator

                                validator = AudioValidator()
                                duration = validator.get_audio_duration(temp_file)
                                _, seg_text = segments_to_process[segment_idx]
                                self._synthesis_tracker.record_segment(
                                    index=segment_idx,
                                    text=seg_text,
                                    audio_path=temp_file,
                                    duration=duration,
                                    status="success",
                                )
                            except Exception:
                                pass  # Non-critical

                        if chunk_callback:
                            try:
                                # Pass segment text to callback for storage
                                _, seg_text = segments_to_process[segment_idx]
                                chunk_callback(segment_idx, temp_file, seg_text)
                            except TypeError:
                                # Fallback for callbacks that don't accept text
                                try:
                                    chunk_callback(segment_idx, temp_file)
                                except Exception as e:
                                    if self.verbose:
                                        self._log(f"⚠️ Chunk callback error: {e}")
                            except Exception as e:
                                if self.verbose:
                                    self._log(f"⚠️ Chunk callback error: {e}")

                        # **NOVO**: Report progress to callback
                        if progress_callback:
                            try:
                                if segment_idx < len(segments_to_process):
                                    _, segment_text = segments_to_process[segment_idx]
                                    total_text_chars = sum(
                                        len(text) for _, text in segments_to_process
                                    )
                                    progress_callback(segment_text, total_text_chars)
                            except Exception as e:
                                if self.verbose:
                                    self._log(f"⚠️ Progress callback error: {e}")

                        if self.verbose:
                            file_size = temp_file.stat().st_size if temp_file.exists() else 0
                            self._log(
                                f"✅ [PARALLEL] Segment {segment_num} OK ({file_size} bytes, {completed_count}/{total_segments})"
                            )
                    else:
                        # **INTEGRITY TRACKING**: Record failed segment
                        if self._synthesis_tracker:
                            try:
                                _, seg_text = segments_to_process[segment_idx]
                                self._synthesis_tracker.record_segment(
                                    index=segment_idx,
                                    text=seg_text,
                                    status="failed",
                                    error="No audio generated",
                                )
                            except Exception:
                                pass  # Non-critical

                        if self.verbose:
                            self._log(f"⚠️ [PARALLEL] Segment {segment_num} failed (no audio)")
                        with suppress(OSError):
                            temp_file.unlink()

                except Exception as exc:
                    # **INTEGRITY TRACKING**: Record exception
                    if self._synthesis_tracker:
                        try:
                            _, seg_text = segments_to_process[segment_idx]
                            error_msg = str(exc)[:200]
                            self._synthesis_tracker.record_segment(
                                index=segment_idx, text=seg_text, status="failed", error=error_msg
                            )
                        except Exception:
                            pass  # Non-critical

                    if self.verbose:
                        error_msg = str(exc)[:100]
                        self._log(f"⚠️ [PARALLEL] Segment {segment_num} failed: {error_msg}")
                    with suppress(OSError):
                        temp_file.unlink()

        # Retry failed segments sequentially (anti-starving measure)
        failed_indices = [i for i, path in segment_files.items() if path is None]
        if failed_indices and successful_segments >= total_segments * 0.8:
            if self.verbose:
                self._log(
                    f"🔄 [PARALLEL] Tentando {len(failed_indices)} segmentos falhados sequencialmente..."
                )

            for fail_idx in failed_indices:
                voice, segment_text = segments_to_process[fail_idx]
                if not segment_text or not segment_text.strip():
                    continue

                if force_plain_segments or self._should_force_plain_text(segment_text):
                    simplified = self._simplify_segment_text(segment_text, limit_chars=None)
                    if simplified:
                        segment_text = simplified

                temp_file = tempfile.NamedTemporaryFile(
                    delete=False, suffix=".mp3", dir=output_path.parent
                )
                temp_file.close()
                retry_path = Path(temp_file.name)

                try:
                    success = await self._synthesize_segment(
                        segment_text,
                        voice or self.voice,
                        retry_path,
                        append=False,
                    )

                    if success and retry_path.exists():
                        successful_segments += 1
                        segment_files[fail_idx] = retry_path

                        # **INTEGRITY TRACKING**: Update retried segment as success
                        if self._synthesis_tracker:
                            try:
                                from ..audio_validator import AudioValidator

                                validator = AudioValidator()
                                duration = validator.get_audio_duration(retry_path)
                                self._synthesis_tracker.record_segment(
                                    index=fail_idx,
                                    text=segment_text,
                                    audio_path=retry_path,
                                    duration=duration,
                                    status="success",
                                )
                            except Exception:
                                pass  # Non-critical

                        if chunk_callback:
                            try:
                                chunk_callback(fail_idx, retry_path, segment_text)
                            except TypeError:
                                try:
                                    chunk_callback(fail_idx, retry_path)
                                except Exception as e:
                                    if self.verbose:
                                        self._log(f"⚠️ Chunk callback error (retry): {e}")
                            except Exception as e:
                                if self.verbose:
                                    self._log(f"⚠️ Chunk callback error (retry): {e}")
                        if self.verbose:
                            self._log(f"✅ [PARALLEL] Segment {fail_idx + 1} recovered in retry")
                    else:
                        # **INTEGRITY TRACKING**: Keep failed status (already recorded earlier)
                        with suppress(OSError):
                            retry_path.unlink()
                except Exception as exc:
                    # **INTEGRITY TRACKING**: Update with retry error
                    if self._synthesis_tracker:
                        try:
                            error_msg = f"Retry failed: {str(exc)[:150]}"
                            self._synthesis_tracker.record_segment(
                                index=fail_idx, text=segment_text, status="failed", error=error_msg
                            )
                        except Exception:
                            pass  # Non-critical

                    if self.verbose:
                        self._log(f"⚠️ [PARALLEL] Retry segmento {fail_idx + 1} falhou: {exc}")
                    with suppress(OSError):
                        retry_path.unlink()

        # Collect successful segments in order
        temp_files = [path for path in segment_files.values() if path is not None]

        if not temp_files:
            self.last_error = "no_audio_generated_parallel"
            return None

        if self.verbose:
            self._log(f"🔗 [PARALLEL] Concatenando {len(temp_files)} segmentos bem-sucedidos...")

        try:
            # **OPTIMIZED**: Buffered chunked I/O to reduce memory pressure
            CHUNK_SIZE = 1024 * 1024  # 1MB chunks
            with output_path.open("wb") as outfile:
                for temp_file in temp_files:
                    if temp_file.exists():
                        with temp_file.open("rb") as infile:
                            while True:
                                chunk = infile.read(CHUNK_SIZE)
                                if not chunk:
                                    break
                                outfile.write(chunk)
                        # Clean up temp file
                        with suppress(OSError):
                            temp_file.unlink()
        except Exception as exc:
            self.last_error = f"concatenation_failed: {exc}"
            if self.verbose:
                self._log(f"❌ [PARALLEL] Erro ao concatenar: {exc}")
            # Clean up remaining temp files
            for temp_file in temp_files:
                with suppress(OSError):
                    temp_file.unlink()
            return None

        # Update statistics
        self.last_segment_report = {
            "expected": total_segments,
            "generated": successful_segments,
            "failed": total_segments - successful_segments,
        }

        success_rate = successful_segments / total_segments
        if success_rate < 0.95:
            self.partial_failure_detected = True

            # Adaptive: reduce chunk size for next attempt
            new_chunk = _reduce_chunk_size(self._log if self.verbose else None)
            self._chunk_char_limit = new_chunk

            self._log(
                f"⚠️ Edge TTS Paralelo: apenas {successful_segments}/{total_segments} segmentos ({success_rate * 100:.1f}%)"
            )
            self.last_error = f"incomplete_segments:{successful_segments}/{total_segments}"
            with suppress(OSError):
                output_path.unlink()
            return None

        if self.verbose:
            self._log(
                f"✅ [PARALLEL] Síntese completa: {successful_segments}/{total_segments} segmentos ({success_rate * 100:.1f}%)"
            )

        return output_path

    def _calculate_timeout(self, text: str) -> int:
        """Estimate a safe upper bound for synthesis time in seconds.

        Otimizado: timeout mais agressivo para falhar rápido em caso de problemas.
        """
        if not text:
            return 60  # 60s padrão para texto vazio

        estimated = max(self._estimate_duration(text), 5.0)

        # Timeout = duração estimada + 40% de buffer + 20s fixos
        # Mais agressivo para evitar esperas longas
        timeout = estimated * 1.4 + 20.0

        # Limites: mínimo 45s, máximo dinâmico para evitar cortes de segmentos longos
        timeout = max(timeout, 45.0)
        timeout_cap = max(300.0, self._max_segment_seconds * 1.5 + 60.0)
        timeout = min(timeout, timeout_cap)

        return int(round(timeout))

    def _prepare_segments(self, text: str) -> list[tuple[str, str]]:
        if text is None:
            return [(self.voice, "")]

        # Preserve markup for language detection; clean after parsing
        cleaned_text = text or ""

        if LanguageMarkup is None:
            base_text = (
                TextFormattingProcessor.clean_tts_text(cleaned_text)
                if TextFormattingProcessor
                else cleaned_text
            )
            return self._chunk_text(self.voice, base_text)

        try:
            lowered = cleaned_text.lower()
            if "[[lang:" not in lowered:
                base_text = (
                    TextFormattingProcessor.clean_tts_text(cleaned_text)
                    if TextFormattingProcessor
                    else cleaned_text
                )
                return self._chunk_text(self.voice, base_text)

            segments = LanguageMarkup.parse(cleaned_text, self.primary_language)
            if segments is None:
                base_text = (
                    TextFormattingProcessor.clean_tts_text(cleaned_text)
                    if TextFormattingProcessor
                    else cleaned_text
                )
                return self._chunk_text(self.voice, base_text)

            if len(segments) > 100:
                simplified = LanguageMarkup.strip(cleaned_text) if LanguageMarkup else cleaned_text
                base_text = (
                    TextFormattingProcessor.clean_tts_text(simplified)
                    if TextFormattingProcessor
                    else simplified
                )
                return self._chunk_text(self.voice, base_text)

            prepared: list[tuple[str, str]] = []
            for segment in segments:
                if segment is None:
                    continue
                segment_text = getattr(segment, "text", "") or ""
                segment_text = segment_text.strip()
                if not segment_text:
                    continue
                lang = (segment.language or "").split("-", 1)[0].lower()
                voice = self.language_voices.get(lang) or self.voice
                segment_clean = (
                    TextFormattingProcessor.clean_tts_text(segment_text)
                    if TextFormattingProcessor
                    else segment_text
                )
                prepared.extend(self._chunk_text(voice, segment_clean))

            if not prepared:
                return self._chunk_text(self.voice, cleaned_text)

            return prepared

        except Exception:
            fallback = (
                TextFormattingProcessor.clean_tts_text(text or "")
                if TextFormattingProcessor
                else (text or "")
            )
            return self._chunk_text(self.voice, fallback)

    def _apply_chunk_prosody(self, text: str, rate_increase: str = "+50%") -> str:
        """
        Aplica tags SSML prosody a um chunk individual para compensar pausas do Edge-TTS.

        NOTA: Função desabilitada - Edge-TTS ignora tags SSML prosody.
        Mantida para compatibilidade futura se o Edge-TTS passar a suportar.

        Args:
            text: Texto do chunk
            rate_increase: Aumento percentual na taxa de fala (não utilizado)

        Returns:
            Texto original sem modificações
        """
        # DISABLED: Edge-TTS não respeita tags SSML prosody
        # Testes mostraram que as tags não reduzem a duração do áudio
        # Retorna texto sem modificações
        return text

    def _chunk_text(
        self, voice: str, text: str, chunk_size: Optional[int] = None
    ) -> list[tuple[str, str]]:
        """Divide texto longo em blocos menores respeitando limites aproximados de frase e duração."""
        if not text:
            return []

        stripped = text.strip()
        if not stripped:
            return []

        # If converter injected a precomputed plan, reuse it
        pre_segments = getattr(self, "_precomputed_segments", None)
        if pre_segments and isinstance(pre_segments, list):
            cleaned_segments: List[str] = []
            try:
                current_len = len(stripped)
            except Exception:
                current_len = 0
            for seg in pre_segments:
                if not isinstance(seg, str):
                    continue
                seg_text = seg.strip()
                if not seg_text:
                    continue
                cleaned_segments.append(self._sanitize_for_edge(seg_text))
            if cleaned_segments:
                total_len = sum(len(seg) for seg in cleaned_segments)
                # Guard against stale plans that don't match the current payload size.
                if current_len and total_len:
                    ratio = total_len / max(current_len, 1)
                    if ratio < 0.75 or ratio > 1.25:
                        cleaned_segments = []
                if cleaned_segments:
                    refined: List[tuple[str, str]] = []
                    for seg_text in cleaned_segments:
                        refined.extend(self._split_if_needed(voice, seg_text))

                    # Apply prosody to precomputed segments
                    prosody_refined: List[tuple[str, str]] = []
                    for seg_voice, seg_text in refined:
                        wrapped_text = self._apply_chunk_prosody(seg_text)
                        prosody_refined.append((seg_voice, wrapped_text))

                    return prosody_refined

        try:
            active_chunk_limit = (
                int(chunk_size) if chunk_size is not None else self._chunk_char_limit
            )
        except (TypeError, ValueError):
            active_chunk_limit = self._chunk_char_limit
        active_chunk_limit = max(_SAFE_CHUNK_MIN, active_chunk_limit)

        # Guardrail: shrink chunk size after rate limits or for very long payloads
        safe_limit_env = os.getenv("EDGE_SAFE_SEGMENT_CHARS")
        safe_limit = None
        if safe_limit_env:
            try:
                safe_limit = int(safe_limit_env)
            except ValueError:
                safe_limit = None
        if safe_limit is None:
            safe_limit = 3600
        safe_limit = max(_SAFE_CHUNK_MIN, min(safe_limit, _SAFE_CHUNK_MAX))

        if _edge_rate_limit_count > 0:
            adjusted = min(active_chunk_limit, safe_limit)
            if adjusted != active_chunk_limit and self.verbose:
                self._log(
                    f"🔍 Edge: chunk reduzido para {adjusted} chars (rate limit / capítulo longo)"
                )
            active_chunk_limit = adjusted

        if len(stripped) <= active_chunk_limit:
            base_chunks: List[tuple[str, str]] = [(voice, stripped)]
        else:
            base_chunks = []
            start = 0
            length = len(stripped)

            while start < length:
                end = min(start + active_chunk_limit, length)
                chunk = stripped[start:end]

                if end < length:
                    last_period = chunk.rfind(".")
                    last_exclamation = chunk.rfind("!")
                    last_question = chunk.rfind("?")
                    break_point = max(last_period, last_exclamation, last_question)
                    if break_point > active_chunk_limit * 0.5:
                        chunk = chunk[: break_point + 1]
                        end = start + len(chunk)

                if chunk:
                    base_chunks.append((voice, chunk))
                start = end

        refined: List[tuple[str, str]] = []
        for chunk_voice, chunk_text in base_chunks:
            refined.extend(self._split_if_needed(chunk_voice, chunk_text))

        # Apply prosody rate to each chunk to compensate for Edge-TTS pauses
        # This is done per-chunk because Edge-TTS processes each chunk independently
        prosody_refined: List[tuple[str, str]] = []
        for chunk_voice, chunk_text in refined:
            # Wrap chunk in prosody tags if it has high sentence density
            wrapped_text = self._apply_chunk_prosody(chunk_text)
            prosody_refined.append((chunk_voice, wrapped_text))

        return prosody_refined

    def _split_if_needed(self, voice: str, text: str) -> List[tuple[str, str]]:
        """Ensure each chunk respects the estimated duration limit."""
        if not text:
            return []

        duration = self._estimate_duration(text)
        if duration <= self._max_segment_seconds:
            return [(voice, text)]

        segments = self._split_text_by_duration(text, self._max_segment_seconds)
        return [(voice, segment) for segment in segments if segment]

    def _split_text_by_duration(self, text: str, max_seconds: float) -> List[str]:
        """Split text using sentence boundaries and estimated duration."""
        sentences = _SENTENCE_SPLIT_RE.split(text)
        segments: List[str] = []
        buffer: List[str] = []

        for sentence in sentences:
            trimmed = sentence.strip()
            if not trimmed:
                continue

            candidate = f"{' '.join(buffer)} {trimmed}".strip() if buffer else trimmed
            if buffer and self._estimate_duration(candidate) > max_seconds:
                segments.append(" ".join(buffer).strip())
                buffer = [trimmed]
            else:
                buffer.append(trimmed)

        if buffer:
            segments.append(" ".join(buffer).strip())

        refined: List[str] = []
        for segment in segments:
            if not segment:
                continue
            if self._estimate_duration(segment) <= max_seconds or len(segment.split()) <= 1:
                refined.append(segment)
            else:
                refined.extend(self._split_by_words(segment, max_seconds))

        return [segment for segment in refined if segment]

    def _split_by_words(self, text: str, max_seconds: float) -> List[str]:
        """Fallback splitter when a single sentence still exceeds the duration limit."""
        words = [word for word in text.split() if word]
        if not words:
            return []

        max_words = max(int((max_seconds / 60.0) * self._words_per_minute), MIN_WORDS_PER_SEGMENT)
        segments: List[str] = []

        for start in range(0, len(words), max_words):
            segment_words = words[start : start + max_words]
            segment_text = " ".join(segment_words).strip()
            if segment_text:
                segments.append(segment_text)

        return segments

    def _segment_signature(self, voice: str, text: str) -> str:
        preview = (text or "").strip()
        return f"{voice}:{len(preview)}:{hash(preview[:160])}"

    def _split_failed_segment(
        self,
        voice: str,
        text: str,
        attempts: Dict[str, int],
    ) -> List[Tuple[str, str]] | None:
        """Try to split a problematic segment into smaller pieces for retry."""
        if not text or len(text) < MIN_SEGMENT_RETRY_CHARS:
            return None

        signature = self._segment_signature(voice, text)
        attempt = attempts.get(signature, 0)
        if attempt >= MAX_SEGMENT_SPLIT_ATTEMPTS:
            return None

        divisor = 2 + attempt
        chunk_size = max(int(len(text) / divisor), MIN_SEGMENT_RETRY_CHARS // 2)
        smaller_segments = self._chunk_text(voice, text, chunk_size=chunk_size)
        smaller_segments = [
            (seg_voice, seg_text)
            for seg_voice, seg_text in smaller_segments
            if seg_text and seg_text.strip()
        ]

        if len(smaller_segments) <= 1:
            return None

        attempts[signature] = attempt + 1
        return smaller_segments

    def _force_micro_segments(
        self,
        voice: str,
        text: str,
        tracker: Set[str],
    ) -> List[Tuple[str, str]] | None:
        """Force text into very small segments to salvage stubborn payloads."""
        if not text:
            return None

        signature = f"micro:{self._segment_signature(voice, text)}"
        if signature in tracker:
            return None

        tracker.add(signature)

        cleaned = text.strip()
        if not cleaned:
            return None

        max_seconds = min(self._max_segment_seconds * 0.5, 20.0)
        micro_chunks = self._split_text_by_duration(cleaned, max_seconds)

        if not micro_chunks:
            # Fall back to fixed-size word groups (~80 words ≈ 30s)
            words = [word for word in cleaned.split() if word]
            if not words:
                return None

            chunk_words = max(min(len(words) // 4, 80), 20)
            micro_chunks = []
            for start in range(0, len(words), chunk_words):
                segment_words = words[start : start + chunk_words]
                if segment_words:
                    micro_chunks.append(" ".join(segment_words))

        micro_chunks = [chunk.strip() for chunk in micro_chunks if chunk and chunk.strip()]
        if not micro_chunks:
            return None

        return [(voice, chunk) for chunk in micro_chunks]

    def _simplify_segment_text(
        self, text: str, *, limit_chars: Optional[int] = SIMPLIFIED_SEGMENT_MAX_CHARS
    ) -> str:
        """Remove formatting markers and limit length to create a safer payload."""
        if not text:
            return ""

        simplified = text
        if LanguageMarkup:
            try:
                simplified = LanguageMarkup.strip(simplified)
            except Exception:
                pass

        if TextFormattingProcessor:
            try:
                simplified = TextFormattingProcessor.strip_inline_markdown(simplified)
            except Exception:
                pass

        simplified = re.sub(r"<[^>]+>", " ", simplified)
        simplified = re.sub(r"\[\[[^\]]+\]\]", " ", simplified)
        simplified = re.sub(r"\s+", " ", simplified)
        simplified = simplified.strip()

        if limit_chars and len(simplified) > limit_chars:
            simplified = simplified[:limit_chars]

        return simplified

    def _should_force_plain_text(self, text: str) -> bool:
        """Heuristic: detect heavy markup that often breaks Edge SSML."""
        if not text:
            return False
        stripped = text.strip()
        if len(stripped) < 400:
            return False

        fmt_markers = stripped.count("[[fmt:")
        lang_markers = stripped.lower().count("[[lang:")
        bold_markers = stripped.count("**")
        italic_markers = stripped.count("_")

        high_markup = fmt_markers + lang_markers >= 20
        dense_markup = (fmt_markers + lang_markers) >= 8 and len(stripped) / max(
            fmt_markers + lang_markers, 1
        ) < 200
        heavy_markdown = bold_markers >= 10 or italic_markers >= 30
        very_long = len(stripped) > 12000 and (fmt_markers + lang_markers) >= 5

        return high_markup or dense_markup or heavy_markdown or very_long

    def _estimate_duration(self, text: str) -> float:
        """Estimate spoken duration in seconds for the provided text."""
        try:
            estimated = TextValidator.estimate_duration(
                text, words_per_minute=self._words_per_minute
            )
            return float(estimated or 0.0)
        except Exception:
            words = [word for word in (text or "").split() if word]
            if not words:
                return 0.0
            return (len(words) / max(self._words_per_minute, 1)) * 60.0

    def _supports_emphasis(self) -> bool:
        voice = (self.voice or "").lower()
        return "neural" in voice or voice.startswith("pt-br")

    def _resolve_parallel_capacity(self) -> int:
        """Return desired parallelism while clamping to a safe minimum."""
        slots = self._parallel_slots if self._enable_parallel else 1
        if slots <= 0:
            slots = 1
        slots = min(slots, max(1, _edge_max_concurrency))
        return max(1, slots)

    def _determine_parallel_batch_size(self, total_segments: int) -> int:
        """Decide how many segments to launch per batch without hitting zero-step ranges."""
        capacity = self._resolve_parallel_capacity()
        total = max(1, total_segments)
        return max(1, min(capacity, total))

    async def _synthesize_segment(
        self,
        text: str,
        voice: str,
        output_path: Path,
        *,
        append: bool,
    ) -> bool:
        # Validate inputs
        if text is None:
            self.last_error = "text_is_none"
            return False

        if voice is None:
            voice = self.voice or "en-US-GuyNeural"

        # **RATE LIMIT CHECK**: Wait if we recently hit a 403
        waited = await _wait_if_rate_limited()
        if waited and self.verbose:
            self._log("   ⏸️ Aguardou cooldown de rate limit")

        log_callback = self._log if (self.verbose or self.log_callback) else None

        # Use per-instance + global rate limiter to prevent resource contention
        loop = asyncio.get_running_loop()
        waiting_start = loop.time()
        if self._global_rate_limiter_loop is not loop:
            self._global_rate_limiter = _get_global_edge_limiter(loop)
            self._global_rate_limiter_loop = loop
        global_limiter = self._global_rate_limiter
        slots_available = self._rate_limiter._value
        global_slots_available = (
            global_limiter._value
            if global_limiter and global_limiter is not self._rate_limiter
            else None
        )

        if slots_available == 0 or (global_slots_available == 0):
            waiters = getattr(self._rate_limiter, "_waiters", [])
            if global_slots_available == 0 and global_limiter is not None:
                waiters = getattr(global_limiter, "_waiters", waiters)
            waiters_count = len(waiters) if waiters is not None else 0
            if self.verbose:
                self._log(f"   ⏳ Aguardando slot livre (fila: {waiters_count})")

        async with AsyncExitStack() as stack:
            if global_limiter and global_limiter is not self._rate_limiter:
                await stack.enter_async_context(global_limiter)
            await stack.enter_async_context(self._rate_limiter)
            wait_time = loop.time() - waiting_start
            if self.verbose and wait_time > 1:
                self._log(f"   🚀 Slot obtido após {wait_time:.1f}s")

            now = loop.time()
            if now < self._noaudio_backoff_until:
                remaining = int(self._noaudio_backoff_until - now)
                self.last_error = f"service_unavailable (cooldown {remaining}s)"
                if self.verbose:
                    self._log(f"   ⏸️ Cooldown: {remaining}s restantes")
                return False
            try:
                # SSL bypass já aplicado no topo do módulo via monkeypatch
                communicator = self._edge_tts.Communicate(text, voice)

            except Exception as exc:  # pragma: no cover - defensive logging
                if _is_rate_limit_error(exc):
                    self.last_error = f"rate_limit: {exc}" if exc else "rate_limit"
                    await _handle_rate_limit(log_callback)
                else:
                    self.last_error = (
                        f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                    )
                if self.verbose:
                    self._log(f"   ❌ Erro ao criar Communicate: {self.last_error}")
                return False

            mode = "ab" if append else "wb"
            received_audio = False
            timeout = self._calculate_timeout(text)

            try:
                stream_candidate = communicator.stream()
            except Exception as exc:  # pragma: no cover - defensive logging
                if _is_rate_limit_error(exc):
                    self.last_error = f"rate_limit: {exc}" if exc else "rate_limit"
                    await _handle_rate_limit(log_callback)
                else:
                    self.last_error = (
                        f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                    )
                if self.verbose:
                    self._log(f"   ❌ Erro ao obter stream: {self.last_error}")
                return False

            try:
                stream = (
                    await stream_candidate
                    if inspect.isawaitable(stream_candidate)
                    else stream_candidate
                )
            except asyncio.TimeoutError:
                self.last_error = "timeout"
                if self.verbose:
                    self._log("   ⏱️ Timeout ao inicializar stream")
                return False
            except Exception as exc:  # pragma: no cover - defensive logging
                if _is_rate_limit_error(exc):
                    self.last_error = f"rate_limit: {exc}" if exc else "rate_limit"
                    await _handle_rate_limit(log_callback)
                else:
                    self.last_error = (
                        f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                    )
                if self.verbose:
                    self._log(f"   ❌ Erro ao inicializar stream: {self.last_error}")
                return False

            if not hasattr(stream, "__aiter__"):
                self.last_error = "invalid_stream"
                if self.verbose:
                    self._log("   ❌ Stream inválido (não assíncrono)")
                return False
            chunks_received = 0

            async def _consume_stream(out_file) -> None:
                nonlocal received_audio, chunks_received
                try:
                    async for chunk in stream:
                        chunks_received += 1
                        if chunk["type"] == "audio":
                            out_file.write(chunk["data"])
                            received_audio = True
                finally:
                    with suppress(Exception):
                        await stream.aclose()

            synthesis_start = asyncio.get_event_loop().time()
            max_retries = 3
            retry_count = 0

            try:
                while retry_count < max_retries:
                    try:
                        heartbeat_task = None
                        if self.verbose:

                            async def _segment_heartbeat() -> None:
                                while True:
                                    await asyncio.sleep(10)
                                    elapsed = asyncio.get_event_loop().time() - synthesis_start
                                    status = "receiving" if received_audio else "waiting"
                                    self._log(f"   ... {status} ({elapsed:.0f}s)")

                            heartbeat_task = asyncio.create_task(_segment_heartbeat())

                        try:
                            with output_path.open(mode) as out_file:
                                await asyncio.wait_for(_consume_stream(out_file), timeout=timeout)
                        finally:
                            if heartbeat_task is not None:
                                heartbeat_task.cancel()
                                with suppress(asyncio.CancelledError):
                                    await heartbeat_task

                        if self.verbose and received_audio:
                            elapsed = asyncio.get_event_loop().time() - synthesis_start
                            self._log(
                                f"   ✅ Concluído em {elapsed:.1f}s ({chunks_received} chunks)"
                            )

                        break  # Success - exit retry loop

                    except asyncio.TimeoutError:
                        synthesis_time = asyncio.get_event_loop().time() - synthesis_start
                        self.last_error = "timeout"
                        if self.verbose:
                            self._log(
                                f"   ⏱️ Timeout após {synthesis_time:.1f}s (limite: {timeout}s)"
                            )
                        # Record timeout to network tuner
                        self._record_network_result(
                            success=False,
                            latency=synthesis_time,
                            is_timeout=True,
                            error_msg="timeout",
                        )
                        return False

                    except asyncio.CancelledError:
                        synthesis_time = asyncio.get_event_loop().time() - synthesis_start
                        self.last_error = "cancelled"
                        if self.verbose:
                            self._log(f"   🚫 Cancelado após {synthesis_time:.1f}s")
                        raise

                    except Exception as exc:
                        synthesis_time = asyncio.get_event_loop().time() - synthesis_start

                        if self.verbose:
                            self._log(
                                f"   ⚠️ Exceção ({exc.__class__.__name__}) após {synthesis_time:.1f}s: {exc}"
                            )

                        is_rate_limit = _is_rate_limit_error(exc)
                        is_cert_error = (
                            (
                                ClientConnectorCertificateError
                                and isinstance(exc, ClientConnectorCertificateError)
                            )
                            or (ClientConnectorError and isinstance(exc, ClientConnectorError))
                            or ("certificate" in str(exc).lower() or "ssl" in str(exc).lower())
                        )

                        is_no_audio = (
                            "noaudio" in str(exc).lower()
                            or exc.__class__.__name__.lower() == "noaudioreceived"
                        )
                        is_transient = (
                            is_cert_error
                            or is_no_audio
                            or "timeout" in str(exc).lower()
                            or "connection" in str(exc).lower()
                        )

                        # If *nothing* was received (0 chunks), first check if service is reachable.
                        allow_retry = True
                        health_ok = True
                        if is_no_audio and chunks_received == 0 and not received_audio:
                            allow_retry = retry_count < 1  # only one retry for no-audio
                            health_ok = await self._probe_edge_health(voice)

                        if is_rate_limit:
                            self.last_error = f"rate_limit: {exc}" if exc else "rate_limit"
                            # Record rate limit to network tuner
                            self._record_network_result(
                                success=False,
                                latency=synthesis_time,
                                is_rate_limit=True,
                                error_msg=str(exc),
                            )
                            backoff_time = await _handle_rate_limit(log_callback)
                            self._parallel_slots = min(self._parallel_slots, _edge_max_concurrency)
                            if retry_count < max_retries - 1:
                                retry_count += 1
                                await asyncio.sleep(backoff_time)
                                try:
                                    communicator = self._edge_tts.Communicate(text, voice)
                                    stream_candidate = communicator.stream()
                                    stream = (
                                        await stream_candidate
                                        if inspect.isawaitable(stream_candidate)
                                        else stream_candidate
                                    )
                                    chunks_received = 0
                                    received_audio = False
                                    continue
                                except Exception as retry_exc:
                                    self.last_error = f"retry_failed: {retry_exc}"
                                    if self.verbose:
                                        self._log(f"   ❌ Falha no retry: {retry_exc}")
                                    return False
                            return False

                        if is_transient and allow_retry and retry_count < max_retries - 1:
                            retry_count += 1
                            backoff_time = 2**retry_count  # 2s, 4s, 8s

                            # Detailed SSL error logging
                            if is_cert_error:
                                self._log(f"   🔒 Erro SSL: {exc.__class__.__name__}")
                            elif is_no_audio:
                                self._log(
                                    f"   🔇 Sem áudio ({exc.__class__.__name__}); retry {retry_count}/{max_retries - 1} em {backoff_time}s"
                                )
                            else:
                                self._log(
                                    f"   🔄 Erro transitório ({exc.__class__.__name__}); retry {retry_count}/{max_retries - 1} em {backoff_time}s"
                                )

                            await asyncio.sleep(backoff_time)

                            # Recreate communicator and stream for retry
                            try:
                                # SSL bypass já aplicado no topo do módulo via monkeypatch
                                communicator = self._edge_tts.Communicate(text, voice)
                                stream_candidate = communicator.stream()
                                stream = (
                                    await stream_candidate
                                    if inspect.isawaitable(stream_candidate)
                                    else stream_candidate
                                )
                                chunks_received = 0
                                received_audio = False
                                continue  # Retry
                            except Exception as retry_exc:
                                self.last_error = f"retry_failed: {retry_exc}"
                                if self.verbose:
                                    self._log(f"   ❌ Falha no retry: {retry_exc}")
                                return False
                        else:
                            # Not a cert error or max retries reached
                            self.last_error = (
                                f"{exc.__class__.__name__}: {exc}"
                                if exc
                                else exc.__class__.__name__
                            )
                            if is_no_audio and chunks_received == 0 and not received_audio:
                                if not health_ok:
                                    # Open cooldown to avoid hammering the service when it's not responding with audio.
                                    self._noaudio_backoff_until = (
                                        asyncio.get_event_loop().time()
                                        + max(5.0, EDGE_NOAUDIO_COOLDOWN_SECONDS)
                                    )
                                    self.last_error = f"service_unavailable (cooldown {int(EDGE_NOAUDIO_COOLDOWN_SECONDS)}s)"
                                    if self.verbose:
                                        self._log(
                                            f"   ⛔ Serviço indisponível - cooldown {int(EDGE_NOAUDIO_COOLDOWN_SECONDS)}s"
                                        )
                                else:
                                    # Provável problema de payload; não abrir cooldown global
                                    self.last_error = "no_audio_payload"
                                    if self.verbose:
                                        self._log("   ⚠️ Sem áudio (provável problema de conteúdo)")
                            if is_cert_error:
                                self._log("   ❌ Erro SSL persistente")
                            return False
            finally:
                with suppress(Exception):
                    connector = getattr(communicator, "connector", None)
                    if connector:
                        maybe_close = getattr(connector, "close", None)
                        if callable(maybe_close):
                            result = maybe_close()
                            if asyncio.iscoroutine(result):
                                await result

            # Record timing for adaptive tuning
            synthesis_end = asyncio.get_event_loop().time()
            segment_duration = synthesis_end - synthesis_start
            text_chars = len(text) if text else 0

            if received_audio:
                with suppress(Exception):
                    await _record_success()
                # Record successful segment timing for auto-tuning
                self._record_segment_timing(text_chars, segment_duration, success=True)
                # Record success to network tuner for adaptive speed recovery
                self._record_network_result(
                    success=True,
                    latency=segment_duration,
                )
            else:
                self.last_error = "no_audio"
                # Record failed segment timing
                self._record_segment_timing(text_chars, segment_duration, success=False)
                # Record failure to network tuner for automatic adjustment
                self._record_network_result(
                    success=False,
                    latency=segment_duration,
                    error_msg="no_audio",
                )

            return received_audio


__all__ = [
    "EdgeTTSEngine",
    "get_edge_performance_stats",
    "get_adaptive_chunk_size",
    "get_adaptive_concurrency",
    "reset_adaptive_settings",
]
