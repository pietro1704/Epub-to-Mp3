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

from src.ci_speed_benchmark import (  # noqa: E402
    baseline_is_stale,
    check_per_item_regression,
    check_regression,
    check_regression_vs_baseline,
    load_baseline,
    run_ci_speed_benchmark,
    save_baseline,
)


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
    parser.add_argument(
        "--min-item-cps",
        type=float,
        default=0.0,
        help="Fail with exit code 4 if any individual item (short/medium/long) "
        "is below this threshold. Tighter signal than --min-avg-cps.",
    )
    parser.add_argument(
        "--baseline-file",
        type=Path,
        default=Path(".cache/telemetry/ci-speed-baseline.json"),
        help="Baseline JSON used for periodic regression checks",
    )
    parser.add_argument(
        "--max-regression-pct",
        type=float,
        default=12.0,
        help="Fail with exit code 3 if performance regresses more than this percent vs baseline",
    )
    parser.add_argument(
        "--period-hours",
        type=float,
        default=24.0,
        help="Baseline refresh period in hours (<=0 disables staleness check)",
    )
    parser.add_argument(
        "--update-baseline",
        action="store_true",
        help="Force update baseline with current benchmark result",
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
    ok_items, items_message = check_per_item_regression(payload, args.min_item_cps)
    if args.min_item_cps > 0:
        if ok_items:
            print(f"✅ Per-item check: {items_message}")
        else:
            print(f"❌ Per-item check: {items_message}")
            return 4
    baseline = load_baseline(args.baseline_file)
    baseline_stale = baseline_is_stale(baseline, period_hours=args.period_hours)
    if args.update_baseline or baseline_stale:
        saved = save_baseline(payload, args.baseline_file)
        why = "forced" if args.update_baseline else "periodic refresh"
        print(f"💾 Baseline updated ({why}): {saved}")
        baseline = load_baseline(args.baseline_file)
    ok_baseline, baseline_msg = check_regression_vs_baseline(
        payload,
        baseline,
        max_regression_pct=args.max_regression_pct,
    )
    if ok_baseline:
        print(f"✅ Baseline check: {baseline_msg}")
    else:
        print(f"❌ Baseline check: {baseline_msg}")
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
