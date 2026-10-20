#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fail when A/B benchmark indicates unacceptable regression."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path


def _finite_number(value: object) -> bool:
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _invalid(reason: str) -> int:
    print(f"A/B regression check: INVALID ({reason})", file=sys.stderr)
    return 2


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate A/B benchmark regression thresholds")
    parser.add_argument("--report", required=True, help="JSON report from benchmark_feature_ab.py")
    parser.add_argument(
        "--max-stage-loss-pct",
        type=float,
        default=25.0,
        help="Maximum allowed loss of stage_pipeline vs baseline (percent)",
    )
    parser.add_argument(
        "--max-pool-loss-pct",
        type=float,
        default=35.0,
        help="Maximum allowed loss of external worker pool vs stage pipeline (percent)",
    )
    args = parser.parse_args()

    if not all(math.isfinite(value) for value in (args.max_stage_loss_pct, args.max_pool_loss_pct)):
        return _invalid("loss thresholds must be finite")

    report = Path(args.report).expanduser()
    try:
        payload = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return _invalid("report cannot be read as JSON")
    if not isinstance(payload, dict) or not isinstance(payload.get("results"), dict):
        return _invalid("results must be an object")

    for name in ("baseline_no_stage", "stage_pipeline", "external_worker_pool"):
        result = payload["results"].get(name)
        if not isinstance(result, dict):
            return _invalid(f"missing result: {name}")
        if result.get("success") is not True or type(result.get("exit_code")) is not int or result["exit_code"] != 0:
            return _invalid(f"unsuccessful result: {name}")
        elapsed = result.get("elapsed_s")
        if not _finite_number(elapsed) or elapsed <= 0:
            return _invalid(f"invalid elapsed time: {name}")

    comp = payload.get("comparisons")
    if not isinstance(comp, dict):
        return _invalid("comparisons must be an object")
    for name in ("stage_vs_baseline_gain_pct", "pool_vs_stage_gain_pct"):
        if not _finite_number(comp.get(name)):
            return _invalid(f"missing or invalid comparison: {name}")
    stage_gain = float(comp["stage_vs_baseline_gain_pct"])
    pool_gain = float(comp["pool_vs_stage_gain_pct"])

    max_stage_loss = -abs(float(args.max_stage_loss_pct))
    max_pool_loss = -abs(float(args.max_pool_loss_pct))

    ok_stage = stage_gain >= max_stage_loss
    ok_pool = pool_gain >= max_pool_loss

    print(f"stage_vs_baseline_gain_pct={stage_gain:.2f} (limit >= {max_stage_loss:.2f})")
    print(f"pool_vs_stage_gain_pct={pool_gain:.2f} (limit >= {max_pool_loss:.2f})")

    if ok_stage and ok_pool:
        print("A/B regression check: PASS")
        return 0
    print("A/B regression check: FAIL")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
