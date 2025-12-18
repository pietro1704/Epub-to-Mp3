# -*- coding: utf-8 -*-
"""Lightweight telemetry to benchmark TTS engines."""

from __future__ import annotations

import json
import threading
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

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


class TelemetryRecorder:
    """Append-only recorder that stores engine throughput stats in cache."""

    def __init__(self, telemetry_file: Optional[Path] = None, max_samples: int = 400) -> None:
        self.telemetry_file = telemetry_file or (TELEMETRY_DIR / "engine_samples.json")
        self.telemetry_file.parent.mkdir(parents=True, exist_ok=True)
        self.max_samples = max(50, max_samples)
        self._lock = threading.Lock()

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
        )
        with self._lock:
            samples = self._load_samples()
            samples.append(asdict(sample))
            trimmed = samples[-self.max_samples :]
            self._write_samples(trimmed)

    def summary(self) -> Dict[str, Dict[str, float]]:
        """Return aggregated throughput stats per engine."""
        stats: Dict[str, Dict[str, float]] = {}
        samples = self._load_samples()
        per_engine: Dict[str, List[dict]] = {}
        for entry in samples:
            engine = (entry.get("engine") or "").lower()
            if not engine:
                continue
            per_engine.setdefault(engine, []).append(entry)
        for engine, entries in per_engine.items():
            total_chars = 0.0
            total_synth = 0.0
            best_speed = 0.0
            worst_speed = None
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
                continue
            avg_speed = total_chars / total_synth
            stats[engine] = {
                "samples": len(entries),
                "avg_chars_per_second": avg_speed,
                "max_chars_per_second": best_speed,
                "min_chars_per_second": worst_speed or 0.0,
            }
        return stats

    def ranked_engines(self) -> List[str]:
        """Return engines ordered from fastest to slowest according to telemetry."""
        summary = self.summary()
        ranked = sorted(
            summary.items(),
            key=lambda item: item[1].get("avg_chars_per_second", 0.0),
            reverse=True,
        )
        return [engine for engine, _ in ranked]

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
