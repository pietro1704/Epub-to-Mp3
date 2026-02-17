# -*- coding: utf-8 -*-
"""Run lightweight CI benchmark for short/medium/long chapters.

Usage:
  python python_app/tests/run_ci_speed_benchmark.py
  python python_app/tests/run_ci_speed_benchmark.py --output .cache/telemetry/ci-speed.json
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
from pathlib import Path

python_app_dir = os.path.join(os.path.dirname(__file__), "..")
repo_root = os.path.abspath(os.path.join(python_app_dir, ".."))
sys.path.insert(0, os.path.abspath(python_app_dir))
sys.path.insert(0, repo_root)

from src.ci_speed_benchmark import check_regression, run_ci_speed_benchmark  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Run CI speed benchmark")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(".cache/telemetry/ci-speed-benchmark.json"),
        help="Output JSON report path",
    )
    parser.add_argument(
        "--cps",
        type=float,
        default=450.0,
        help="Mock chars/second baseline",
    )
    parser.add_argument(
        "--min-avg-cps",
        type=float,
        default=0.0,
        help="Fail with exit code 2 if avg chars/s is below this threshold",
    )
    args = parser.parse_args()
    payload = asyncio.run(run_ci_speed_benchmark(output_path=args.output, cps=args.cps))
    print(f"✅ Benchmark complete: {args.output}")
    print(f"   avg chars/s: {payload.get('avg_chars_per_second', 0):.1f}")
    ok, message = check_regression(payload, args.min_avg_cps)
    if args.min_avg_cps > 0:
        if ok:
            print(f"✅ Regression check: {message}")
        else:
            print(f"❌ Regression check: {message}")
            return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
