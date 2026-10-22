# -*- coding: utf-8 -*-
"""Edge TTS engine wrapper used by the converter and tests."""

from __future__ import annotations

import asyncio
import importlib
import inspect
import os
import re

import ssl as _ssl_module
import threading
from contextlib import AsyncExitStack as AsyncExitStack
from contextlib import suppress
from pathlib import Path
from typing import Any, Dict, List, Optional
from typing import Callable as Callable
from typing import Set as Set
from typing import Tuple as Tuple
from unittest.mock import Mock

from ..error_classifier import classify_error as classify_error
from ..speed_monitor import AdaptiveEdgeTuner as AdaptiveEdgeTuner
from ..speed_monitor import get_edge_tuner as get_edge_tuner
from ..synthesis_tracker import SynthesisTracker
from ..utils import TextValidator as TextValidator
from .edge_adaptive_control import _get_global_edge_limiter as _get_global_edge_limiter
from .edge_adaptive_control import _handle_rate_limit as _handle_rate_limit
from .edge_adaptive_control import _is_rate_limit_error as _is_rate_limit_error
from .edge_adaptive_control import _record_success as _record_success
from .edge_adaptive_control import _reduce_chunk_size as _reduce_chunk_size
from .edge_adaptive_control import _wait_if_rate_limited as _wait_if_rate_limited
from .edge_adaptive_control import get_adaptive_chunk_size as get_adaptive_chunk_size
from .edge_adaptive_control import get_adaptive_concurrency as get_adaptive_concurrency
from .edge_adaptive_control import get_edge_performance_stats as get_edge_performance_stats
from .edge_adaptive_control import reset_adaptive_settings as reset_adaptive_settings
from .edge_engine_initialization import EdgeEngineInitialization
from .edge_parallel_synthesis import EdgeParallelSynthesis
from .edge_request_coordinator import EdgeRequestCoordinator
from .edge_runtime_tuning import EdgeRuntimeTuning
from .edge_segment_policy import AdaptiveSegmentDurationPolicy as AdaptiveSegmentDurationPolicy
from .edge_segment_recovery import EdgeSegmentRecovery
from .edge_segment_transport import EdgeSegmentTransport
from .edge_text_segmentation import EdgeTextSegmentation
from .network_tuner import NetworkTuner as NetworkTuner

# **SSL BYPASS**: Monkeypatch SSL BEFORE importing edge_tts
# IMPORTANT: Required because Microsoft certificate (api.msedgeservices.com) is expired
# Edge-TTS uses ssl.create_default_context(cafile=certifi.where())
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
SAFE_ADAPTIVE_SEGMENT_SECONDS = 85.0


# If Edge returns no audio at all, it's often a connectivity / service issue.
# Use a short circuit-breaker to avoid spending minutes retrying the same request.
EDGE_NOAUDIO_COOLDOWN_SECONDS = float(os.getenv("EDGE_NOAUDIO_COOLDOWN_SECONDS", "15"))
EDGE_SEGMENT_MAX_RETRIES = max(1, int(os.getenv("EDGE_SEGMENT_MAX_RETRIES", "1") or "1"))
EDGE_NETWORK_ABORT_AFTER_FAILS = max(
    1, int(os.getenv("EDGE_NETWORK_ABORT_AFTER_FAILS", "1") or "1")
)
EDGE_STREAM_MAX_RETRIES = max(1, int(os.getenv("EDGE_STREAM_MAX_RETRIES", "1") or "1"))
# Minimum byte size for a synthesised chunk/segment to be considered valid.
# Anything below this is an empty or truncated MP3 fragment that would corrupt
# the concatenated chapter output; mirrors the >=1024 resume pre-scan threshold.
_MIN_VALID_CHUNK_BYTES = max(1, int(os.getenv("EDGE_MIN_VALID_CHUNK_BYTES", "1024") or "1024"))

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
# Apr 2026 update: real-world Carl conversion peaked at 558 chars/s and
# averaged 292 chars/s; bumping default chunk to 12K (the documented Edge
# safe ceiling) cuts request count by ~17% on long chapters at no
# stability cost in measured runs.
_DEFAULT_CHUNK_SIZE = 12000
_DEFAULT_CONCURRENCY = 8
_SAFE_CHUNK_MIN = 2000  # Minimum safe chunk size (reduced for rate-limit recovery)
_SAFE_CHUNK_MAX = 15000  # Upper bound for throughput testing
_SAFE_CONCURRENCY_MIN = 2  # Always use some parallelism
# Hard upper bound for the configurable cap. The previous code clamped to
# 8 unconditionally; raising the ceiling to 16 lets local installs (no
# shared HF IP) opt into more parallelism via EDGE_MAX_CONCURRENCY_CAP.
# The default cap is still 8 — opt-in only.
_SAFE_CONCURRENCY_MAX = 8  # Default hard cap for shared environments
_SAFE_CONCURRENCY_CEILING = 16  # Highest value the env override may set

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
_edge_concurrency_cap = max(
    _SAFE_CONCURRENCY_MIN, min(_edge_concurrency_cap, _SAFE_CONCURRENCY_CEILING)
)
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
_EDGE_IDENTITY_ROTATION_ENABLED = os.getenv(
    "EDGE_IDENTITY_ROTATION_ENABLED", "true"
).strip().lower() in {"1", "true", "yes", "on"}
_EDGE_IDENTITY_ROTATION_WINDOW = max(1, int(os.getenv("EDGE_IDENTITY_ROTATION_WINDOW", "2") or "2"))


