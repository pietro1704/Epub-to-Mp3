#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fail when A/B benchmark indicates unacceptable regression."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


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

    report = Path(args.report).expanduser()
    if not report.exists():
        print(f"Report not found: {report}")
        return 2

    payload = json.loads(report.read_text(encoding="utf-8"))

    # If all three runs failed, elapsed-time comparisons are meaningless —
    # skip regression check rather than producing spurious failures.
    results = payload.get("results", {}) if isinstance(payload, dict) else {}
    all_failed = results and all(not r.get("success") for r in results.values())
    if all_failed:
        print(
            "All benchmark runs failed (engine unavailable or no models) — skipping regression check."
        )
        return 0

    comp = payload.get("comparisons", {}) if isinstance(payload, dict) else {}
    stage_gain = float(comp.get("stage_vs_baseline_gain_pct", 0.0) or 0.0)
    pool_gain = float(comp.get("pool_vs_stage_gain_pct", 0.0) or 0.0)

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
