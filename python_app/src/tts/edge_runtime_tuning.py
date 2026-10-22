# -*- coding: utf-8 -*-
"""Per-engine throughput and network tuning."""

from __future__ import annotations

from typing import Dict, Optional

from ..speed_monitor import AdaptiveEdgeTuner


class EdgeRuntimeTuning:
    """Own the per-engine throughput and network tuning."""

    def _get_tuner(self) -> AdaptiveEdgeTuner:
        """Get or create the adaptive tuner for this engine."""
        from . import edge_engine as _runtime
        if self._tuner is None:
            self._tuner = _runtime.get_edge_tuner(
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
        from . import edge_engine as _runtime

        changed = []

        new_chunk = config.get("chunk_size")
        if new_chunk and new_chunk != self._chunk_char_limit:
            old_chunk = self._chunk_char_limit
            self._chunk_char_limit = max(_runtime._SAFE_CHUNK_MIN, min(new_chunk, _runtime._SAFE_CHUNK_MAX))
            _runtime._edge_current_chunk_size = self._chunk_char_limit
            changed.append(f"chunk: {old_chunk} -> {self._chunk_char_limit}")

        new_conc = config.get("concurrency")
        if new_conc and new_conc != _runtime._edge_max_concurrency:
            old_conc = _runtime._edge_max_concurrency
            _runtime._edge_max_concurrency = max(_runtime._SAFE_CONCURRENCY_MIN, min(new_conc, _runtime._SAFE_CONCURRENCY_MAX))
            self._parallel_slots = _runtime._edge_max_concurrency
            # Update rate limiters
            for loop_id in list(_runtime._edge_rate_limiters.keys()):
                _runtime._edge_rate_limiters[loop_id] = _runtime.asyncio.Semaphore(_runtime._edge_max_concurrency)
            changed.append(f"concurrency: {old_conc} -> {_runtime._edge_max_concurrency}")

        new_seg = config.get("max_segment_seconds")
        if new_seg and new_seg != self._max_segment_seconds:
            old_seg = self._max_segment_seconds
            self._max_segment_seconds = max(30.0, min(float(new_seg), _runtime.MAX_EDGE_SEGMENT_SECONDS))
            changed.append(f"segment: {old_seg:.0f}s -> {self._max_segment_seconds:.0f}s")

        if changed and self.verbose:
            self._log(f"🔧 AUTO-TUNE: {', '.join(changed)}")

    def _apply_network_tuning(self) -> None:
        """Apply settings from network tuner to engine."""
        from . import edge_engine as _runtime

        config = self._network_tuner.config
        changed = []

        # Apply chunk size
        if config.chunk_size != self._chunk_char_limit:
            old = self._chunk_char_limit
            self._chunk_char_limit = max(
                config.min_chunk_size, min(config.chunk_size, config.max_chunk_size)
            )
            _runtime._edge_current_chunk_size = self._chunk_char_limit
            changed.append(f"chunk: {old}→{self._chunk_char_limit}")

        # Apply concurrency
        if config.concurrency != self._parallel_slots:
            old = self._parallel_slots
            self._parallel_slots = max(
                config.min_concurrency, min(config.concurrency, config.max_concurrency)
            )
            _runtime._edge_max_concurrency = self._parallel_slots
            # Update rate limiters
            for loop_id in list(_runtime._edge_rate_limiters.keys()):
                _runtime._edge_rate_limiters[loop_id] = _runtime.asyncio.Semaphore(_runtime._edge_max_concurrency)
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
