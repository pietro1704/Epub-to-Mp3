#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Check rolling benchmark history for sustained performance regression."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Dict, List


def _safe_float(value, default: float = 0.0) -> float:
    try:
        return float(value)
    except Exception:
        return default


def _window_average(entries: List[Dict[str, object]], key: str) -> float:
    if not entries:
        return 0.0
    values = [_safe_float(item.get(key), 0.0) for item in entries]
    return sum(values) / max(1, len(values))


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate benchmark history trend")
    parser.add_argument("--history", required=True, help="History JSON path")
    parser.add_argument(
        "--recent-window",
        type=int,
        default=4,
        help="Recent entries window size",
    )
    parser.add_argument(
        "--baseline-window",
        type=int,
        default=12,
        help="Older entries window size for baseline",
    )
    parser.add_argument(
        "--max-drop-pct",
        type=float,
        default=20.0,
        help="Maximum allowed sustained drop percentage",
    )
    args = parser.parse_args()

    history_path = Path(args.history).expanduser()
    if not history_path.exists():
        print(f"History file not found: {history_path}")
        return 2

    payload = json.loads(history_path.read_text(encoding="utf-8"))
    entries = payload.get("entries", []) if isinstance(payload, dict) else []
    if not isinstance(entries, list):
        entries = []

    entries = [item for item in entries if isinstance(item, dict)]
    if len(entries) < max(args.recent_window + 1, 6):
        print("History trend check: not enough entries yet, skipping gate")
        return 0

    recent = entries[: max(1, int(args.recent_window or 4))]
    older_pool = entries[len(recent) : len(recent) + max(1, int(args.baseline_window or 12))]
    if len(older_pool) < 3:
        print("History trend check: not enough baseline entries, skipping gate")
        return 0

    metrics = [
        "stage_vs_baseline_gain_pct",
        "pool_vs_stage_gain_pct",
    ]
    violations = []
    max_drop = abs(float(args.max_drop_pct or 20.0))

    for metric in metrics:
        recent_avg = _window_average(recent, metric)
        baseline_avg = _window_average(older_pool, metric)
        if baseline_avg == 0:
            continue
        drop_pct = ((baseline_avg - recent_avg) / abs(baseline_avg)) * 100.0
        print(f"{metric}: recent={recent_avg:.2f} baseline={baseline_avg:.2f} drop={drop_pct:.2f}%")
        if drop_pct > max_drop:
            violations.append((metric, drop_pct, recent_avg, baseline_avg))

    if violations:
        print("History trend check: FAIL")
        for metric, drop_pct, recent_avg, baseline_avg in violations:
            print(
                f" - {metric}: drop {drop_pct:.2f}% (recent {recent_avg:.2f}, baseline {baseline_avg:.2f})"
            )
        return 1

    print("History trend check: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
