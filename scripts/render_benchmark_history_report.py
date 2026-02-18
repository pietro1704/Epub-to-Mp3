#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Render rolling benchmark history into a markdown report."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import List


def _safe_float(value, default: float = 0.0) -> float:
    try:
        return float(value)
    except Exception:
        return default


def _fmt_ts(ts: float) -> str:
    if ts <= 0:
        return "-"
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))


def main() -> int:
    parser = argparse.ArgumentParser(description="Render benchmark history markdown report")
    parser.add_argument("--history", required=True, help="History JSON path")
    parser.add_argument("--output", required=True, help="Markdown output path")
    parser.add_argument("--max-rows", type=int, default=12, help="Max table rows")
    args = parser.parse_args()

    history_path = Path(args.history).expanduser()
    output_path = Path(args.output).expanduser()
    if not history_path.exists():
        print(f"History file not found: {history_path}")
        return 2

    payload = json.loads(history_path.read_text(encoding="utf-8"))
    entries = payload.get("entries", []) if isinstance(payload, dict) else []
    if not isinstance(entries, list):
        entries = []
    entries = [item for item in entries if isinstance(item, dict)]

    rows = entries[: max(1, int(args.max_rows or 12))]
    stage_vals = [_safe_float(item.get("stage_vs_baseline_gain_pct"), 0.0) for item in rows]
    pool_vals = [_safe_float(item.get("pool_vs_stage_gain_pct"), 0.0) for item in rows]

    avg_stage = sum(stage_vals) / max(1, len(stage_vals))
    avg_pool = sum(pool_vals) / max(1, len(pool_vals))

    lines: List[str] = []
    lines.append("# Weekly Feature A/B History")
    lines.append("")
    lines.append(f"- Entries considered: {len(rows)}")
    lines.append(f"- Avg stage_vs_baseline_gain_pct: {avg_stage:.2f}%")
    lines.append(f"- Avg pool_vs_stage_gain_pct: {avg_pool:.2f}%")
    lines.append("")
    lines.append(
        "| Timestamp | Host | Engine | Stage vs Baseline | Pool vs Stage | Stage OK | Pool OK |"
    )
    lines.append("|---|---|---:|---:|---:|---:|---:|")
    for item in rows:
        ts = _fmt_ts(_safe_float(item.get("ts"), 0.0))
        host = str(item.get("hostname") or "-")
        engine = str(item.get("engine") or "-")
        stage = _safe_float(item.get("stage_vs_baseline_gain_pct"), 0.0)
        pool = _safe_float(item.get("pool_vs_stage_gain_pct"), 0.0)
        stage_ok = "yes" if bool(item.get("stage_success")) else "no"
        pool_ok = "yes" if bool(item.get("pool_success")) else "no"
        lines.append(
            f"| {ts} | {host} | {engine} | {stage:.2f}% | {pool:.2f}% | {stage_ok} | {pool_ok} |"
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Rendered report: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
