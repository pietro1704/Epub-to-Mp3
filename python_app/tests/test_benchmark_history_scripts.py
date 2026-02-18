# -*- coding: utf-8 -*-
"""Tests for benchmark history trend/report helper scripts."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def _load_script_module(script_name: str):
    root = Path(__file__).resolve().parents[2]
    script_path = root / "scripts" / script_name
    spec = importlib.util.spec_from_file_location(script_name.replace(".py", ""), script_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestBenchmarkHistoryScripts(unittest.TestCase):
    def setUp(self) -> None:
        self.trend_mod = _load_script_module("check_benchmark_history_trend.py")
        self.report_mod = _load_script_module("render_benchmark_history_report.py")
        self.temp_dir = tempfile.TemporaryDirectory(prefix="bench-history-test-")
        self.addCleanup(self.temp_dir.cleanup)

    def _write_history(self, entries):
        path = Path(self.temp_dir.name) / "history.json"
        path.write_text(
            json.dumps({"updated_at": 1700000000.0, "entries": entries}), encoding="utf-8"
        )
        return path

    def test_trend_check_passes_when_drop_is_small(self):
        history_path = self._write_history(
            [
                {"stage_vs_baseline_gain_pct": 11.0, "pool_vs_stage_gain_pct": 4.0},
                {"stage_vs_baseline_gain_pct": 10.5, "pool_vs_stage_gain_pct": 4.2},
                {"stage_vs_baseline_gain_pct": 11.5, "pool_vs_stage_gain_pct": 3.9},
                {"stage_vs_baseline_gain_pct": 10.8, "pool_vs_stage_gain_pct": 4.1},
                {"stage_vs_baseline_gain_pct": 12.0, "pool_vs_stage_gain_pct": 4.3},
                {"stage_vs_baseline_gain_pct": 11.7, "pool_vs_stage_gain_pct": 4.0},
                {"stage_vs_baseline_gain_pct": 11.9, "pool_vs_stage_gain_pct": 4.1},
                {"stage_vs_baseline_gain_pct": 12.1, "pool_vs_stage_gain_pct": 4.2},
            ]
        )
        argv = [
            "check_benchmark_history_trend.py",
            "--history",
            str(history_path),
            "--recent-window",
            "4",
            "--baseline-window",
            "4",
            "--max-drop-pct",
            "20",
        ]
        with patch("sys.argv", argv):
            code = self.trend_mod.main()
        self.assertEqual(code, 0)

    def test_trend_check_fails_on_sustained_drop(self):
        history_path = self._write_history(
            [
                {"stage_vs_baseline_gain_pct": 2.0, "pool_vs_stage_gain_pct": 0.5},
                {"stage_vs_baseline_gain_pct": 2.1, "pool_vs_stage_gain_pct": 0.4},
                {"stage_vs_baseline_gain_pct": 1.9, "pool_vs_stage_gain_pct": 0.6},
                {"stage_vs_baseline_gain_pct": 2.0, "pool_vs_stage_gain_pct": 0.5},
                {"stage_vs_baseline_gain_pct": 12.0, "pool_vs_stage_gain_pct": 4.5},
                {"stage_vs_baseline_gain_pct": 11.8, "pool_vs_stage_gain_pct": 4.2},
                {"stage_vs_baseline_gain_pct": 12.2, "pool_vs_stage_gain_pct": 4.4},
                {"stage_vs_baseline_gain_pct": 11.7, "pool_vs_stage_gain_pct": 4.1},
            ]
        )
        argv = [
            "check_benchmark_history_trend.py",
            "--history",
            str(history_path),
            "--recent-window",
            "4",
            "--baseline-window",
            "4",
            "--max-drop-pct",
            "20",
        ]
        with patch("sys.argv", argv):
            code = self.trend_mod.main()
        self.assertEqual(code, 1)

    def test_render_report_generates_markdown(self):
        history_path = self._write_history(
            [
                {
                    "ts": 1700000000.0,
                    "hostname": "host-a",
                    "engine": "edge",
                    "stage_vs_baseline_gain_pct": 9.5,
                    "pool_vs_stage_gain_pct": 3.2,
                    "stage_success": True,
                    "pool_success": True,
                }
            ]
        )
        output_path = Path(self.temp_dir.name) / "history.md"
        argv = [
            "render_benchmark_history_report.py",
            "--history",
            str(history_path),
            "--output",
            str(output_path),
            "--max-rows",
            "5",
        ]
        with patch("sys.argv", argv):
            code = self.report_mod.main()
        self.assertEqual(code, 0)
        content = output_path.read_text(encoding="utf-8")
        self.assertIn("# Weekly Feature A/B History", content)
        self.assertIn("host-a", content)
        self.assertIn("9.50%", content)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
