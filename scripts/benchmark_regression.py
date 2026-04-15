#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Regression gate for TTS telemetry throughput.

Compares `TelemetryRecorder.summary()` (or an arbitrary JSON payload with the
same shape) against `benchmarks/baseline.json`. Fails (exit 1) when any engine
with enough samples falls below its baseline minus tolerance; warns but passes
(exit 0) when samples are insufficient.

Usage:
    python scripts/benchmark_regression.py                    # use live telemetry
    python scripts/benchmark_regression.py --report file.json # use specific file
    python scripts/benchmark_regression.py --baseline custom.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

PROJECT_ROOT = Path(__file__).resolve().parent.parent


def load_baseline(path: Path) -> Dict:
    if not path.exists():
        raise FileNotFoundError(f"Baseline file not found: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("Baseline JSON root must be an object")
    engines = payload.get("engines")
    if not isinstance(engines, dict) or not engines:
        raise ValueError("Baseline JSON must contain a non-empty 'engines' map")
    return payload


def load_summary(report_path: Optional[Path]) -> Dict[str, Dict[str, float]]:
    if report_path is not None:
        if not report_path.exists():
            raise FileNotFoundError(f"Report file not found: {report_path}")
        payload = json.loads(report_path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("Report JSON root must be an object")
        return payload  # already a summary

    sys.path.insert(0, str(PROJECT_ROOT))
    from python_app.src.telemetry import TelemetryRecorder  # noqa: E402

    return TelemetryRecorder().summary()


def evaluate(
    baseline: Dict,
    summary: Dict[str, Dict[str, float]],
) -> Tuple[List[str], List[str], List[str]]:
    """Return (failures, warnings, passes) as lists of human-readable lines."""
    failures: List[str] = []
    warnings: List[str] = []
    passes: List[str] = []

    default_min_samples = int(baseline.get("min_samples", 3))
    default_tolerance = float(baseline.get("tolerance_pct", 15.0))

    for engine_name, cfg in baseline.get("engines", {}).items():
        if not isinstance(cfg, dict):
            continue
        target = float(cfg.get("min_chars_per_second", 0.0) or 0.0)
        if target <= 0:
            continue
        min_samples = int(cfg.get("min_samples", default_min_samples))
        tolerance = float(cfg.get("tolerance_pct", default_tolerance))
        floor = target * (1.0 - tolerance / 100.0)

        stats = summary.get(engine_name)
        if not stats:
            warnings.append(f"{engine_name}: no telemetry samples (target ≥ {target:.1f} c/s)")
            continue

        sample_count = int(stats.get("samples", 0) or 0)
        avg = float(stats.get("avg_chars_per_second", 0.0) or 0.0)

        if sample_count < min_samples:
            warnings.append(
                f"{engine_name}: only {sample_count} samples "
                f"(need ≥ {min_samples}); avg {avg:.1f} c/s"
            )
            continue

        if avg < floor:
            failures.append(
                f"{engine_name}: avg {avg:.1f} c/s below floor "
                f"{floor:.1f} c/s (target {target:.1f}, tolerance {tolerance:.0f}%)"
            )
        else:
            passes.append(
                f"{engine_name}: avg {avg:.1f} c/s ≥ floor {floor:.1f} c/s "
                f"({sample_count} samples)"
            )

    return failures, warnings, passes


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Fail when TTS telemetry throughput regresses below baseline."
    )
    parser.add_argument(
        "--baseline",
        type=Path,
        default=PROJECT_ROOT / "benchmarks" / "baseline.json",
        help="Path to baseline JSON (default: benchmarks/baseline.json)",
    )
    parser.add_argument(
        "--report",
        type=Path,
        default=None,
        help="JSON file with summary-shaped data (default: live TelemetryRecorder.summary())",
    )
    parser.add_argument(
        "--warnings-as-errors",
        action="store_true",
        help="Treat insufficient samples as failures",
    )
    args = parser.parse_args(argv)

    try:
        baseline = load_baseline(args.baseline)
        summary = load_summary(args.report)
    except (FileNotFoundError, ValueError, json.JSONDecodeError) as exc:
        print(f"benchmark_regression: {exc}", file=sys.stderr)
        return 2

    failures, warnings, passes = evaluate(baseline, summary)

    for line in passes:
        print(f"PASS  {line}")
    for line in warnings:
        print(f"WARN  {line}")
    for line in failures:
        print(f"FAIL  {line}")

    if failures:
        print(f"\nbenchmark_regression: FAIL ({len(failures)} engine(s) regressed)")
        return 1
    if args.warnings_as_errors and warnings:
        print(f"\nbenchmark_regression: FAIL ({len(warnings)} warnings as errors)")
        return 1
    print(f"\nbenchmark_regression: OK " f"({len(passes)} pass, {len(warnings)} warn, 0 fail)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
