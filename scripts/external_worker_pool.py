#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Run multiple book conversions with an external worker pool."""

from __future__ import annotations

import argparse
import asyncio
import os
import shlex
import sys
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
) -> tuple[Path, int]:
    async with sem:
        print(f"[{idx}/{total}] starting {file_path.name}")
        proc = await asyncio.create_subprocess_exec(*cmd)
        code = await proc.wait()
        state = "ok" if code == 0 else f"fail({code})"
        print(f"[{idx}/{total}] done {file_path.name}: {state}")
        return file_path, code


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
                _run_job(sem=sem, file_path=file_path, cmd=cmd, idx=idx, total=len(files))
            )
        )
    results = await asyncio.gather(*tasks)
    failures = [item for item in results if item[1] != 0]
    print(f"Finished: {len(files) - len(failures)}/{len(files)} succeeded")
    if failures:
        print("Failed files:")
        for file_path, code in failures:
            print(f" - {file_path} (exit {code})")
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
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.forward_args:
        args.forward_arg.extend(shlex.split(args.forward_args))
    return asyncio.run(_main_async(args))


if __name__ == "__main__":
    raise SystemExit(main())
