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


@dataclass
class BenchmarkItem:
    size: str
    chars: int
    elapsed_s: float
    chars_per_second: float
    success: bool


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


async def run_ci_speed_benchmark(
    *,
    output_path: Optional[Path] = None,
    cps: float = 450.0,
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


__all__ = ["run_ci_speed_benchmark", "check_regression"]
