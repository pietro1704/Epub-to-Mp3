# -*- coding: utf-8 -*-
"""Lightweight telemetry to benchmark TTS engines.

v0.3.28: switched the hot path from full read+rewrite (sync, ``indent=2``)
to append-only JSONL with periodic compaction. ``record_sample`` now
appends a single line under a short-held lock; ``summary()`` reads both
the legacy JSON consolidation file and the JSONL tail, so older callers
keep working.
"""

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
    primary = cleaned.replace("_", "-").split("-", 1)[0]
    return primary or None


class TelemetryRecorder:
    """Append-only recorder that stores engine throughput stats in cache.

    The hot path is ``record_sample`` — we append one line per call to a
    JSONL sidecar instead of rewriting the entire JSON consolidation
    file. The expensive read+rewrite happens at most once every
    ``_compaction_interval_seconds`` (default 60s) or on ``flush()``.
    """

    _compaction_interval_seconds: float = 60.0

    def __init__(self, telemetry_file: Optional[Path] = None, max_samples: int = 400) -> None:
        self.telemetry_file = telemetry_file or (TELEMETRY_DIR / "engine_samples.json")
        self.telemetry_file.parent.mkdir(parents=True, exist_ok=True)
        # Sidecar JSONL — one line per sample, append-only.
        self.jsonl_file = self.telemetry_file.with_suffix(".jsonl")
        self.max_samples = max(50, max_samples)
        self._lock = threading.Lock()
        self._failure_timestamps: Dict[str, Deque[float]] = {}
        self._last_compaction_ts: float = 0.0

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
        encoded = json.dumps(asdict(sample), ensure_ascii=False, separators=(",", ":"))
        # Append-only fast path.
        with self._lock:
            try:
                with self.jsonl_file.open("a", encoding="utf-8") as fh:
                    fh.write(encoded)
                    fh.write("\n")
            except OSError:
                # Fall back to the consolidated JSON path on filesystem
                # errors (e.g. read-only mount) so we don't lose data.
                samples = self._load_samples_locked()
                samples.append(asdict(sample))
                self._write_consolidated_locked(samples[-self.max_samples :])
                return
            now = time.time()
            # Don't compact on the very first sample — initialize the
            # timestamp so the first compaction trigger fires
            # ``_compaction_interval_seconds`` from now, not immediately.
            if self._last_compaction_ts == 0.0:
                self._last_compaction_ts = now
                should_compact = False
            else:
                should_compact = now - self._last_compaction_ts >= self._compaction_interval_seconds
        if should_compact:
            self._maybe_compact()

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
        """Return aggregated stats grouped by ``(engine, language)``."""
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
        engine_key = (engine or "").lower().strip()
        if not engine_key:
            return 0.0
        lang_key = _normalize_lang(language)
        if lang_key:
            by_lang = self.summary_by_language().get(engine_key) or {}
            stats = by_lang.get(lang_key)
            if stats and stats.get("avg_chars_per_second"):
                return float(stats["avg_chars_per_second"])
        stats = self.summary().get(engine_key) or {}
        return float(stats.get("avg_chars_per_second") or 0.0)

    def ranked_engines(self, language: Optional[str] = None) -> List[str]:
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
        normalized = (engine or "").lower().strip()
        if not normalized:
            return
        with self._lock:
            dq = self._failure_timestamps.setdefault(normalized, deque(maxlen=20))
            dq.append(time.time())

    def failure_count_recent(self, engine: str, window_seconds: int = 900) -> int:
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
        fails = self.failure_count_recent(engine, window_seconds=window_seconds)
        return max(0.10, 0.85**fails)

    def recent_samples(self, limit: int = 25) -> List[dict]:
        samples = self._load_samples()
        if limit <= 0:
            return samples
        return samples[-limit:]

    def flush(self) -> None:
        """Force a compaction pass: merge JSONL tail into the consolidated
        JSON file and truncate the JSONL. Call at server shutdown / job
        completion if you want a clean state on disk."""
        self._maybe_compact(force=True)

    def clear(self) -> None:
        with self._lock:
            for path in (self.telemetry_file, self.jsonl_file):
                try:
                    if path.exists():
                        path.unlink()
                except OSError:
                    pass
            self._last_compaction_ts = 0.0

    # -- Internals ------------------------------------------------------------

    def _read_consolidated(self) -> List[dict]:
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

    def _read_jsonl_tail(self) -> List[dict]:
        if not self.jsonl_file.exists():
            return []
        out: List[dict] = []
        try:
            with self.jsonl_file.open("r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(entry, dict):
                        out.append(entry)
        except OSError:
            return out
        return out

    def _load_samples(self) -> List[dict]:
        with self._lock:
            return self._load_samples_locked()

    def _load_samples_locked(self) -> List[dict]:
        merged = self._read_consolidated() + self._read_jsonl_tail()
        return merged[-self.max_samples :]

    def _write_consolidated_locked(self, samples: List[dict]) -> None:
        try:
            self.telemetry_file.write_text(
                json.dumps(samples, ensure_ascii=False, separators=(",", ":")),
                encoding="utf-8",
            )
        except Exception:
            pass

    def _maybe_compact(self, force: bool = False) -> None:
        with self._lock:
            now = time.time()
            if not force and (now - self._last_compaction_ts < self._compaction_interval_seconds):
                return
            tail = self._read_jsonl_tail()
            if not tail and not force:
                self._last_compaction_ts = now
                return
            merged = (self._read_consolidated() + tail)[-self.max_samples :]
            self._write_consolidated_locked(merged)
            try:
                # Truncate JSONL once its content has been folded into
                # the consolidated file.
                if self.jsonl_file.exists():
                    self.jsonl_file.write_text("", encoding="utf-8")
            except OSError:
                pass
            self._last_compaction_ts = now


__all__ = ["TelemetryRecorder", "EngineSample"]
