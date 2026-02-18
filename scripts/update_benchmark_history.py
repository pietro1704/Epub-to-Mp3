#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Append feature A/B benchmark reports to a rolling history JSON."""

from __future__ import annotations

import argparse
import json
import socket
import time
from pathlib import Path
from typing import Any, Dict


def _load_json(path: Path, default: Dict[str, Any]) -> Dict[str, Any]:
    if not path.exists():
        return dict(default)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    return dict(default)


def main() -> int:
    parser = argparse.ArgumentParser(description="Update rolling benchmark history")
    parser.add_argument("--report", required=True, help="Feature A/B benchmark report JSON path")
    parser.add_argument("--history", required=True, help="Rolling history JSON path")
    parser.add_argument("--max-entries", type=int, default=104, help="Max history entries")
    args = parser.parse_args()

    report_path = Path(args.report).expanduser()
    history_path = Path(args.history).expanduser()
    if not report_path.exists():
        print(f"Report not found: {report_path}")
        return 2

    report = json.loads(report_path.read_text(encoding="utf-8"))
    comparisons = report.get("comparisons", {}) if isinstance(report, dict) else {}
    entry = {
        "ts": float(report.get("generated_at", time.time()) or time.time()),
        "hostname": str(report.get("hostname") or socket.gethostname()),
        "book": str(report.get("book") or ""),
        "engine": str(report.get("engine") or ""),
        "stage_vs_baseline_gain_pct": float(
            comparisons.get("stage_vs_baseline_gain_pct", 0.0) or 0.0
        ),
        "pool_vs_stage_gain_pct": float(comparisons.get("pool_vs_stage_gain_pct", 0.0) or 0.0),
        "baseline_success": bool(
            ((report.get("results") or {}).get("baseline_no_stage") or {}).get("success", False)
        ),
        "stage_success": bool(
            ((report.get("results") or {}).get("stage_pipeline") or {}).get("success", False)
        ),
        "pool_success": bool(
            ((report.get("results") or {}).get("external_worker_pool") or {}).get("success", False)
        ),
    }

    history = _load_json(
        history_path,
        default={"updated_at": time.time(), "entries": []},
    )
    entries = history.get("entries", [])
    if not isinstance(entries, list):
        entries = []
    entries.append(entry)
    entries = sorted(
        [item for item in entries if isinstance(item, dict)],
        key=lambda item: float(item.get("ts", 0.0) or 0.0),
        reverse=True,
    )[: max(1, int(args.max_entries or 104))]
    history["updated_at"] = time.time()
    history["entries"] = entries
    history_path.parent.mkdir(parents=True, exist_ok=True)
    history_path.write_text(json.dumps(history, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"Updated benchmark history: {history_path}")
    print(f"Entries kept: {len(entries)}")
    if entries:
        latest = entries[0]
        print(
            "Latest: "
            f"stage_vs_baseline={float(latest.get('stage_vs_baseline_gain_pct', 0.0) or 0.0):.2f}% | "
            f"pool_vs_stage={float(latest.get('pool_vs_stage_gain_pct', 0.0) or 0.0):.2f}%"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
