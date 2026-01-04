# -*- coding: utf-8 -*-
"""Adaptive heuristics that tune conversion speed per chapter/engine."""

from __future__ import annotations

import time
from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, List, Optional


@dataclass
class ChapterSpeedDecision:
    """Action taken before synthesising a chapter."""

    timeout_scale: Optional[float] = None
    message: Optional[str] = None
    switch_engine: Optional[str] = None  # Recommended engine to switch to
    switch_reason: Optional[str] = None  # Why we recommend switching


@dataclass
class ChapterPerf:
    """Aggregate of one chapter conversion."""

    index: int
    name: str
    chars: int
    elapsed: float
    success: bool
    error: Optional[str] = None
    from_cache: bool = False


class AdaptiveSpeedController:
    """Tracks recent chapters and tunes heuristics to avoid stalls."""

    def __init__(self) -> None:
        self._history: Dict[str, Deque[ChapterPerf]] = {
            "edge": deque(maxlen=6),
            "coqui": deque(maxlen=6),
            "piper": deque(maxlen=6),
        }
        self._edge_failure_streak = 0
        self._edge_last_profile: Dict[str, Optional[float]] = {
            "chunk_char_limit": None,
            "max_segment_seconds": None,
            "words_per_minute": None,
        }
        # Engine performance tracking for auto-mode
        self._engine_scores: Dict[str, float] = {}
        self._last_switch_time: float = 0
        self._current_engine: Optional[str] = None
        self._switch_cooldown: float = 300.0  # 5 minutes between switches

    def before_chapter(
        self,
        engine: str,
        *,
        chapter_index: int,
        chapter_name: str,
        chapter_chars: int,
        tts_engine,
        config,
        verbose: bool = False,
    ) -> ChapterSpeedDecision:
        engine = (engine or "").lower()

        if engine != "edge":
            timeout_scale = self._timeout_scale(engine, chapter_chars)
            message = None
            if verbose and timeout_scale not in (None, 1.0):
                pct = int((timeout_scale - 1.0) * 100)
                message = f"⚡ {engine.upper()} capítulo {chapter_index}: timeout ajustado em {pct:+d}% ({chapter_chars} chars)"
            return ChapterSpeedDecision(timeout_scale=timeout_scale, message=message)

        adjustments, note = self._prepare_edge_profile(
            chapter_index,
            chapter_name,
            chapter_chars,
            tts_engine,
            config,
        )
        timeout_scale = self._timeout_scale(engine, chapter_chars)

        if adjustments and hasattr(tts_engine, "apply_speed_profile"):
            tts_engine.apply_speed_profile(**adjustments)
            if "chunk_char_limit" in adjustments:
                config.edge_chunk_chars = int(adjustments["chunk_char_limit"])
            if "max_segment_seconds" in adjustments:
                config.edge_max_segment_seconds = int(adjustments["max_segment_seconds"])

        message = note
        if verbose and not message and adjustments:
            message = (
                f"⚡ EDGE capítulo {chapter_index}: "
                f"chunk={adjustments.get('chunk_char_limit')} "
                f"seg={adjustments.get('max_segment_seconds')} "
                f"wpm={adjustments.get('words_per_minute')}"
            )

        return ChapterSpeedDecision(timeout_scale=timeout_scale, message=message)

    def after_chapter(
        self,
        engine: str,
        *,
        chapter_index: int,
        chapter_name: str,
        chapter_chars: int,
        elapsed: float,
        success: bool,
        error: Optional[str],
        from_cache: bool,
        tts_engine=None,
    ) -> Optional[str]:
        engine = (engine or "").lower()
        elapsed = max(float(elapsed), 0.01)

        if engine not in self._history:
            return None

        if engine == "edge" and not from_cache:
            if success:
                self._edge_failure_streak = 0
            else:
                self._edge_failure_streak += 1

        perf = ChapterPerf(
            index=chapter_index,
            name=chapter_name,
            chars=chapter_chars,
            elapsed=elapsed,
            success=success,
            error=error,
            from_cache=from_cache,
        )

        if not from_cache:
            self._history[engine].append(perf)

        prefix = "♻️" if from_cache else ("✅" if success else "❌")
        throughput = int(perf.chars / elapsed) if perf.chars else 0
        base = (
            f"{prefix} [{engine.upper()}] Capítulo {perf.index} "
            f"→ {int(elapsed)}s para {perf.chars} chars"
        )
        if throughput:
            base += f" (~{throughput} chars/s)"

        if perf.error and not success:
            base += f" | erro: {perf.error}"

        profile_desc = self._describe_profile(engine, tts_engine)
        if profile_desc:
            base += f" | perfil: {profile_desc}"

        if from_cache:
            return base + " (cache)"

        recent = self._history[engine]
        if len(recent) >= 2:
            avg = sum(item.elapsed for item in recent) / len(recent)
            base += f" | média {avg:.1f}s (últimos {len(recent)})"

        return base

    def _timeout_scale(self, engine: str, chapter_chars: int) -> Optional[float]:
        chapter_chars = max(int(chapter_chars), 0)
        if not chapter_chars:
            return None

        # Start from a neutral multiplier
        scale = 1.0
        if chapter_chars <= 6000:
            scale = 0.75
        elif chapter_chars <= 14000:
            scale = 0.9
        elif chapter_chars >= 36000:
            scale = 1.25
        elif chapter_chars >= 24000:
            scale = 1.15

        recent = self._history.get(engine or "", deque())
        slow_recent = any(item.elapsed > 150 and item.success for item in recent)
        if slow_recent:
            scale = max(scale, 1.2)

        # Ignore tiny adjustments
        if abs(scale - 1.0) < 0.05:
            return None
        return max(0.6, min(scale, 1.35))

    def _prepare_edge_profile(
        self,
        chapter_index: int,
        chapter_name: str,
        chapter_chars: int,
        tts_engine,
        config,
    ) -> tuple[Dict[str, float], Optional[str]]:
        history = self._history["edge"]
        # OPTIMIZED: Start from aggressive defaults but cap for reliability
        chunk_limit = int(getattr(config, "edge_chunk_chars", 4000) or 4000)
        max_seconds = float(getattr(config, "edge_max_segment_seconds", 45) or 45)

        profile = getattr(tts_engine, "speed_profile", None)
        words_per_minute = profile.get("words_per_minute") if isinstance(profile, dict) else 170

        adjustments: Dict[str, float] = {}
        chars = max(chapter_chars, 0)

        # Keep chunks moderate; avoid very large segments that often truncate.
        if chars > 32000:
            chunk_limit = max(chunk_limit, 6000)
            max_seconds = max(max_seconds, 65.0)
        elif chars > 18000:
            chunk_limit = max(chunk_limit, 6000)
            max_seconds = max(max_seconds, 55.0)
        elif chars > 10000:
            chunk_limit = max(chunk_limit, 4000)

        recent_failures = sum(1 for entry in history if not entry.success)
        slow_runs = sum(
            1 for entry in history if entry.elapsed > 100 and entry.success
        )  # Reduced from 130

        if recent_failures or self._edge_failure_streak:
            penalty = 1000 * max(recent_failures, self._edge_failure_streak)
            chunk_limit = max(4000, chunk_limit - penalty)
            max_seconds = max(45.0, min(max_seconds, 65.0))
            words_per_minute = min(words_per_minute, 175)
        elif slow_runs:
            chunk_limit = min(10000, chunk_limit + 2000)
            max_seconds = min(75.0, max_seconds + 6.0)
            words_per_minute = max(words_per_minute, 190)
        else:
            words_per_minute = max(words_per_minute, 180)

        # Keep chunk sizes within reliable bounds.
        chunk_limit = int(max(4000, min(chunk_limit, 12000)))
        max_seconds = float(max(45.0, min(max_seconds, 85.0)))
        words_per_minute = int(max(160, min(words_per_minute, 230)))

        changed = False
        for key, value in (
            ("chunk_char_limit", chunk_limit),
            ("max_segment_seconds", max_seconds),
            ("words_per_minute", words_per_minute),
        ):
            last = self._edge_last_profile.get(key)
            if last is None or abs(last - value) >= (50 if key == "chunk_char_limit" else 2):
                adjustments[key] = value
                self._edge_last_profile[key] = value
                changed = True

        message = None
        if changed:
            message = (
                f"⚡ EDGE capítulo {chapter_index}: "
                f"{chapter_chars} chars → chunk {chunk_limit}, "
                f"segmento {int(max_seconds)}s, {words_per_minute} wpm"
            )

        return (adjustments if changed else {}, message)

    @staticmethod
    def _describe_profile(engine: str, tts_engine) -> Optional[str]:
        if engine != "edge" or not tts_engine:
            return None

        profile = getattr(tts_engine, "speed_profile", None)
        if not isinstance(profile, dict):
            return None

        chunk = profile.get("chunk_char_limit")
        seconds = profile.get("max_segment_seconds")
        wpm = profile.get("words_per_minute")
        if not chunk or not seconds or not wpm:
            return None
        return f"{int(chunk)} chars, {int(seconds)}s, {int(wpm)} wpm"

    def get_engine_ranking(self, available_engines: List[str]) -> List[tuple[str, float, str]]:
        """
        Get engines ranked by performance (best first).

        Returns:
            List of (engine_name, score, reason) tuples
        """
        rankings = []

        for engine in available_engines:
            score, reason = self._calculate_engine_score(engine)
            rankings.append((engine, score, reason))

        # Sort by score (higher is better)
        rankings.sort(key=lambda x: x[1], reverse=True)
        return rankings

    def _calculate_engine_score(self, engine: str) -> tuple[float, str]:
        """
        Calculate performance score for an engine.

        Score components:
        - Speed (chars/second): Higher is better
        - Success rate: Higher is better
        - Consistency: Lower variance is better
        - Recency: Recent performance weighted more

        Returns:
            (score, reason) tuple
        """
        history = self._history.get(engine, deque())

        if not history:
            # No data - give neutral score
            return (50.0, "sem histórico")

        # Calculate metrics
        recent_items = list(history)[-3:]  # Last 3 chapters
        if not recent_items:
            return (50.0, "sem dados recentes")

        # Speed (chars/second)
        speeds = [
            item.chars / item.elapsed for item in recent_items if item.success and item.elapsed > 0
        ]

        if not speeds:
            return (10.0, "todas falhas recentes")

        avg_speed = sum(speeds) / len(speeds)

        # Success rate
        successes = sum(1 for item in recent_items if item.success)
        success_rate = successes / len(recent_items)

        # Consistency (lower std dev is better)
        if len(speeds) >= 2:
            mean = sum(speeds) / len(speeds)
            variance = sum((x - mean) ** 2 for x in speeds) / len(speeds)
            std_dev = variance**0.5
            consistency = 1.0 / (1.0 + std_dev / mean)  # Normalize
        else:
            consistency = 0.5

        # Calculate final score (0-100)
        # Speed is primary factor (weighted 60%)
        # Success rate (weighted 30%)
        # Consistency (weighted 10%)
        speed_score = min(avg_speed / 5, 100)  # Normalize to 0-100 (500 chars/s = max)
        success_score = success_rate * 100
        consistency_score = consistency * 100

        final_score = speed_score * 0.6 + success_score * 0.3 + consistency_score * 0.1

        reason = f"{int(avg_speed)} chars/s, {int(success_rate * 100)}% sucesso"
        return (final_score, reason)

    def recommend_engine_switch(
        self, current_engine: str, available_engines: List[str], verbose: bool = False
    ) -> Optional[tuple[str, str]]:
        """
        Recommend switching to a different engine if current one is underperforming.

        Returns:
            (recommended_engine, reason) or None if no switch recommended
        """
        if not available_engines or len(available_engines) < 2:
            return None

        # Respect cooldown period
        now = time.time()
        if now - self._last_switch_time < self._switch_cooldown:
            return None

        # Get current engine performance
        current_score, current_reason = self._calculate_engine_score(current_engine)

        # Check if current engine is performing poorly
        if current_score >= 60:
            # Current engine is doing fine
            return None

        # Find best alternative
        rankings = self.get_engine_ranking(available_engines)

        if verbose:
            print("📊 Engine Performance Rankings:")
            for engine, score, reason in rankings:
                indicator = "⭐" if engine == current_engine else "  "
                print(f"{indicator} {engine}: {score:.1f} ({reason})")

        # Get best alternative (skip current engine)
        for engine, score, reason in rankings:
            if engine == current_engine:
                continue

            # Switch if alternative is significantly better (20+ point difference)
            if score > current_score + 20:
                return (
                    engine,
                    f"{engine} mais rápido ({reason}) vs {current_engine} ({current_reason})",
                )

        return None

    def record_engine_switch(self, new_engine: str) -> None:
        """Record that we switched to a new engine."""
        self._current_engine = new_engine
        self._last_switch_time = time.time()

    def should_enable_parallel(self, engine: str) -> bool:
        """
        Determine if parallel processing should be enabled for this engine.

        Returns True if:
        - Engine is Edge (supports parallel)
        - Recent performance is good (no recent failures)
        """
        if engine != "edge":
            return False

        history = self._history.get("edge", deque())
        if not history:
            return True  # Default to enabled

        # Check last 3 chapters
        recent = list(history)[-3:]
        failures = sum(1 for item in recent if not item.success)

        # Disable parallel if too many failures
        if failures >= 2:
            return False

        return True


__all__ = ["AdaptiveSpeedController", "ChapterSpeedDecision"]
