#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A/B benchmark for staged pipeline and external worker pool."""

from __future__ import annotations

import argparse
import json
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from python_app.src.paths import TELEMETRY_DIR  # noqa: E402


def _default_book() -> Path:
    sample = ROOT / "python_app/tests/fixtures/epubs/sample_multilang.epub"
    if sample.exists():
        return sample
    return ROOT / "web/public/sample.epub"


def _run(cmd: List[str], env: Dict[str, str] | None = None) -> Dict[str, object]:
    start = time.time()
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    elapsed = max(0.001, time.time() - start)
    return {
        "cmd": cmd,
        "exit_code": int(proc.returncode),
        "elapsed_s": round(elapsed, 3),
        "success": proc.returncode == 0,
        "stdout_tail": "\n".join((proc.stdout or "").splitlines()[-20:]),
        "stderr_tail": "\n".join((proc.stderr or "").splitlines()[-20:]),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="A/B benchmark for stage pipeline and external worker pool"
    )
    parser.add_argument("--book", type=Path, default=_default_book())
    parser.add_argument("--engine", default="auto")
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()

    book = Path(args.book).expanduser()
    if not book.exists():
        print(f"Book not found: {book}")
        return 1

    with tempfile.TemporaryDirectory(prefix="ab-bench-") as tmp:
        tmp_dir = Path(tmp)
        base_out = tmp_dir / "base"
        stage_out = tmp_dir / "stage"
        pool_out = tmp_dir / "pool"

        base_cmd = [
            sys.executable,
            "-m",
            "python_app.main",
            "convert",
            str(book),
            "--engine",
            str(args.engine),
            "--max-performance",
            "--no-stage-pipeline",
            "--output-dir",
            str(base_out),
        ]
        stage_cmd = [
            sys.executable,
            "-m",
            "python_app.main",
            "convert",
            str(book),
            "--engine",
            str(args.engine),
            "--max-performance",
            "--stage-pipeline",
            "--stage-pipeline-depth",
            "3",
            "--output-dir",
            str(stage_out),
        ]
        pool_cmd = [
            sys.executable,
            str(ROOT / "scripts/external_worker_pool.py"),
            str(book),
            "--workers",
            str(max(1, int(args.workers or 2))),
            "--forward-args",
            f"--engine {args.engine} --max-performance --stage-pipeline --output-dir {pool_out}",
        ]

        base = _run(base_cmd)
        stage = _run(stage_cmd)
        pool = _run(pool_cmd)

    base_time = float(base.get("elapsed_s") or 0.0)
    stage_time = float(stage.get("elapsed_s") or 0.0)
    pool_time = float(pool.get("elapsed_s") or 0.0)

    payload = {
        "generated_at": time.time(),
        "hostname": socket.gethostname(),
        "book": str(book),
        "engine": str(args.engine),
        "results": {
            "baseline_no_stage": base,
            "stage_pipeline": stage,
            "external_worker_pool": pool,
        },
        "comparisons": {
            "stage_vs_baseline_gain_pct": round(((base_time - stage_time) / base_time) * 100.0, 2)
            if base_time > 0
            else 0.0,
            "pool_vs_stage_gain_pct": round(((stage_time - pool_time) / stage_time) * 100.0, 2)
            if stage_time > 0
            else 0.0,
        },
    }

    output = args.output
    if output is None:
        output = TELEMETRY_DIR / f"feature-ab-benchmark-{socket.gethostname()}.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"Saved benchmark report: {output}")
    print(
        "Stage vs Baseline gain: "
        f"{float(payload['comparisons']['stage_vs_baseline_gain_pct']):.2f}%"
    )
    print("Pool vs Stage gain: " f"{float(payload['comparisons']['pool_vs_stage_gain_pct']):.2f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
