"""Benchmark result identity, persistence and aggregate reports."""

from __future__ import annotations

import hashlib
import json
import statistics
from pathlib import Path
from typing import Dict, List


def _scenario_id(payload: Dict[str, object]) -> str:
    digest = hashlib.sha1(json.dumps(payload, sort_keys=True).encode("utf-8")).hexdigest()
    return digest[:12]


def _write_json(path: Path, data: object) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")


def _load_existing_results(path: Path) -> Dict[str, Dict[str, object]]:
    results: Dict[str, Dict[str, object]] = {}
    if not path.exists():
        return results
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        run_id = str(payload.get("run_id") or "")
        if run_id:
            results[run_id] = payload
    return results


def _summarize_results(runs: List[Dict[str, object]]) -> Dict[str, object]:
    per_engine: Dict[str, List[Dict[str, object]]] = {}
    for run in runs:
        engine = str(run.get("engine") or "unknown")
        per_engine.setdefault(engine, []).append(run)

    best_by_engine: Dict[str, Dict[str, object]] = {}
    aggregates: List[Dict[str, object]] = []

    for engine, engine_runs in per_engine.items():
        scenario_groups: Dict[str, List[Dict[str, object]]] = {}
        for run in engine_runs:
            scenario_key = _scenario_id(
                {
                    "engine": run.get("engine"),
                    "chapter_parallel": run.get("chapter_parallel"),
                    "edge_enable_parallel": run.get("edge_enable_parallel"),
                    "edge_max_concurrency": run.get("edge_max_concurrency"),
                    "edge_chunk_chars": run.get("edge_chunk_chars"),
                    "edge_max_segment_seconds": run.get("edge_max_segment_seconds"),
                    "coqui_max_workers": run.get("coqui_max_workers"),
                    "piper_max_procs": run.get("piper_max_procs"),
                    "network_profile": run.get("network_profile"),
                }
            )
            scenario_groups.setdefault(scenario_key, []).append(run)

        engine_aggregates: List[Dict[str, object]] = []
        for scenario_key, group in scenario_groups.items():
            successful = [item for item in group if item.get("success")]
            speeds = [float(item.get("chars_per_second") or 0.0) for item in successful]
            avg_speed = statistics.mean(speeds) if speeds else 0.0
            stdev_speed = statistics.pstdev(speeds) if len(speeds) > 1 else 0.0
            sample = group[0]
            entry = {
                "engine": engine,
                "scenario_key": scenario_key,
                "avg_chars_per_second": avg_speed,
                "stdev_chars_per_second": stdev_speed,
                "runs": len(group),
                "success_rate": (len(successful) / len(group)) if group else 0.0,
                "chapter_parallel": sample.get("chapter_parallel"),
                "edge_enable_parallel": sample.get("edge_enable_parallel"),
                "edge_max_concurrency": sample.get("edge_max_concurrency"),
                "edge_chunk_chars": sample.get("edge_chunk_chars"),
                "edge_max_segment_seconds": sample.get("edge_max_segment_seconds"),
                "coqui_max_workers": sample.get("coqui_max_workers"),
                "piper_max_procs": sample.get("piper_max_procs"),
                "network_profile": sample.get("network_profile"),
            }
            aggregates.append(entry)
            engine_aggregates.append(entry)

        best = max(engine_aggregates, key=lambda item: item["avg_chars_per_second"], default=None)
        if best:
            best_by_engine[engine] = best

    return {
        "best_by_engine": best_by_engine,
        "aggregates": aggregates,
    }


def _write_csv(path: Path, summary: Dict[str, object]) -> None:
    rows = summary.get("aggregates") or []
    if not rows:
        return
    header = [
        "engine",
        "avg_chars_per_second",
        "stdev_chars_per_second",
        "runs",
        "success_rate",
        "chapter_parallel",
        "edge_enable_parallel",
        "edge_max_concurrency",
        "edge_chunk_chars",
        "edge_max_segment_seconds",
        "coqui_max_workers",
        "piper_max_procs",
        "network_profile",
        "scenario_key",
    ]
    lines = [",".join(header)]
    for row in rows:
        line = ",".join(str(row.get(key, "")) for key in header)
        lines.append(line)
    path.write_text("\n".join(lines), encoding="utf-8")
