#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Run a real TTS benchmark (short/medium/long) and persist machine baseline."""

from __future__ import annotations

import argparse
import asyncio
import json
import platform
import socket
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, List

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from python_app.src.config import ConversionConfig  # noqa: E402
from python_app.src.converter import AudioConverter  # noqa: E402
from python_app.src.ebook_reader import Chapter, EbookReader  # noqa: E402
from python_app.src.paths import TELEMETRY_DIR  # noqa: E402


@dataclass
class EngineRun:
    engine: str
    chapter_bucket: str
    chars: int
    elapsed_s: float
    chars_per_second: float
    success: bool
    error: str = ""


def _pick_buckets(chapters: List[Chapter]) -> Dict[str, Chapter]:
    enriched = [
        (chapter, len(getattr(chapter, "speech_text", None) or chapter.text or ""))
        for chapter in chapters
    ]
    enriched = [(chapter, chars) for chapter, chars in enriched if chars > 0]
    if not enriched:
        return {}
    enriched.sort(key=lambda item: item[1])
    short = enriched[0][0]
    long_ch = enriched[-1][0]
    medium = enriched[len(enriched) // 2][0]
    return {"short": short, "medium": medium, "long": long_ch}


async def _benchmark_engine(book_path: Path, engine_name: str) -> List[EngineRun]:
    reader = EbookReader(str(book_path))
    chapters = list(reader.get_chapter_structure(preserve_all=True) or [])
    buckets = _pick_buckets(chapters)
    if not buckets:
        return [
            EngineRun(
                engine=engine_name,
                chapter_bucket="none",
                chars=0,
                elapsed_s=0.0,
                chars_per_second=0.0,
                success=False,
                error="book has no readable chapters",
            )
        ]

    converter = AudioConverter()
    runs: List[EngineRun] = []

    with tempfile.TemporaryDirectory() as temp_root:
        for bucket, chapter in buckets.items():
            cfg = ConversionConfig(
                engine=engine_name,
                output_dir=Path(temp_root) / engine_name / bucket,
                cache_dir=Path(temp_root) / "cache" / engine_name / bucket,
                validate_audio=False,
                validate_text=False,
                force_reprocess=True,
                book_title=f"Benchmark {engine_name}",
            )
            text = getattr(chapter, "speech_text", None) or chapter.text or ""
            chars = len(text)
            start = time.time()
            try:
                tts_engine = converter.tts_factory.create_engine(cfg)
                result = await converter._convert_chapters_sequential(  # pylint: disable=protected-access
                    [chapter],
                    tts_engine,
                    Path(temp_root) / engine_name / bucket,
                    cfg,
                )
                elapsed = max(time.time() - start, 0.001)
                success = bool(result.success)
                runs.append(
                    EngineRun(
                        engine=engine_name,
                        chapter_bucket=bucket,
                        chars=chars,
                        elapsed_s=elapsed,
                        chars_per_second=(chars / elapsed) if success and chars > 0 else 0.0,
                        success=success,
                        error="; ".join(result.errors[:1]) if result.errors else "",
                    )
                )
            except Exception as exc:  # noqa: BLE001
                elapsed = max(time.time() - start, 0.001)
                runs.append(
                    EngineRun(
                        engine=engine_name,
                        chapter_bucket=bucket,
                        chars=chars,
                        elapsed_s=elapsed,
                        chars_per_second=0.0,
                        success=False,
                        error=str(exc),
                    )
                )
    return runs


def _default_book() -> Path:
    candidate = Path("python_app/tests/fixtures/epubs/sample_multilang.epub")
    if candidate.exists():
        return candidate
    return Path("web/public/sample.epub")


def _hostname_slug() -> str:
    host = socket.gethostname() or platform.node() or "machine"
    return "".join(ch if ch.isalnum() or ch in {"-", "_"} else "_" for ch in host.lower())[:64]


async def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run real engine benchmark and save machine baseline"
    )
    parser.add_argument(
        "--book",
        type=Path,
        default=_default_book(),
        help="EPUB/PDF input used for real benchmark",
    )
    parser.add_argument(
        "--engines",
        default="edge,piper,coqui",
        help="Comma-separated engines to benchmark",
    )
    parser.add_argument(
        "--engine-timeout-seconds",
        type=float,
        default=120.0,
        help="Hard timeout per engine benchmark (seconds)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output JSON report path (default: .cache/telemetry/real-engine-benchmark-<host>.json)",
    )
    args = parser.parse_args()

    book = Path(args.book).expanduser()
    if not book.exists():
        print(f"❌ Book not found: {book}")
        return 1

    engines = [item.strip().lower() for item in str(args.engines).split(",") if item.strip()]
    if not engines:
        print("❌ No engines selected")
        return 1

    host = _hostname_slug()
    output_path = args.output or (TELEMETRY_DIR / f"real-engine-benchmark-{host}.json")
    baseline_path = TELEMETRY_DIR / f"real-engine-baseline-{host}.json"

    all_runs: List[EngineRun] = []
    started_at = time.time()
    for engine in engines:
        print(f"🔍 Benchmarking {engine}...")
        try:
            runs = await asyncio.wait_for(
                _benchmark_engine(book, engine),
                timeout=max(10.0, float(args.engine_timeout_seconds or 120.0)),
            )
        except asyncio.TimeoutError:
            runs = [
                EngineRun(
                    engine=engine,
                    chapter_bucket="timeout",
                    chars=0,
                    elapsed_s=max(10.0, float(args.engine_timeout_seconds or 120.0)),
                    chars_per_second=0.0,
                    success=False,
                    error=f"engine benchmark timeout after {float(args.engine_timeout_seconds or 120.0):.0f}s",
                )
            ]
        all_runs.extend(runs)

    summary: Dict[str, Dict[str, float]] = {}
    for engine in engines:
        items = [run for run in all_runs if run.engine == engine and run.success]
        if not items:
            summary[engine] = {"avg_chars_per_second": 0.0, "success_rate": 0.0}
            continue
        avg_cps = sum(run.chars_per_second for run in items) / len(items)
        success_rate = len(items) / max(1, len([run for run in all_runs if run.engine == engine]))
        summary[engine] = {
            "avg_chars_per_second": round(avg_cps, 3),
            "success_rate": round(success_rate, 3),
        }

    payload = {
        "generated_at": time.time(),
        "duration_s": round(time.time() - started_at, 3),
        "machine": {
            "hostname": socket.gethostname(),
            "platform": platform.platform(),
            "python": platform.python_version(),
        },
        "book": str(book),
        "engines": engines,
        "runs": [asdict(run) for run in all_runs],
        "summary": summary,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    baseline_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"✅ Report: {output_path}")
    print(f"💾 Machine baseline: {baseline_path}")
    for engine in engines:
        data = summary.get(engine, {})
        print(
            f"   {engine}: avg {float(data.get('avg_chars_per_second', 0.0) or 0.0):.1f} chars/s | "
            f"success {float(data.get('success_rate', 0.0) or 0.0) * 100:.0f}%"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
