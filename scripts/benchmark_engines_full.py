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
import hashlib
import json
import os
import socket
import statistics
import subprocess
import sys
import time
from dataclasses import asdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


NETWORK_PROFILES: Dict[str, Dict[str, float]] = {
    "slow": {"chunk_chars": 8000, "max_segment_seconds": 40, "concurrency_scale": 0.5},
    "medium": {"chunk_chars": 11000, "max_segment_seconds": 60, "concurrency_scale": 0.75},
    "fast": {"chunk_chars": 16000, "max_segment_seconds": 75, "concurrency_scale": 1.0},
    "ultra": {"chunk_chars": 20000, "max_segment_seconds": 85, "concurrency_scale": 1.25},
}


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


def _dedupe_sorted(values: Iterable[int]) -> List[int]:
    return sorted({int(v) for v in values if int(v) > 0})


def _probe_edge_latency(
    host: str = "api.msedgeservices.com",
    *,
    attempts: int = 5,
    timeout: float = 2.5,
    pause: float = 0.2,
) -> Dict[str, object]:
    latencies_ms: List[float] = []
    errors = 0
    for _ in range(max(1, attempts)):
        start = time.perf_counter()
        try:
            sock = socket.create_connection((host, 443), timeout=timeout)
            sock.close()
            latencies_ms.append((time.perf_counter() - start) * 1000.0)
        except OSError:
            errors += 1
        time.sleep(pause)
    tier = _classify_latency(latencies_ms)
    return {
        "host": host,
        "attempts": attempts,
        "errors": errors,
        "latencies_ms": latencies_ms,
        "median_ms": statistics.median(latencies_ms) if latencies_ms else None,
        "tier": tier,
    }


def _classify_latency(latencies_ms: List[float]) -> str:
    if not latencies_ms:
        return "unknown"
    median = statistics.median(latencies_ms)
    if median <= 30:
        return "ultra"
    if median <= 70:
        return "fast"
    if median <= 140:
        return "medium"
    return "slow"


