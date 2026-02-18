#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Long-run stability smoke using repeated real conversions."""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import List

try:
    import psutil  # type: ignore
except Exception:  # pragma: no cover
    psutil = None

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from python_app.main import ConverterApplication, create_argument_parser  # noqa: E402


def _default_book() -> Path:
    sample = ROOT / "web/public/sample.epub"
    if sample.exists():
        return sample
    return ROOT / "python_app/tests/fixtures/epubs/sample_multilang.epub"


def _rss_mb() -> float:
    if psutil is None:
        return 0.0
    try:
        proc = psutil.Process()
        return float(proc.memory_info().rss) / (1024**2)
    except Exception:
        return 0.0


def _run_once(book: Path, output_dir: Path, engine: str) -> int:
    parser = create_argument_parser()
    argv: List[str] = [
        "convert",
        str(book),
        "--engine",
        engine,
        "--chapter",
        "1",
        "--no-parallel",
        "--force-reprocess",
        "--no-validate-text",
        "--no-validate-audio",
        "--output-dir",
        str(output_dir),
    ]
    args = parser.parse_args(argv)
    app = ConverterApplication(ui_language=getattr(args, "ui_language", None))
    return int(app.run(args))


def main() -> int:
    parser = argparse.ArgumentParser(description="Long stability smoke for repeated conversions")
    parser.add_argument("--book", type=Path, default=_default_book())
    parser.add_argument("--engine", default="edge")
    parser.add_argument("--loops", type=int, default=3)
    parser.add_argument("--max-failures", type=int, default=1)
    parser.add_argument("--max-mem-growth-mb", type=float, default=700.0)
    args = parser.parse_args()

    book = Path(args.book).expanduser()
    if not book.exists():
        print(f"Book not found: {book}")
        return 2

    os.environ.setdefault("R2_OPTIONAL", "true")
    os.environ.setdefault("EDGE_MAX_CONCURRENCY", "1")
    os.environ.setdefault("EDGE_ENABLE_PARALLEL", "false")
    os.environ.setdefault("EDGE_AUTO_TUNE", "false")
    os.environ.setdefault("CHAPTER_PARALLEL_COUNT", "1")

    loops = max(1, int(args.loops or 3))
    failures = 0
    durations: List[float] = []
    mem_start = _rss_mb()

    with tempfile.TemporaryDirectory(prefix="long-stability-") as tmp:
        tmp_dir = Path(tmp)
        for i in range(1, loops + 1):
            run_dir = tmp_dir / f"run_{i}"
            start = time.time()
            code = _run_once(book, run_dir, str(args.engine))
            elapsed = max(0.001, time.time() - start)
            durations.append(elapsed)
            if code != 0:
                failures += 1
            print(f"[{i}/{loops}] exit={code} elapsed={elapsed:.2f}s")

    mem_end = _rss_mb()
    growth = max(0.0, mem_end - mem_start)
    avg = sum(durations) / max(1, len(durations))
    print(
        f"Summary: loops={loops} failures={failures} avg={avg:.2f}s "
        f"mem_growth={growth:.1f}MB (start={mem_start:.1f} end={mem_end:.1f})"
    )

    if failures > int(args.max_failures or 0):
        print("FAIL: too many conversion failures")
        return 1
    if growth > float(args.max_mem_growth_mb or 700.0):
        print("FAIL: memory growth above threshold")
        return 1
    print("PASS: long stability smoke")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
