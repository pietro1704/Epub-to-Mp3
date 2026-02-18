#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Run multiple book conversions with an external worker pool."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import os
import shlex
import sys
import time
from pathlib import Path
from typing import Iterable, List, Sequence


def _expand_inputs(items: Iterable[str]) -> List[Path]:
    out: List[Path] = []
    seen = set()
    for raw in items:
        path = Path(raw).expanduser()
        if path.is_file() and path.suffix.lower() in {".epub", ".pdf"}:
            key = str(path.resolve())
            if key not in seen:
                out.append(path)
                seen.add(key)
            continue
        if path.is_dir():
            for candidate in sorted(path.rglob("*")):
                if not candidate.is_file():
                    continue
                if candidate.suffix.lower() not in {".epub", ".pdf"}:
                    continue
                key = str(candidate.resolve())
                if key in seen:
                    continue
                out.append(candidate)
                seen.add(key)
    return out


def _read_batch_file(batch_file: str | None) -> List[str]:
    if not batch_file:
        return []
    path = Path(batch_file).expanduser()
    if not path.exists():
        return []
    entries: List[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        cleaned = line.strip()
        if cleaned and not cleaned.startswith("#"):
            entries.append(cleaned)
    return entries


def _recommended_workers() -> int:
    cpu = max(1, os.cpu_count() or 1)
    try:
        import psutil  # type: ignore

        ram_gb = float(psutil.virtual_memory().total) / (1024**3)
    except Exception:
        ram_gb = 8.0
    by_cpu = max(1, min(8, cpu // 2 if cpu > 2 else 1))
    by_ram = max(1, min(8, int(ram_gb // 4)))
    return max(1, min(by_cpu, by_ram))


async def _run_job(
    *,
    sem: asyncio.Semaphore,
    file_path: Path,
    cmd: Sequence[str],
    idx: int,
    total: int,
    job_timeout_seconds: float,
) -> tuple[Path, int, float, bool]:
    async with sem:
        started = time.time()
        print(f"[{idx}/{total}] starting {file_path.name}")
        proc = await asyncio.create_subprocess_exec(*cmd)
        timeout = max(0.0, float(job_timeout_seconds or 0.0))
        timed_out = False
        if timeout > 0:
            try:
                code = await asyncio.wait_for(proc.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                timed_out = True
                with contextlib.suppress(Exception):
                    proc.kill()
                with contextlib.suppress(Exception):
                    await proc.wait()
                code = 124
        else:
            code = await proc.wait()
        elapsed = max(0.001, time.time() - started)
        state = "ok" if code == 0 else f"fail({code})"
        print(f"[{idx}/{total}] done {file_path.name}: {state} ({elapsed:.2f}s)")
        return file_path, code, elapsed, timed_out


async def _run_job_with_retry(
    *,
    sem: asyncio.Semaphore,
    file_path: Path,
    cmd: Sequence[str],
    idx: int,
    total: int,
    retries: int,
    retry_delay_s: float,
    job_timeout_seconds: float,
) -> tuple[Path, int, float, int, bool]:
    attempts = 0
    total_elapsed = 0.0
    had_timeout = False
    while True:
        attempts += 1
        path, code, elapsed, timed_out = await _run_job(
            sem=sem,
            file_path=file_path,
            cmd=cmd,
            idx=idx,
            total=total,
            job_timeout_seconds=job_timeout_seconds,
        )
        total_elapsed += elapsed
        had_timeout = had_timeout or timed_out
        if code == 0 or attempts > retries:
            return path, code, total_elapsed, attempts, had_timeout
        wait = max(0.0, float(retry_delay_s))
        print(
            f"[{idx}/{total}] retrying {file_path.name} in {wait:.1f}s "
            f"(attempt {attempts}/{retries + 1})"
        )
        if wait > 0:
            await asyncio.sleep(wait)


async def _main_async(args: argparse.Namespace) -> int:
    sources = list(args.inputs or [])
    sources.extend(_read_batch_file(args.batch_file))
    files = _expand_inputs(sources)
    if not files:
        print("No EPUB/PDF files found.")
        return 1

    workers = int(args.workers or _recommended_workers())
    workers = max(1, min(workers, 16))
    print(f"External worker pool: {workers} workers for {len(files)} books")

    sem = asyncio.Semaphore(workers)
    base = [sys.executable, "-m", "python_app.main", "convert"]
    forward = list(args.forward_arg or [])
    tasks = []
    for idx, file_path in enumerate(files, start=1):
        cmd = [*base, str(file_path), *forward]
        tasks.append(
            asyncio.create_task(
                _run_job_with_retry(
                    sem=sem,
                    file_path=file_path,
                    cmd=cmd,
                    idx=idx,
                    total=len(files),
                    retries=max(0, int(args.retries or 0)),
                    retry_delay_s=max(0.0, float(args.retry_delay_seconds or 0.0)),
                    job_timeout_seconds=max(0.0, float(args.job_timeout_seconds or 0.0)),
                )
            )
        )
    results = await asyncio.gather(*tasks)
    failures = [item for item in results if item[1] != 0]
    print(f"Finished: {len(files) - len(failures)}/{len(files)} succeeded")
    if args.json_report:
        report_path = Path(str(args.json_report)).expanduser()
        report_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "generated_at": time.time(),
            "workers": workers,
            "total_books": len(files),
            "successes": len(files) - len(failures),
            "failures": len(failures),
            "items": [
                {
                    "file": str(path),
                    "exit_code": int(code),
                    "elapsed_s": round(float(elapsed), 3),
                    "attempts": int(attempts),
                    "timed_out": bool(timed_out),
                    "success": int(code) == 0,
                }
                for path, code, elapsed, attempts, timed_out in results
            ],
        }
        report_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"JSON report: {report_path}")
    if failures:
        print("Failed files:")
        for file_path, code, _elapsed, _attempts, timed_out in failures:
            timeout_msg = " timeout" if timed_out else ""
            print(f" - {file_path} (exit {code}{timeout_msg})")
        return 2
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="External conversion worker pool")
    parser.add_argument("inputs", nargs="*", help="EPUB/PDF files or directories")
    parser.add_argument("--batch-file", help="Manifest with one input path per line")
    parser.add_argument(
        "--workers",
        type=int,
        help="Number of external worker processes (default: auto by HW)",
    )
    parser.add_argument(
        "--forward-arg",
        action="append",
        default=[],
        help="Argument forwarded to `python -m python_app.main convert` (repeatable)",
    )
    parser.add_argument(
        "--forward-args",
        default="",
        help="Quoted string with extra args to forward to convert",
    )
    parser.add_argument(
        "--retries",
        type=int,
        default=1,
        help="Retries per failed book",
    )
    parser.add_argument(
        "--retry-delay-seconds",
        type=float,
        default=2.0,
        help="Delay between retries",
    )
    parser.add_argument(
        "--json-report",
        help="Optional JSON report output path",
    )
    parser.add_argument(
        "--job-timeout-seconds",
        type=float,
        default=0.0,
        help="Per-book timeout (0 disables timeout)",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.forward_args:
        args.forward_arg.extend(shlex.split(args.forward_args))
    return asyncio.run(_main_async(args))


if __name__ == "__main__":
    raise SystemExit(main())