def _default_chapter_parallel(recommended: int) -> List[int]:
    rec = max(1, int(recommended or 1))
    values = [
        1,
        max(2, rec // 2),
        rec,
        min(16, rec * 2),
    ]
    return _dedupe_sorted(values)


def _default_edge_concurrency(recommended: int) -> List[int]:
    rec = max(1, int(recommended or 1))
    values = [
        1,
        max(2, rec // 2),
        rec,
        min(32, rec * 2),
    ]
    return _dedupe_sorted(values)


def _default_coqui_workers(cpu_count: int) -> List[int]:
    default = max(1, min(4, cpu_count))
    values = [1, default, min(8, default + 1), min(8, default * 2)]
    return _dedupe_sorted(values)


def _default_piper_procs(cpu_count: int) -> List[int]:
    default = max(1, min(3, cpu_count))
    values = [1, default, min(6, default + 1), min(6, default * 2)]
    return _dedupe_sorted(values)


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


def _run_worker(args: argparse.Namespace) -> int:
    import psutil

    from python_app.src.config import AppConfig, VoiceConfigProvider
    from python_app.src.ebook_reader import EbookReader
    from python_app.src.engine_pool import JobEnginePool, ResourceSnapshot
    from python_app.src.hardware_detector import HardwareProfile
    from python_app.src.tts.factory import TTSFactory

    start_ts = time.time()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    if args.hardware_profile:
        data = json.loads(Path(args.hardware_profile).read_text(encoding="utf-8"))
        hardware_profile = HardwareProfile(**data)
    else:
        from python_app.src.hardware_detector import HardwareDetector

        hardware_profile = HardwareDetector.detect()

    reader = EbookReader(args.input_file)
    chapters = reader.get_chapter_structure(preserve_all=True)
    if args.max_chapters and args.max_chapters > 0:
        chapters = chapters[: args.max_chapters]

    primary_language = (reader.language or "auto").split("-", 1)[0]
    provider = VoiceConfigProvider()
    default_voice = (
        provider.get_voice(args.engine, primary_language)
        if primary_language
        else provider.get_voice(args.engine)
    )

    app_config = AppConfig()
    config = app_config.create_conversion_config(
        args.engine,
        voice=default_voice,
        primary_language=primary_language,
    )

    engine_label = args.engine.lower()
    edge_cap = 0
    try:
        edge_cap = int(os.getenv("EDGE_MAX_CONCURRENCY", "") or "0")
    except ValueError:
        edge_cap = 0

    def _snapshot() -> ResourceSnapshot:
        cpu_pct = 0.0
        ram_gb = 0.0
        try:
            cpu_pct = float(psutil.cpu_percent(interval=None))
        except Exception:
            cpu_pct = 0.0
        try:
            mem = psutil.virtual_memory()
            ram_gb = float(mem.available / (1024**3))
        except Exception:
            ram_gb = 0.0
        cpu_idle = max(0.0, 100.0 - cpu_pct)
        return ResourceSnapshot(
            cpu_percent=cpu_pct,
            cpu_idle=cpu_idle,
            ram_gb=ram_gb,
            active_jobs=max(1, int(args.chapter_parallel)),
        )

    tts_factory = TTSFactory()
    engine_pool = JobEnginePool(
        create_engine=tts_factory.create_engine,
        parallel_slots=max(1, int(args.chapter_parallel)),
        edge_cap=edge_cap,
        hardware_profile=hardware_profile,
        stats_provider=_snapshot,
    )
    engine_pool.register_engine(engine_label, config)

    texts: List[str] = []
    for chapter in chapters:
        text = getattr(chapter, "speech_text", None) or chapter.text or ""
        texts.append(text)

    total_chars = sum(len(text) for text in texts)
    if not texts:
        payload = {
            "run_id": args.run_id,
            "engine": engine_label,
            "success": False,
            "engine_available": True,
            "error": "no_chapters",
        }
        print(json.dumps(payload))
        return 1

    output_ext = ".mp3" if engine_label == "edge" else ".wav"

    async def _run() -> Dict[str, object]:
        import asyncio

        init_start = time.perf_counter()
        try:
            async with engine_pool.use(engine_label):
                pass
        except Exception as exc:
            return {"errors": 0, "engine_available": False, "error": str(exc)}
        init_seconds = time.perf_counter() - init_start

        semaphore = asyncio.Semaphore(max(1, int(args.chapter_parallel)))
        errors = 0

        async def synthesize(idx: int, text: str) -> None:
            nonlocal errors
            if not text:
                return
            output_path = output_dir / f"ch{idx:04d}{output_ext}"
            async with semaphore:
                try:
                    async with engine_pool.use(engine_label) as (_, engine_obj):
                        result = await engine_obj.synthesize_async(text, output_path)
                    if result is None:
                        errors += 1
                except Exception:
                    errors += 1

        synth_start = time.perf_counter()
        tasks = [asyncio.create_task(synthesize(idx + 1, text)) for idx, text in enumerate(texts)]
        await asyncio.gather(*tasks)
        synth_seconds = time.perf_counter() - synth_start
        return {
            "errors": errors,
            "engine_available": True,
            "init_seconds": init_seconds,
            "synth_seconds": synth_seconds,
        }

    try:
        import asyncio

        run_outcome = asyncio.run(_run())
    except Exception as exc:
        payload = {
            "run_id": args.run_id,
            "engine": engine_label,
            "success": False,
            "engine_available": False,
            "error": str(exc),
        }
        print(json.dumps(payload))
        return 1
    if run_outcome.get("engine_available") is False:
        payload = {
            "run_id": args.run_id,
            "engine": engine_label,
            "success": False,
            "engine_available": False,
            "error": str(run_outcome.get("error") or "engine_init_failed"),
        }
        print(json.dumps(payload))
        return 1

    init_seconds = float(run_outcome.get("init_seconds") or 0.0)
    synth_seconds = float(run_outcome.get("synth_seconds") or 0.0)

    if not args.keep_audio:
        for path in output_dir.glob(f"*{output_ext}"):
            try:
                path.unlink()
            except OSError:
                pass

    end_ts = time.time()
    payload = {
        "run_id": args.run_id,
        "engine": engine_label,
        "chapter_parallel": int(args.chapter_parallel),
        "edge_enable_parallel": os.getenv("EDGE_ENABLE_PARALLEL"),
        "edge_max_concurrency": os.getenv("EDGE_MAX_CONCURRENCY"),
        "edge_chunk_chars": os.getenv("EDGE_CHUNK_CHARS"),
        "edge_max_segment_seconds": os.getenv("EDGE_MAX_SEGMENT_SECONDS"),
        "coqui_max_workers": os.getenv("COQUI_MAX_WORKERS"),
        "piper_max_procs": os.getenv("PIPER_MAX_PROCS"),
        "network_profile": args.network_profile,
        "voice": config.voice,
        "model_path": str(config.model_path) if config.model_path else None,
        "chapters": len(texts),
        "chars": total_chars,
        "init_seconds": init_seconds,
        "synth_seconds": synth_seconds,
        "total_seconds": (end_ts - start_ts),
        "chars_per_second": (total_chars / synth_seconds) if synth_seconds > 0 else 0.0,
        "errors": int(run_outcome.get("errors", 0)),
        "success": int(run_outcome.get("errors", 0)) == 0,
        "engine_available": True,
        "output_dir": str(output_dir),
    }
    print(json.dumps(payload))
    return 0


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