try:  # pragma: no cover - lazily loaded
    from ..language import LanguageMarkup
    from ..text_formatting import TextFormattingProcessor
except ImportError:  # pragma: no cover - during optional dependency resolution
    LanguageMarkup = None  # type: ignore
    TextFormattingProcessor = None  # type: ignore


_edge_prewarm_done: bool = False
_edge_prewarm_lock: Optional[asyncio.Lock] = None
# Sync mutex guarding the lazy creation of ``_edge_prewarm_lock`` itself.
# Without this, two coroutines hitting the ``is None`` check concurrently
# could each create their own asyncio.Lock and race past the gate.
_edge_prewarm_init_mutex = threading.Lock()


async def prewarm_edge(voice: str = "en-US-AriaNeural", *, force: bool = False) -> bool:
    """Open and drain a tiny Edge-TTS stream to amortize the TLS handshake
    + first-request latency before the chapter loop starts.

    Idempotent within a process: a second call is a no-op unless ``force``
    is set. Best-effort — any failure is swallowed and reported via the
    return value (``True`` on success, ``False`` on any error). Mirrors the
    pattern used by ``_prewarm_kokoro_pipeline``.
    """
    global _edge_prewarm_done, _edge_prewarm_lock, edge_tts
    if _edge_prewarm_done and not force:
        return True
    # Lazy-create the asyncio lock under a sync mutex so concurrent
    # callers see the same Lock instance.
    with _edge_prewarm_init_mutex:
        if _edge_prewarm_lock is None:
            _edge_prewarm_lock = asyncio.Lock()
        lock = _edge_prewarm_lock
    async with lock:
        if _edge_prewarm_done and not force:
            return True
        try:
            if edge_tts is None or isinstance(edge_tts, Mock):
                edge_tts = importlib.import_module("edge_tts")  # type: ignore
            comm = edge_tts.Communicate("Hi.", voice)  # type: ignore[attr-defined]
            # Drain the async iterator without writing anywhere — we only
            # care about establishing the connection + voice handshake.
            async for _chunk in comm.stream():
                pass
        except Exception:
            return False
        _edge_prewarm_done = True
        return True


