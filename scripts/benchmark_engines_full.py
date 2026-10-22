#!/usr/bin/env python3
"""
Comprehensive TTS benchmark across engines, parallelism, and Edge network profiles.

This script runs a sweep of scenarios (edge/coqui/piper) and measures throughput
using real chapter text from an EPUB/PDF. It is intentionally long-running.

Usage:
  python scripts/benchmark_engines_full.py /path/to/book.epub
  python scripts/benchmark_engines_full.py /path/to/book.epub --repeat 2
  python scripts/benchmark_engines_full.py /path/to/book.epub --dry-run

The script spawns a worker process per scenario to ensure env-based settings
are applied cleanly (EDGE_MAX_CONCURRENCY, COQUI_MAX_WORKERS, etc).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import asdict
from pathlib import Path
from typing import Dict, List, Optional

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from scripts.tts_benchmark_worker import (  # noqa: E402
    _run_worker as _run_worker,
)
from scripts.tts_benchmark_reports import (  # noqa: E402
    _scenario_id as _scenario_id,
    _write_json as _write_json,
    _load_existing_results as _load_existing_results,
    _summarize_results as _summarize_results,
    _write_csv as _write_csv,
)
from scripts.tts_benchmark_network_profiles import (  # noqa: E402
    _probe_edge_latency as _probe_edge_latency,
    _classify_latency as _classify_latency,
    _dedupe_sorted as _dedupe_sorted,
    _default_chapter_parallel as _default_chapter_parallel,
    _default_edge_concurrency as _default_edge_concurrency,
    _default_coqui_workers as _default_coqui_workers,
    _default_piper_procs as _default_piper_procs,
    NETWORK_PROFILES as NETWORK_PROFILES,
)


def _parse_int_list(raw: Optional[str]) -> List[int]:
    if not raw:
        return []
    values: List[int] = []
    for part in raw.replace(",", " ").split():
        if "-" in part:
            start_raw, end_raw = part.split("-", 1)
            try:
                start = int(start_raw)
                end = int(end_raw)
            except ValueError:
                continue
            if start <= 0 or end <= 0:
                continue
            if end < start:
                start, end = end, start
            values.extend(range(start, end + 1))
        else:
            try:
                value = int(part)
            except ValueError:
                continue
            if value > 0:
                values.append(value)
    return sorted(set(values))


def _parse_list(raw: Optional[str]) -> List[str]:
    if not raw:
        return []
    items = []
    for part in raw.replace(",", " ").split():
        part = part.strip()
        if part:
            items.append(part)
    return items


def _worker_mode() -> bool:
    return "--worker" in sys.argv


def _build_sweep_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Comprehensive benchmark across TTS engines and parallelism.",
    )
    parser.add_argument("input_file", help="EPUB/PDF to benchmark")
    parser.add_argument("--output-dir", help="Directory to store benchmark output")
    parser.add_argument(
        "--max-chapters", type=int, default=0, help="Limit number of chapters (0 = all)"
    )
    parser.add_argument("--repeat", type=int, default=1, help="Runs per scenario")
    parser.add_argument(
        "--engines",
        default="edge,coqui,piper",
        help="Comma/space list of engines (edge, coqui, piper)",
    )
    parser.add_argument(
        "--edge-profiles",
        default="auto,slow,medium,fast",
        help="Edge network profiles to test (auto, slow, medium, fast, ultra)",
    )
    parser.add_argument(
        "--edge-parallel",
        choices=["on", "off", "both"],
        default="both",
        help="Edge segment parallelism toggle",
    )
    parser.add_argument(
        "--chapter-parallel-grid",
        help="Chapter parallelism levels (e.g. 1,2,4 or 1-6)",
    )
    parser.add_argument(
        "--edge-concurrency-grid",
        help="EDGE_MAX_CONCURRENCY values to test",
    )
    parser.add_argument(
        "--coqui-workers-grid",
        help="COQUI_MAX_WORKERS values to test",
    )
    parser.add_argument(
        "--piper-procs-grid",
        help="PIPER_MAX_PROCS values to test",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print scenarios and exit")
    parser.add_argument("--resume", action="store_true", help="Resume from existing results.jsonl")
    parser.add_argument("--keep-audio", action="store_true", help="Keep generated audio files")
    parser.add_argument(
        "--worker-timeout",
        type=int,
        default=1200,
        help="Timeout (seconds) per scenario worker; 0 disables",
    )
    return parser


def _build_worker_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("input_file")
    parser.add_argument("--engine", required=True, choices=["edge", "coqui", "piper"])
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--chapter-parallel", type=int, required=True)
    parser.add_argument("--max-chapters", type=int, default=0)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--network-profile")
    parser.add_argument("--hardware-profile")
    parser.add_argument("--keep-audio", action="store_true")
    return parser


def _run_sweep(args: argparse.Namespace) -> int:
    from python_app.src.hardware_detector import HardwareDetector

    input_path = Path(args.input_file)
    if not input_path.exists():
        print(f"Input not found: {input_path}")
        return 1

    timestamp = time.strftime("%Y%m%d_%H%M%S")
    output_dir = (
        Path(args.output_dir) if args.output_dir else ROOT / "output" / f"benchmark_{timestamp}"
    )
    output_dir.mkdir(parents=True, exist_ok=True)

    hardware_profile = HardwareDetector.detect()
    hardware_path = output_dir / "hardware_profile.json"
    _write_json(hardware_path, asdict(hardware_profile))

    engine_list = [engine.lower() for engine in _parse_list(args.engines)]
    engine_list = [engine for engine in engine_list if engine in {"edge", "coqui", "piper"}]
    if not engine_list:
        print("No valid engines selected.")
        return 1

    network_probe: Dict[str, object] = {}
    if "edge" in engine_list:
        network_probe = _probe_edge_latency()
        _write_json(output_dir / "edge_network.json", network_probe)

    profile_names = [name.lower() for name in _parse_list(args.edge_profiles)]
    resolved_profiles: List[str] = []
    detected_tier = str(network_probe.get("tier") or "unknown")
    for name in profile_names:
        if name == "auto":
            if detected_tier in NETWORK_PROFILES:
                resolved_profiles.append(detected_tier)
            else:
                resolved_profiles.append("medium")
        elif name in NETWORK_PROFILES:
            resolved_profiles.append(name)
    if not resolved_profiles:
        resolved_profiles = ["medium"]
    resolved_profiles = sorted(set(resolved_profiles))

    chapter_parallel_grid = _parse_int_list(args.chapter_parallel_grid)
    if not chapter_parallel_grid:
        chapter_parallel_grid = _default_chapter_parallel(
            hardware_profile.recommended_chapter_parallel
        )

    edge_concurrency_grid = _parse_int_list(args.edge_concurrency_grid)
    if not edge_concurrency_grid:
        edge_concurrency_grid = _default_edge_concurrency(hardware_profile.recommended_concurrency)

    cpu_count = max(1, int(hardware_profile.cpu_count))
    coqui_workers_grid = _parse_int_list(args.coqui_workers_grid)
    if not coqui_workers_grid:
        coqui_workers_grid = _default_coqui_workers(cpu_count)

    piper_procs_grid = _parse_int_list(args.piper_procs_grid)
    if not piper_procs_grid:
        piper_procs_grid = _default_piper_procs(cpu_count)

    if args.edge_parallel == "on":
        edge_parallel_values = [True]
    elif args.edge_parallel == "off":
        edge_parallel_values = [False]
    else:
        edge_parallel_values = [True, False]

    scenarios: List[Dict[str, object]] = []
    for engine in engine_list:
        if engine == "edge":
            for profile_name in resolved_profiles:
                profile = NETWORK_PROFILES[profile_name]
                for chapter_parallel in chapter_parallel_grid:
                    for enable_parallel in edge_parallel_values:
                        for base_concurrency in edge_concurrency_grid:
                            scaled = max(
                                1, int(round(base_concurrency * profile["concurrency_scale"]))
                            )
                            scaled = min(32, scaled)
                            scenarios.append(
                                {
                                    "engine": "edge",
                                    "chapter_parallel": chapter_parallel,
                                    "edge_profile": profile_name,
                                    "edge_enable_parallel": enable_parallel,
                                    "edge_max_concurrency": scaled,
                                    "edge_chunk_chars": int(profile["chunk_chars"]),
                                    "edge_max_segment_seconds": int(profile["max_segment_seconds"]),
                                }
                            )
        elif engine == "coqui":
            for chapter_parallel in chapter_parallel_grid:
                for workers in coqui_workers_grid:
                    scenarios.append(
                        {
                            "engine": "coqui",
                            "chapter_parallel": chapter_parallel,
                            "coqui_max_workers": workers,
                        }
                    )
        elif engine == "piper":
            for chapter_parallel in chapter_parallel_grid:
                for procs in piper_procs_grid:
                    scenarios.append(
                        {
                            "engine": "piper",
                            "chapter_parallel": chapter_parallel,
                            "piper_max_procs": procs,
                        }
                    )

    if args.dry_run:
        print(f"Scenarios: {len(scenarios)}")
        for scenario in scenarios:
            print(scenario)
        return 0

    results_path = output_dir / "results.jsonl"
    existing = _load_existing_results(results_path) if args.resume else {}
    seen_run_ids = set(existing.keys())

    runs: List[Dict[str, object]] = list(existing.values()) if existing else []
    script_path = Path(__file__).resolve()
    disabled_engines: set[str] = set()

    for scenario in scenarios:
        engine_name = str(scenario.get("engine") or "").lower()
        if engine_name in disabled_engines:
            continue
        scenario_id = _scenario_id(scenario)
        for run_index in range(1, max(1, int(args.repeat)) + 1):
            run_id = f"{scenario_id}-{run_index}"
            if run_id in seen_run_ids:
                continue

            output_run_dir = output_dir / "runs" / f"{scenario['engine']}_{run_id}"
            env = os.environ.copy()
            env["PYTHONUNBUFFERED"] = "1"
            if scenario.get("engine") == "edge":
                env["EDGE_ENABLE_PARALLEL"] = (
                    "true" if scenario["edge_enable_parallel"] else "false"
                )
                env["EDGE_MAX_CONCURRENCY"] = str(scenario["edge_max_concurrency"])
                env["EDGE_CHUNK_CHARS"] = str(scenario["edge_chunk_chars"])
                env["EDGE_MAX_SEGMENT_SECONDS"] = str(scenario["edge_max_segment_seconds"])
            if scenario.get("engine") == "coqui":
                env["COQUI_MAX_WORKERS"] = str(scenario["coqui_max_workers"])
            if scenario.get("engine") == "piper":
                env["PIPER_MAX_PROCS"] = str(scenario["piper_max_procs"])

            cmd = [
                sys.executable,
                str(script_path),
                "--worker",
                str(input_path),
                "--engine",
                scenario["engine"],
                "--output-dir",
                str(output_run_dir),
                "--chapter-parallel",
                str(scenario["chapter_parallel"]),
                "--max-chapters",
                str(args.max_chapters),
                "--run-id",
                run_id,
                "--hardware-profile",
                str(hardware_path),
            ]
            if scenario.get("edge_profile"):
                cmd.extend(["--network-profile", str(scenario["edge_profile"])])
            if args.keep_audio:
                cmd.append("--keep-audio")

            print(f"Running {run_id} ({scenario['engine']})")
            timeout_seconds = None
            if args.worker_timeout and args.worker_timeout > 0:
                timeout_seconds = float(args.worker_timeout)
            try:
                completed = subprocess.run(
                    cmd,
                    cwd=str(ROOT),
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=timeout_seconds,
                )
            except subprocess.TimeoutExpired:
                print(f"Worker timeout: {run_id} ({scenario['engine']})")
                result = {
                    "run_id": run_id,
                    "engine": scenario["engine"],
                    "chapter_parallel": scenario.get("chapter_parallel"),
                    "edge_enable_parallel": scenario.get("edge_enable_parallel"),
                    "edge_max_concurrency": scenario.get("edge_max_concurrency"),
                    "edge_chunk_chars": scenario.get("edge_chunk_chars"),
                    "edge_max_segment_seconds": scenario.get("edge_max_segment_seconds"),
                    "coqui_max_workers": scenario.get("coqui_max_workers"),
                    "piper_max_procs": scenario.get("piper_max_procs"),
                    "network_profile": scenario.get("edge_profile"),
                    "chars_per_second": 0.0,
                    "errors": 1,
                    "success": False,
                    "engine_available": True,
                    "error": "timeout",
                    "timeout_seconds": timeout_seconds,
                    "output_dir": str(output_run_dir),
                }
                runs.append(result)
                with results_path.open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps(result) + "\n")
                seen_run_ids.add(run_id)
                continue

            if completed.stdout:
                stdout_line = completed.stdout.strip().splitlines()[-1]
            else:
                stdout_line = ""
            try:
                result = json.loads(stdout_line) if stdout_line else None
            except json.JSONDecodeError:
                result = None

            if completed.returncode != 0:
                print(f"Worker failed: {run_id}")
                if completed.stderr:
                    print(completed.stderr.strip())
                if result:
                    runs.append(result)
                    with results_path.open("a", encoding="utf-8") as handle:
                        handle.write(json.dumps(result) + "\n")
                    seen_run_ids.add(run_id)
                    if result.get("engine_available") is False:
                        disabled_engines.add(engine_name)
                        break
                continue

            if not result:
                print(f"Invalid worker output for {run_id}")
                if completed.stdout:
                    print(completed.stdout)
                if completed.stderr:
                    print(completed.stderr)
                continue

            runs.append(result)
            with results_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(result) + "\n")
            seen_run_ids.add(run_id)

    if not runs:
        print("No results collected.")
        return 1

    summary = _summarize_results(runs)
    summary_payload = {
        "input_file": str(input_path),
        "output_dir": str(output_dir),
        "hardware_profile": asdict(hardware_profile),
        "network_probe": network_probe,
        "scenarios": len(scenarios),
        "runs": len(runs),
        "summary": summary,
    }
    _write_json(output_dir / "summary.json", summary_payload)
    _write_csv(output_dir / "summary.csv", summary)
    print(f"Summary written to {output_dir / 'summary.json'}")
    return 0


def main() -> int:
    if _worker_mode():
        parser = _build_worker_parser()
        args = parser.parse_args()
        return _run_worker(args)
    parser = _build_sweep_parser()
    args = parser.parse_args()
    return _run_sweep(args)

if __name__ == "__main__":
    sys.exit(main())
