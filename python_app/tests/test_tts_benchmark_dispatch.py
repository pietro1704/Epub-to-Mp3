"""Offline contracts for the engine benchmark entrypoint and report boundaries."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from scripts.tts_benchmark_network_profiles import _classify_latency
from scripts.tts_benchmark_reports import _load_existing_results, _scenario_id, _summarize_results


def test_engine_cli_help_works_outside_checkout_without_starting_a_worker(tmp_path: Path):
    script = Path(__file__).resolve().parents[2] / "scripts" / "benchmark_engines_full.py"
    result = subprocess.run(
        [sys.executable, str(script), "--help"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    assert "--engines" in result.stdout
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize(
    ("samples", "expected"),
    [([], "unknown"), ([10], "ultra"), ([40], "fast"), ([100], "medium"), ([200], "slow")],
)
def test_network_tiers_use_recorded_samples_without_a_network_probe(samples, expected):
    assert _classify_latency(samples) == expected


def test_resume_keeps_run_identity_and_ignores_malformed_records(tmp_path: Path):
    path = tmp_path / "runs.jsonl"
    completed = {"run_id": "owned-1", "success": True}
    failed = {"run_id": "owned-2", "success": False}
    path.write_text("{malformed}\n" + json.dumps(completed) + "\n" + json.dumps(failed) + "\n")
    assert _load_existing_results(path) == {"owned-1": completed, "owned-2": failed}
    assert _load_existing_results(tmp_path / "missing.jsonl") == {}
    assert _scenario_id({"engine": "piper", "chapter_parallel": 1}) == _scenario_id(
        {"chapter_parallel": 1, "engine": "piper"}
    )


def test_failed_run_is_not_counted_as_successful_throughput():
    result = _summarize_results(
        [
            {"engine": "piper", "success": True, "chars_per_second": 20},
            {"engine": "piper", "success": False, "chars_per_second": 1000},
        ]
    )
    aggregate = result["aggregates"][0]
    assert aggregate["avg_chars_per_second"] == 20
    assert aggregate["success_rate"] == 0.5
