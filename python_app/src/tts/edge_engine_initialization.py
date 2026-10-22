# -*- coding: utf-8 -*-
"""Engine construction and retry identity setup."""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Optional, Tuple

from ..speed_monitor import AdaptiveEdgeTuner
from ..synthesis_tracker import SynthesisTracker


class EdgeEngineInitialization:
    """Own the engine construction and retry identity setup."""

    _synthesis_tracker: Optional[SynthesisTracker]

    def __init__(
        self,
        voice: str,
        *,
        primary_language: Optional[str] = None,
        language_voices: Optional[Dict[str, str]] = None,
        verbose: bool = False,
        max_segment_seconds: Optional[float] = None,
        adaptive_segment_seconds: bool = False,
        adaptive_segment_max_seconds: float = 180.0,
        chunk_char_limit: Optional[int] = None,
        enable_parallel: bool = True,
        formatting_cues_enabled: bool = True,
        formatting_locale: str = "pt",
        log_callback: Optional[Callable[[str], None]] = None,
        metric_callback: Optional[Callable[[Dict[str, Any]], None]] = None,
        enable_character_voices: bool = False,
        narrator_voice: Optional[str] = None,
        character_voice: Optional[str] = None,
    ) -> None:
        from . import edge_engine as _runtime

        if isinstance(_runtime.edge_tts, _runtime.Mock):
            if getattr(_runtime.edge_tts, "side_effect", None):
                raise ImportError("Edge-TTS not installed")
            module = _runtime.edge_tts
        else:
            if _runtime.edge_tts is None:
                try:
                    _runtime.edge_tts = _runtime.importlib.import_module("edge_tts")  # type: ignore
                except ImportError as exc:
                    raise ImportError("Edge-TTS not installed") from exc
            module = _runtime.edge_tts

        # Per-instance rate limiter (instead of global) for better multi-chapter performance
        # This prevents artificial serialization when processing multiple chapters in parallel
        self._rate_limiter = _runtime.asyncio.Semaphore(_runtime._edge_max_concurrency)
        self._global_rate_limiter: Optional[_runtime.asyncio.Semaphore] = None
        self._global_rate_limiter_loop: Optional[_runtime.asyncio.AbstractEventLoop] = None

        self.voice = voice
        self._edge_tts = module
        self.primary_language = (primary_language or "auto").split("-", 1)[0].lower()
        self.enable_character_voices = bool(enable_character_voices)
        # Default both slots to the primary voice so a partially-configured
        # caller still produces sensible output. The splitter only fires
        # when both voices are distinct, otherwise it's a no-op.
        self.narrator_voice = (narrator_voice or "").strip() or voice
        self.character_voice = (character_voice or "").strip() or voice
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
        self.metric_callback = metric_callback
        max_seconds = (
            max_segment_seconds if max_segment_seconds is not None else _runtime.DEFAULT_EDGE_SEGMENT_SECONDS
        )
        self._max_segment_seconds = max(30.0, min(float(max_seconds), _runtime.MAX_EDGE_SEGMENT_SECONDS))
        self._segment_duration_policy = _runtime.AdaptiveSegmentDurationPolicy(
            enabled=adaptive_segment_seconds,
            initial_seconds=self._max_segment_seconds,
            hard_max_seconds=adaptive_segment_max_seconds,
        )
        self._pending_segment_policy_result: Optional[Tuple[bool, str]] = None
        # Use adaptive chunk size if no override provided
        if chunk_char_limit is not None:
            try:
                chunk_limit = int(chunk_char_limit)
            except (TypeError, ValueError):
                chunk_limit = _runtime._edge_current_chunk_size
        else:
            chunk_limit = _runtime._edge_current_chunk_size  # Use adaptive setting
        self._chunk_char_limit = max(
            _runtime._SAFE_CHUNK_MIN, min(chunk_limit, _runtime._SAFE_CHUNK_MAX)
        )  # Clamp to safe range
        self._chunk_log_every = max(25, int(self._chunk_char_limit / 400))
        self._words_per_minute = _runtime.WORDS_PER_MINUTE
        self.partial_failure_detected: bool = False
        self.last_segment_report: Dict[str, int] = {"expected": 0, "generated": 0, "failed": 0}
        self._enable_parallel = enable_parallel
        # Stable view of how many tasks we *intend* to run in parallel regardless of current semaphore value
        self._parallel_slots = _runtime._edge_max_concurrency if self._enable_parallel else 1

        # Network-aware auto-tuner for adaptive parameter adjustment
        self._network_tuner = _runtime.NetworkTuner(
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
        self._identity_rotation_enabled = _runtime._EDGE_IDENTITY_ROTATION_ENABLED
        self._rate_limit_streak = 0
        self._voice_rotation_pool: List[str] = []
        self._voice_rotation_cursor = 0
        self._init_identity_pool()

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
            if self._identity_rotation_enabled and len(self._voice_rotation_pool) > 1:
                self._log(
                    f"   Identity rotation: {len(self._voice_rotation_pool)} voice identities"
                )

    def _init_identity_pool(self) -> None:
        """Build a deduplicated voice pool used after repeated throttling."""
        from . import edge_engine as _runtime
        entries: List[str] = []
        primary = str(self.voice or "").strip()
        if primary:
            entries.append(primary)

        env_pool = _runtime.os.getenv("EDGE_IDENTITY_VOICES", "").strip()
        if env_pool:
            entries.extend(item.strip() for item in env_pool.split(",") if item.strip())

        for _, value in sorted((self.language_voices or {}).items()):
            candidate = str(value or "").strip()
            if candidate:
                entries.append(candidate)

        seen = set()
        deduped: List[str] = []
        for voice_name in entries:
            key = voice_name.lower()
            if key in seen:
                continue
            seen.add(key)
            deduped.append(voice_name)
        self._voice_rotation_pool = deduped

    def _rotate_retry_voice(self, current_voice: str) -> str:
        """Choose another voice identity when rate-limit streak is high."""
        from . import edge_engine as _runtime
        if (
            not self._identity_rotation_enabled
            or len(self._voice_rotation_pool) <= 1
            or self._rate_limit_streak < _runtime._EDGE_IDENTITY_ROTATION_WINDOW
        ):
            return current_voice
        current_key = str(current_voice or "").lower()
        for _ in range(len(self._voice_rotation_pool)):
            self._voice_rotation_cursor = (self._voice_rotation_cursor + 1) % len(
                self._voice_rotation_pool
            )
            candidate = self._voice_rotation_pool[self._voice_rotation_cursor]
            if str(candidate).lower() != current_key:
                if self.verbose:
                    self._log(f"   🔁 Rate-limit rotation: voice {current_voice} -> {candidate}")
                return candidate
        return current_voice
