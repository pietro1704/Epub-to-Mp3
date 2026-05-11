# -*- coding: utf-8 -*-
"""Lightweight CI speed benchmark (short/medium/long chapters)."""

from __future__ import annotations

import asyncio
import json
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, List, Optional

from .config import ConversionConfig
from .converter import AudioConverter
from .ebook_reader import Chapter
from .paths import TELEMETRY_DIR


@dataclass
class BenchmarkItem:
    size: str
    chars: int
    elapsed_s: float
    chars_per_second: float
    success: bool
    engine: str = "edge"


# Archetype profiles used by the per-engine benchmark. Values are intentionally
# coarse: they model the relative cps ordering we expect in production so a
# regression that destroys the gap between engines (e.g. Edge suddenly serving
# at Piper speeds) still trips the gate. Real engine latency is measured in
# separate integration benchmarks, not here.
ENGINE_PROFILES: Dict[str, float] = {
    "edge": 450.0,
    "piper": 110.0,
}


def _make_text(chars_target: int) -> str:
    base = "benchmark text "
    repeats = max(1, chars_target // len(base))
    text = (base * repeats).strip()
    if len(text) < chars_target:
        text += "x" * (chars_target - len(text))
    return text


class _MockBenchmarkEngine:
    """Synthetic engine with deterministic latency profile."""

    def __init__(self, cps: float = 450.0):
        self._cps = max(50.0, float(cps))
        self.last_error = None
        self.partial_failure_detected = False

    async def synthesize_async(self, text, output_path, formatting_segments=None):
        delay = max(0.02, len(text or "") / self._cps)
        await asyncio.sleep(delay)
        target = Path(output_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        size_bytes = max(120_000, len(text or "") * 80)
        target.write_bytes(b"a" * size_bytes)
        return target


async def run_per_engine_benchmark(
    *,
    output_path: Optional[Path] = None,
    engines: Optional[Dict[str, float]] = None,
) -> Dict[str, object]:
    """Run the CI benchmark across multiple synthetic engine profiles.

    Each (engine, size) pair is emitted as a separate benchmark item so the
    per-item gate (``--min-item-cps``) and downstream analyzers can detect a
    regression isolated to a single engine archetype (for example Edge
    collapsing to Piper's throughput profile).
    """
    profiles = dict(engines or ENGINE_PROFILES)
    combined_items: List[Dict[str, object]] = []
    per_engine_avg: Dict[str, float] = {}
    for engine_name, cps_target in profiles.items():
        single = await run_ci_speed_benchmark(
            output_path=None,
            cps=cps_target,
            engine_label=engine_name,
        )
        for raw in single.get("items", []) or []:
            if isinstance(raw, dict):
                raw.setdefault("engine", engine_name)
                combined_items.append(raw)
        per_engine_avg[engine_name] = float(single.get("avg_chars_per_second", 0.0) or 0.0)

    overall_avg = (
        sum(per_engine_avg.values()) / max(len(per_engine_avg), 1) if per_engine_avg else 0.0
    )
    payload: Dict[str, object] = {
        "generated_at": time.time(),
        "items": combined_items,
        "avg_chars_per_second": overall_avg,
        "per_engine_avg_chars_per_second": per_engine_avg,
    }
    if output_path is not None:
        out = Path(output_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return payload


async def run_ci_speed_benchmark(
    *,
    output_path: Optional[Path] = None,
    cps: float = 450.0,
    engine_label: str = "edge",
) -> Dict[str, object]:
    converter = AudioConverter()

    async def _convert_to_mp3_stub(input_file, output_file, bitrate="8k"):
        out = Path(output_file)
        out.parent.mkdir(parents=True, exist_ok=True)
        src = Path(input_file)
        if src.exists():
            out.write_bytes(src.read_bytes())
        else:
            out.write_bytes(b"m" * 120_000)
        return out

    converter.audio_processor.convert_to_mp3 = _convert_to_mp3_stub
    engine = _MockBenchmarkEngine(cps=cps)

    sizes = {
        "short": 4_000,
        "medium": 16_000,
        "long": 48_000,
    }
    items: List[BenchmarkItem] = []

    with tempfile.TemporaryDirectory() as temp_root:
        base = Path(temp_root)
        for label, chars in sizes.items():
            chapter = Chapter(
                index=1,
                name=f"Benchmark {label}",
                source_path=f"{label}.html",
                text=_make_text(chars),
            )
            config = ConversionConfig(
                engine="edge",
                output_dir=base / label,
                validate_audio=False,
                validate_text=False,
                book_title=f"Benchmark {label}",
                force_reprocess=True,
            )
            start = time.time()
            result = await converter._convert_chapters_sequential(
                [chapter],
                engine,
                base / label,
                config,
            )
            elapsed = max(time.time() - start, 0.001)
            item = BenchmarkItem(
                size=label,
                chars=chars,
                elapsed_s=elapsed,
                chars_per_second=chars / elapsed,
                success=bool(result.success),
                engine=engine_label,
            )
            items.append(item)

    payload: Dict[str, object] = {
        "generated_at": time.time(),
        "items": [asdict(item) for item in items],
        "avg_chars_per_second": sum(item.chars_per_second for item in items) / max(len(items), 1),
    }
    if output_path is not None:
        out = Path(output_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return payload


def check_regression(payload: Dict[str, object], min_avg_cps: float) -> tuple[bool, str]:
    """Return (ok, message) based on average chars/s threshold."""
    threshold = float(min_avg_cps or 0.0)
    avg_cps = float(payload.get("avg_chars_per_second", 0.0) or 0.0)
    if threshold <= 0:
        return True, "no threshold configured"
    if avg_cps >= threshold:
        return True, f"avg chars/s {avg_cps:.1f} >= threshold {threshold:.1f}"
    return False, f"avg chars/s {avg_cps:.1f} < threshold {threshold:.1f}"


def check_per_engine_regression(
    payload: Dict[str, object], min_cps_by_engine: Dict[str, float]
) -> tuple[bool, str]:
    """Return (ok, message) for per-engine average chars/s floors.

    ``min_cps_by_engine`` maps engine label → minimum avg cps. Engines not
    present in the payload are ignored; thresholds of 0 are skipped.
    """
    if not min_cps_by_engine:
        return True, "no per-engine threshold configured"
    per_engine = payload.get("per_engine_avg_chars_per_second") or {}
    if not isinstance(per_engine, dict):
        return True, "no per-engine data in payload"
    offenders: list[str] = []
    for engine, threshold in min_cps_by_engine.items():
        if not threshold or float(threshold) <= 0:
            continue
        observed = float(per_engine.get(engine, 0.0) or 0.0)
        if observed and observed < float(threshold):
            offenders.append(f"{engine}={observed:.1f}<{float(threshold):.1f}")
    if offenders:
        return False, f"engines below floor: {', '.join(offenders)}"
    return True, "all engines above floors"


def check_per_item_regression(payload: Dict[str, object], min_item_cps: float) -> tuple[bool, str]:
    """Return (ok, message) based on per-item chars/s floor.

    Fails when any individual benchmark item (short/medium/long) drops below
    the configured floor. Catches regressions isolated to a single size class
    that an averaged gate would miss.
    """
    threshold = float(min_item_cps or 0.0)
    if threshold <= 0:
        return True, "no per-item threshold configured"
    items = payload.get("items", []) or []
    offenders: list[str] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        cps = float(item.get("chars_per_second", 0.0) or 0.0)
        if cps < threshold:
            offenders.append(f"{item.get('size', '?')}={cps:.1f}")
    if offenders:
        return False, f"items below {threshold:.1f} cps: {', '.join(offenders)}"
    return True, f"all items >= {threshold:.1f} cps"


def load_baseline(path: Optional[Path] = None) -> Optional[Dict[str, object]]:
    baseline_path = Path(path or (TELEMETRY_DIR / "ci-speed-baseline.json"))
    if not baseline_path.exists():
        return None
    try:
        payload = json.loads(baseline_path.read_text(encoding="utf-8"))
        if isinstance(payload, dict):
            return payload
    except Exception:
        return None
    return None


def save_baseline(payload: Dict[str, object], path: Optional[Path] = None) -> Path:
    baseline_path = Path(path or (TELEMETRY_DIR / "ci-speed-baseline.json"))
    baseline_path.parent.mkdir(parents=True, exist_ok=True)
    body = {
        "saved_at": time.time(),
        "avg_chars_per_second": float(payload.get("avg_chars_per_second", 0.0) or 0.0),
        "items": list(payload.get("items", []) or []),
    }
    baseline_path.write_text(json.dumps(body, ensure_ascii=False, indent=2), encoding="utf-8")
    return baseline_path


def baseline_is_stale(
    baseline: Optional[Dict[str, object]],
    *,
    period_hours: float,
) -> bool:
    if baseline is None:
        return True
    hours = float(period_hours or 0.0)
    if hours <= 0:
        return False
    saved_at = float(baseline.get("saved_at", 0.0) or 0.0)
    if saved_at <= 0:
        return True
    return (time.time() - saved_at) >= (hours * 3600.0)


def check_regression_vs_baseline(
    payload: Dict[str, object],
    baseline: Optional[Dict[str, object]],
    *,
    max_regression_pct: float,
) -> tuple[bool, str]:
    if baseline is None:
        return True, "no baseline configured"
    regression_pct = max(0.0, float(max_regression_pct or 0.0))
    baseline_avg = float(baseline.get("avg_chars_per_second", 0.0) or 0.0)
    current_avg = float(payload.get("avg_chars_per_second", 0.0) or 0.0)
    if baseline_avg <= 0:
        return True, "baseline avg chars/s is not set"
    floor = baseline_avg * (1.0 - (regression_pct / 100.0))
    if current_avg >= floor:
        return (
            True,
            f"avg chars/s {current_avg:.1f} within {regression_pct:.1f}% of baseline {baseline_avg:.1f}",
        )
    return (
        False,
        f"avg chars/s {current_avg:.1f} below baseline floor {floor:.1f} "
        f"({regression_pct:.1f}% from {baseline_avg:.1f})",
    )


__all__ = [
    "run_ci_speed_benchmark",
    "check_regression",
    "load_baseline",
    "save_baseline",
    "baseline_is_stale",
    "check_regression_vs_baseline",
]
