# -*- coding: utf-8 -*-
"""Adaptive heuristics that tune conversion speed per chapter/engine."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, Optional


@dataclass
class ChapterSpeedDecision:
    """Action taken before synthesising a chapter."""

    timeout_scale: Optional[float] = None
    message: Optional[str] = None


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
        chunk_limit = int(getattr(config, "edge_chunk_chars", 14000) or 14000)
        max_seconds = float(getattr(config, "edge_max_segment_seconds", 75) or 75)

        profile = getattr(tts_engine, "speed_profile", None)
        words_per_minute = (
            profile.get("words_per_minute") if isinstance(profile, dict) else 150
        )

        adjustments: Dict[str, float] = {}
        chars = max(chapter_chars, 0)

        if chars > 32000:
            chunk_limit = max(chunk_limit, 20000)
            max_seconds = max(max_seconds, 90.0)
        elif chars > 18000:
            chunk_limit = max(chunk_limit, 17000)
        elif chars < 8000:
            chunk_limit = min(chunk_limit, 12000)

        recent_failures = sum(1 for entry in history if not entry.success)
        slow_runs = sum(1 for entry in history if entry.elapsed > 130 and entry.success)

        if recent_failures or self._edge_failure_streak:
            penalty = 1500 * max(recent_failures, self._edge_failure_streak)
            chunk_limit = max(9000, chunk_limit - penalty)
            max_seconds = max(55.0, min(max_seconds, 75.0))
            words_per_minute = min(words_per_minute, 165)
        elif slow_runs:
            chunk_limit = min(22000, chunk_limit + 2000)
            max_seconds = min(95.0, max_seconds + 5.0)
            words_per_minute = max(words_per_minute, 180)
        else:
            words_per_minute = max(words_per_minute, 170)

        chunk_limit = int(max(8000, min(chunk_limit, 23000)))
        max_seconds = float(max(45.0, min(max_seconds, 95.0)))
        words_per_minute = int(max(150, min(words_per_minute, 220)))

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


__all__ = ["AdaptiveSpeedController", "ChapterSpeedDecision"]