class EdgeTTSEngine(
    EdgeEngineInitialization,
    EdgeRequestCoordinator,
    EdgeParallelSynthesis,
    EdgeSegmentTransport,
    EdgeTextSegmentation,
    EdgeSegmentRecovery,
    EdgeRuntimeTuning,
):
    """Small facade around ``edge_tts`` with predictable behaviour."""

    _noaudio_backoff_until: float = 0.0


    def _log(self, message: str) -> None:
        """Log message using callback if available, otherwise print."""
        if self.log_callback:
            self.log_callback(message)
        else:
            print(message)

    def _emit_metric(self, payload: Dict[str, Any]) -> None:
        """Emit compact telemetry without allowing observers to affect synthesis."""
        callback = getattr(self, "metric_callback", None)
        if not callable(callback):
            return
        try:
            callback(dict(payload))
        except Exception:
            return

    def _emit_validation_metric(
        self, *, segment_index: int, elapsed_ms: float, valid: bool
    ) -> None:
        """Record the post-synthesis audio validation phase."""
        self._emit_metric(
            {
                "event": "edge_segment_validation",
                "engine": "edge",
                "segment_index": int(segment_index),
                "status": "success" if valid else "failed",
                "validation_ms": round(max(0.0, float(elapsed_ms or 0.0)), 3),
            }
        )

    def _measure_segment_validation(self, audio_path: Optional[Path], segment_index: int) -> float:
        """Validate one generated segment and emit timing without changing failure semantics."""
        started = asyncio.get_running_loop().time()
        valid = False
        duration = 0.0
        try:
            from ..audio_validator import AudioValidator

            if audio_path is None:
                raise ValueError("missing_audio_path")
            duration = float(AudioValidator().get_audio_duration(audio_path) or 0.0)
            valid = duration > 0.0
        except Exception:
            duration = 0.0
        finally:
            elapsed_ms = (asyncio.get_running_loop().time() - started) * 1000.0
            self._emit_validation_metric(
                segment_index=segment_index,
                elapsed_ms=elapsed_ms,
                valid=valid,
            )
        return duration

    def get_synthesis_log(self) -> List[Dict]:
        """Return log of all segments processed during last synthesis."""
        if self._synthesis_tracker is None:
            return []
        return self._synthesis_tracker.get_synthesis_log()

    def get_synthesis_tracker(self) -> Optional[SynthesisTracker]:
        """Return the SynthesisTracker instance used for last synthesis."""
        return self._synthesis_tracker


    def supports_multilingual(self) -> bool:
        """Edge TTS supports multilingual via voice switching and [[lang:]] tags"""
        return True

    def supports_emphasis(self) -> bool:
        """Edge TTS supports emphasis via SSML when voice is Neural"""
        return self._supports_emphasis()


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

    def _apply_pending_segment_policy(self) -> None:
        """Apply the previous chapter result immediately before the next chapter boundary."""
        pending = self._pending_segment_policy_result
        if pending is None:
            return
        self._pending_segment_policy_result = None
        success, reason = pending
        event = self._segment_duration_policy.observe_chapter(success=success, reason=reason)
        if event:
            self._emit_metric(event)

    def get_segment_policy_state(self) -> Dict[str, Any]:
        """Return bounded adaptive segment state for runtime tuning checkpoints."""
        return self._segment_duration_policy.snapshot()

    def restore_segment_policy_state(self, state: Dict[str, Any]) -> None:
        """Restore adaptive segment state without touching content cache files."""
        self._segment_duration_policy.restore(state)

    @staticmethod
    def _segment_policy_failure_reason(error: Optional[str]) -> str:
        text = str(error or "").lower()
        if "timeout" in text:
            return "timeout"
        if "no_audio" in text or "noaudioreceived" in text:
            return "no_audio"
        if "incomplete" in text or "truncat" in text:
            return "truncation"
        if "429" in text or "rate" in text or "thrott" in text:
            return "rate_limit"
        return "chapter_failure"

    async def synthesize_async(
        self,
        text: str,
        output_path: Path,
        formatting_segments=None,
        progress_callback=None,
        chunk_callback=None,
        pre_segment_callback=None,
        resume_chunks_dir: Optional[Path] = None,
    ) -> Optional[Path]:
        """Synthesize one chapter and defer policy adjustment to the next boundary."""
        self._apply_pending_segment_policy()
        try:
            result = await self._synthesize_async_impl(
                text,
                output_path,
                formatting_segments=formatting_segments,
                progress_callback=progress_callback,
                chunk_callback=chunk_callback,
                pre_segment_callback=pre_segment_callback,
                resume_chunks_dir=resume_chunks_dir,
            )
        except BaseException:
            self._pending_segment_policy_result = (
                False,
                self._segment_policy_failure_reason(self.last_error),
            )
            raise
        self._pending_segment_policy_result = (
            result is not None,
            "" if result is not None else self._segment_policy_failure_reason(self.last_error),
        )
        return result


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


__all__ = [
    "EdgeTTSEngine",
    "get_edge_performance_stats",
    "get_adaptive_chunk_size",
    "get_adaptive_concurrency",
    "reset_adaptive_settings",
]
