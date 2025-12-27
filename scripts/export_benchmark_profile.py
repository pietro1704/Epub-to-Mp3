#!/usr/bin/env python3
"""
Export best-performing benchmark profile from results.jsonl files.

Usage:
  python scripts/export_benchmark_profile.py output/benchmark_*/results.jsonl
  python scripts/export_benchmark_profile.py output/benchmark_* --output .cache/telemetry/benchmark_profiles.json
"""

from __future__ import annotations

import argparse
import json
import statistics
import time
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

FIELDS = (
    "engine",
    "chapter_parallel",
    "edge_enable_parallel",
    "edge_max_concurrency",
    "edge_chunk_chars",
    "edge_max_segment_seconds",
    "coqui_max_workers",
    "piper_max_procs",
    "network_profile",
)


def _collect_result_files(inputs: Iterable[str]) -> List[Path]:
    results: List[Path] = []
    for raw in inputs:
        path = Path(raw)
        if path.is_dir():
            candidates = list(path.rglob("results.jsonl"))
            results.extend(candidates)
            continue
        if path.is_file():
            if path.name == "results.jsonl":
                results.append(path)
            elif path.suffix.lower() == ".jsonl":
                results.append(path)
    return results


def _load_runs(paths: Iterable[Path]) -> List[dict]:
    runs: List[dict] = []
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                runs.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return runs


def _scenario_key(run: dict) -> Tuple[object, ...]:
    return tuple(run.get(field) for field in FIELDS)


def _pick_best_scenario(runs: List[dict], min_success: float) -> List[dict]:
    best_entries: List[dict] = []
    per_engine: Dict[str, List[dict]] = {}
    for run in runs:
        engine = str(run.get("engine") or "unknown")
        per_engine.setdefault(engine, []).append(run)

    for engine, engine_runs in per_engine.items():
        groups: Dict[Tuple[object, ...], List[dict]] = {}
        for run in engine_runs:
            groups.setdefault(_scenario_key(run), []).append(run)
        best = None
        for group in groups.values():
            successes = [item for item in group if item.get("success")]
            success_rate = len(successes) / len(group) if group else 0.0
            if successes:
                avg_speed = statistics.mean(
                    float(item.get("chars_per_second") or 0.0) for item in successes
                )
            else:
                avg_speed = 0.0
            if success_rate < min_success:
                continue
            sample = group[0]
            entry = {
                "engine": engine,
                "avg_speed": avg_speed,
                "success_rate": success_rate,
                "sample": sample,
            }
            if best is None:
                best = entry
                continue
            if entry["avg_speed"] > best["avg_speed"]:
                best = entry
                continue
            if (
                entry["avg_speed"] == best["avg_speed"]
                and entry["success_rate"] > best["success_rate"]
            ):
                best = entry
        if best:
            best_entries.append(best)
    return best_entries


def _build_profile(best_entries: List[dict]) -> dict:
    engines: Dict[str, dict] = {}
    for entry in best_entries:
        sample = entry["sample"]
        engine = str(sample.get("engine") or "").lower()
        if not engine:
            continue
        profile = {
            "chapter_parallel": sample.get("chapter_parallel"),
        }
        if engine == "edge":
            profile.update(
                {
                    "edge_enable_parallel": sample.get("edge_enable_parallel"),
                    "edge_max_concurrency": sample.get("edge_max_concurrency"),
                    "edge_chunk_chars": sample.get("edge_chunk_chars"),
                    "edge_max_segment_seconds": sample.get("edge_max_segment_seconds"),
                    "network_profile": sample.get("network_profile"),
                }
            )
        if engine == "coqui":
            profile["coqui_max_workers"] = sample.get("coqui_max_workers")
        if engine == "piper":
            profile["piper_max_procs"] = sample.get("piper_max_procs")
        engines[engine] = profile
    return {
        "version": 1,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "engines": engines,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Export best benchmark profile from results.jsonl files."
    )
    parser.add_argument("inputs", nargs="+", help="Benchmark result files or directories")
    parser.add_argument(
        "--output",
        default=str(Path(".cache/telemetry/benchmark_profiles.json")),
        help="Output JSON profile path",
    )
    parser.add_argument(
        "--min-success",
        type=float,
        default=0.5,
        help="Minimum success rate to consider a scenario",
    )
    args = parser.parse_args()

    results_files = _collect_result_files(args.inputs)
    if not results_files:
        print("No results.jsonl files found.")
        return 1

    runs = _load_runs(results_files)
    if not runs:
        print("No benchmark runs parsed.")
        return 1

    best_entries = _pick_best_scenario(runs, min_success=max(0.0, min(args.min_success, 1.0)))
    if not best_entries:
        print("No successful benchmark scenarios found.")
        return 1

    profile = _build_profile(best_entries)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(profile, indent=2, sort_keys=True), encoding="utf-8")
    print(f"Profile written to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
