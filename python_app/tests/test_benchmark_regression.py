# -*- coding: utf-8 -*-
"""Tests for scripts/benchmark_regression.py"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parents[2] / "scripts" / "benchmark_regression.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("benchmark_regression", _SCRIPT_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


BR = _load_module()


@pytest.fixture
def baseline() -> dict:
    return {
        "min_samples": 3,
        "tolerance_pct": 10.0,
        "engines": {
            "edge": {"min_chars_per_second": 100.0},
            "piper": {"min_chars_per_second": 50.0},
            "kokoro": {"min_chars_per_second": 40.0, "tolerance_pct": 20.0},
        },
    }


def test_load_baseline_reads_file(tmp_path: Path, baseline: dict) -> None:
    path = tmp_path / "baseline.json"
    path.write_text(json.dumps(baseline), encoding="utf-8")
    loaded = BR.load_baseline(path)
    assert loaded["engines"]["edge"]["min_chars_per_second"] == 100.0


def test_load_baseline_missing_file(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        BR.load_baseline(tmp_path / "ghost.json")


def test_load_baseline_invalid_root(tmp_path: Path) -> None:
    bad = tmp_path / "bad.json"
    bad.write_text("[]", encoding="utf-8")
    with pytest.raises(ValueError):
        BR.load_baseline(bad)


def test_load_baseline_missing_engines(tmp_path: Path) -> None:
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"engines": {}}), encoding="utf-8")
    with pytest.raises(ValueError):
        BR.load_baseline(bad)


def test_evaluate_all_pass(baseline: dict) -> None:
    summary = {
        "edge": {"samples": 10, "avg_chars_per_second": 150.0},
        "piper": {"samples": 5, "avg_chars_per_second": 60.0},
        "kokoro": {"samples": 4, "avg_chars_per_second": 45.0},
    }
    failures, warnings, passes = BR.evaluate(baseline, summary)
    assert failures == []
    assert warnings == []
    assert len(passes) == 3


def test_evaluate_failure_when_below_floor(baseline: dict) -> None:
    summary = {
        "edge": {"samples": 10, "avg_chars_per_second": 80.0},  # below 90 (100 - 10%)
        "piper": {"samples": 5, "avg_chars_per_second": 60.0},
    }
    failures, warnings, passes = BR.evaluate(baseline, summary)
    assert len(failures) == 1
    assert "edge" in failures[0]
    assert any("piper" in p for p in passes)


def test_evaluate_per_engine_tolerance_override(baseline: dict) -> None:
    # kokoro has 20% tolerance → floor = 32.0
    summary = {
        "edge": {"samples": 10, "avg_chars_per_second": 150.0},
        "piper": {"samples": 5, "avg_chars_per_second": 60.0},
        "kokoro": {"samples": 4, "avg_chars_per_second": 33.0},
    }
    failures, _, passes = BR.evaluate(baseline, summary)
    assert failures == []
    assert any("kokoro" in p for p in passes)


def test_evaluate_warning_when_no_samples(baseline: dict) -> None:
    summary = {
        "edge": {"samples": 10, "avg_chars_per_second": 150.0},
    }
    _, warnings, _ = BR.evaluate(baseline, summary)
    assert any("piper" in w and "no telemetry" in w for w in warnings)
    assert any("kokoro" in w for w in warnings)


def test_evaluate_warning_when_insufficient_samples(baseline: dict) -> None:
    summary = {
        "edge": {"samples": 2, "avg_chars_per_second": 150.0},
        "piper": {"samples": 5, "avg_chars_per_second": 60.0},
        "kokoro": {"samples": 4, "avg_chars_per_second": 45.0},
    }
    failures, warnings, _ = BR.evaluate(baseline, summary)
    assert failures == []
    assert any("edge" in w and "2 samples" in w for w in warnings)


def test_main_passes_with_good_report(tmp_path: Path, baseline: dict) -> None:
    baseline_path = tmp_path / "baseline.json"
    baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
    report_path = tmp_path / "report.json"
    report_path.write_text(
        json.dumps(
            {
                "edge": {"samples": 10, "avg_chars_per_second": 150.0},
                "piper": {"samples": 5, "avg_chars_per_second": 60.0},
                "kokoro": {"samples": 4, "avg_chars_per_second": 45.0},
            }
        ),
        encoding="utf-8",
    )
    rc = BR.main(["--baseline", str(baseline_path), "--report", str(report_path)])
    assert rc == 0


def test_main_fails_when_regressed(
    tmp_path: Path, baseline: dict, capsys: pytest.CaptureFixture
) -> None:
    baseline_path = tmp_path / "baseline.json"
    baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
    report_path = tmp_path / "report.json"
    report_path.write_text(
        json.dumps(
            {
                "edge": {"samples": 10, "avg_chars_per_second": 50.0},
                "piper": {"samples": 5, "avg_chars_per_second": 60.0},
                "kokoro": {"samples": 4, "avg_chars_per_second": 45.0},
            }
        ),
        encoding="utf-8",
    )
    rc = BR.main(["--baseline", str(baseline_path), "--report", str(report_path)])
    assert rc == 1
    out = capsys.readouterr().out
    assert "FAIL" in out


def test_main_warnings_as_errors(tmp_path: Path, baseline: dict) -> None:
    baseline_path = tmp_path / "baseline.json"
    baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
    report_path = tmp_path / "report.json"
    report_path.write_text(
        json.dumps(
            {
                "edge": {"samples": 10, "avg_chars_per_second": 150.0},
            }
        ),
        encoding="utf-8",
    )
    rc_ok = BR.main(["--baseline", str(baseline_path), "--report", str(report_path)])
    assert rc_ok == 0

    rc_strict = BR.main(
        [
            "--baseline",
            str(baseline_path),
            "--report",
            str(report_path),
            "--warnings-as-errors",
        ]
    )
    assert rc_strict == 1


def test_main_missing_baseline_returns_2(tmp_path: Path) -> None:
    rc = BR.main(["--baseline", str(tmp_path / "nope.json")])
    assert rc == 2


def test_main_missing_report_returns_2(tmp_path: Path, baseline: dict) -> None:
    baseline_path = tmp_path / "baseline.json"
    baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
    rc = BR.main(
        [
            "--baseline",
            str(baseline_path),
            "--report",
            str(tmp_path / "missing.json"),
        ]
    )
    assert rc == 2


def test_repository_baseline_file_valid() -> None:
    """The shipped baseline.json must be loadable by load_baseline."""
    repo_baseline = Path(__file__).resolve().parents[2] / "benchmarks" / "baseline.json"
    data = BR.load_baseline(repo_baseline)
    assert "edge" in data["engines"]
    assert data["engines"]["edge"]["min_chars_per_second"] > 0
