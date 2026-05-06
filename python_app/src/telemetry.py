# -*- coding: utf-8 -*-
"""Lightweight telemetry to benchmark TTS engines."""

from __future__ import annotations

import json
import threading
import time
from collections import deque
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Deque, Dict, List, Optional

from .paths import TELEMETRY_DIR


@dataclass
class EngineSample:
    engine: str
    voice: Optional[str]
    chars: int
    synth_seconds: float
    total_seconds: float
    audio_seconds: Optional[float]
    job_id: Optional[str]
    chapter: Optional[str]
    timestamp: str
    language: Optional[str] = None


def _normalize_lang(value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    cleaned = str(value).strip().lower()
    if not cleaned or cleaned in {"auto", "unknown"}:
        return None
    # Normalize variants like "pt-BR" -> "pt", "en_US" -> "en". Keep only the
    # primary language tag — speed differences across regional variants are
    # negligible compared to differences across primary languages (pt vs en).
    primary = cleaned.replace("_", "-").split("-", 1)[0]
    return primary or None


class TelemetryRecorder:
    """Append-only recorder that stores engine throughput stats in cache."""

    def __init__(self, telemetry_file: Optional[Path] = None, max_samples: int = 400) -> None:
        self.telemetry_file = telemetry_file or (TELEMETRY_DIR / "engine_samples.json")
        self.telemetry_file.parent.mkdir(parents=True, exist_ok=True)
        self.max_samples = max(50, max_samples)
        self._lock = threading.Lock()
        # In-memory ring of recent per-engine failures (timestamps). Used to
        # penalise flaky engines in the server-side fallback ranking.
        self._failure_timestamps: Dict[str, Deque[float]] = {}

    def record_sample(
        self,
        *,
        engine: str,
        voice: Optional[str],
        chars: int,
        synth_seconds: float,
        total_seconds: float,
        audio_seconds: Optional[float],
        job_id: Optional[str],
        chapter: Optional[str],
        language: Optional[str] = None,
    ) -> None:
        if chars <= 0 or synth_seconds <= 0:
            return
        sample = EngineSample(
            engine=engine.lower(),
            voice=voice,
            chars=int(chars),
            synth_seconds=float(synth_seconds),
            total_seconds=max(float(total_seconds), float(synth_seconds)),
            audio_seconds=float(audio_seconds) if audio_seconds else None,
            job_id=job_id,
            chapter=chapter,
            timestamp=datetime.utcnow().isoformat(timespec="seconds") + "Z",
            language=_normalize_lang(language),
        )
        with self._lock:
            samples = self._load_samples()
            samples.append(asdict(sample))
            trimmed = samples[-self.max_samples :]
            self._write_samples(trimmed)

    def _aggregate(self, entries: List[dict]) -> Optional[Dict[str, float]]:
        total_chars = 0.0
        total_synth = 0.0
        best_speed = 0.0
        worst_speed: Optional[float] = None
        for entry in entries:
            chars = float(entry.get("chars") or 0)
            synth_seconds = float(entry.get("synth_seconds") or 0)
            if chars <= 0 or synth_seconds <= 0:
                continue
            total_chars += chars
            total_synth += synth_seconds
            throughput = chars / synth_seconds
            best_speed = max(best_speed, throughput)
            if worst_speed is None or throughput < worst_speed:
                worst_speed = throughput
        if total_chars <= 0 or total_synth <= 0:
            return None
        return {
            "samples": float(len(entries)),
            "avg_chars_per_second": total_chars / total_synth,
            "max_chars_per_second": best_speed,
            "min_chars_per_second": worst_speed or 0.0,
        }

    def summary(self) -> Dict[str, Dict[str, float]]:
        """Return aggregated throughput stats per engine (language-agnostic)."""
        stats: Dict[str, Dict[str, float]] = {}
        samples = self._load_samples()
        per_engine: Dict[str, List[dict]] = {}
        for entry in samples:
            engine = (entry.get("engine") or "").lower()
            if not engine:
                continue
            per_engine.setdefault(engine, []).append(entry)
        for engine, entries in per_engine.items():
            agg = self._aggregate(entries)
            if agg is not None:
                stats[engine] = agg
        return stats

    def summary_by_language(self) -> Dict[str, Dict[str, Dict[str, float]]]:
        """Return aggregated stats grouped by ``(engine, language)``.

        Shape: ``{engine: {lang: {avg_chars_per_second, ...}}}``. Samples
        without a recorded language are bucketed under ``"_any"``.
        """
        result: Dict[str, Dict[str, List[dict]]] = {}
        for entry in self._load_samples():
            engine = (entry.get("engine") or "").lower()
            if not engine:
                continue
            lang = _normalize_lang(entry.get("language")) or "_any"
            result.setdefault(engine, {}).setdefault(lang, []).append(entry)
        out: Dict[str, Dict[str, Dict[str, float]]] = {}
        for engine, by_lang in result.items():
            for lang, entries in by_lang.items():
                agg = self._aggregate(entries)
                if agg is None:
                    continue
                out.setdefault(engine, {})[lang] = agg
        return out

    def avg_speed_for(self, engine: str, language: Optional[str] = None) -> float:
        """Return ``avg_chars_per_second`` for an engine, optionally filtered
        by language. Falls back to the engine-wide average when no
        language-specific samples exist."""
        engine_key = (engine or "").lower().strip()
        if not engine_key:
            return 0.0
        lang_key = _normalize_lang(language)
        if lang_key:
            by_lang = self.summary_by_language().get(engine_key) or {}
            stats = by_lang.get(lang_key)
            if stats and stats.get("avg_chars_per_second"):
                return float(stats["avg_chars_per_second"])
            # Fall through to engine-wide aggregate.
        stats = self.summary().get(engine_key) or {}
        return float(stats.get("avg_chars_per_second") or 0.0)

    def ranked_engines(self, language: Optional[str] = None) -> List[str]:
        """Return engines ordered from fastest to slowest.

        When ``language`` is provided, ranking uses language-specific samples
        when available, falling back to the engine-wide average otherwise.
        """
        engine_summary = self.summary()
        if not engine_summary:
            return []
        scored: List[tuple] = []
        for engine in engine_summary:
            scored.append((engine, self.avg_speed_for(engine, language)))
        scored.sort(key=lambda item: item[1], reverse=True)
        return [engine for engine, _ in scored]

    # -- Failure tracking for reliability-weighted ranking --------------------

    def record_failure(self, engine: str) -> None:
        """Record a terminal engine failure (e.g. chapter timeout, engine
        marked unavailable for a job). Consumed by ``failure_count_recent``
        so the fallback ranking can penalise flaky engines."""
        normalized = (engine or "").lower().strip()
        if not normalized:
            return
        with self._lock:
            dq = self._failure_timestamps.setdefault(normalized, deque(maxlen=20))
            dq.append(time.time())

    def failure_count_recent(self, engine: str, window_seconds: int = 900) -> int:
        """Return how many failures the given engine has accumulated within
        the last ``window_seconds`` (default 15 min)."""
        normalized = (engine or "").lower().strip()
        if not normalized:
            return 0
        now = time.time()
        with self._lock:
            dq = self._failure_timestamps.get(normalized)
            if not dq:
                return 0
            return sum(1 for ts in dq if (now - ts) <= window_seconds)

    def reliability_factor(self, engine: str, window_seconds: int = 900) -> float:
        """Return a multiplier in (0, 1] for ranking. Each recent failure
        shaves 15% off, floored at 0.10 so the engine never fully vanishes
        from the chain (we still want it as last-resort retry fodder)."""
        fails = self.failure_count_recent(engine, window_seconds=window_seconds)
        return max(0.10, 0.85**fails)

    def recent_samples(self, limit: int = 25) -> List[dict]:
        samples = self._load_samples()
        if limit <= 0:
            return samples
        return samples[-limit:]

    def clear(self) -> None:
        with self._lock:
            try:
                if self.telemetry_file.exists():
                    self.telemetry_file.unlink()
            except OSError:
                pass

    def _load_samples(self) -> List[dict]:
        try:
            raw = self.telemetry_file.read_text(encoding="utf-8")
            data = json.loads(raw)
            if isinstance(data, list):
                return data
        except FileNotFoundError:
            return []
        except Exception:
            return []
        return []

    def _write_samples(self, samples: List[dict]) -> None:
        try:
            self.telemetry_file.write_text(
                json.dumps(samples, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except Exception:
            pass


__all__ = ["TelemetryRecorder", "EngineSample"]
