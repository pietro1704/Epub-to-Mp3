# -*- coding: utf-8 -*-
"""Tests for CI speed benchmark utility."""

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.ci_speed_benchmark import (
    baseline_is_stale,
    check_regression,
    check_regression_vs_baseline,
    load_baseline,
    run_ci_speed_benchmark,
    save_baseline,
)


class TestCISpeedBenchmark(unittest.IsolatedAsyncioTestCase):
    async def test_ci_speed_benchmark_generates_report(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report_path = Path(temp_dir) / "ci-speed-benchmark.json"
            payload = await run_ci_speed_benchmark(output_path=report_path, cps=250_000.0)

            self.assertTrue(report_path.exists())
            self.assertIn("items", payload)
            self.assertEqual(len(payload["items"]), 3)
            labels = {item["size"] for item in payload["items"]}
            self.assertEqual(labels, {"short", "medium", "long"})
            self.assertTrue(all(bool(item["success"]) for item in payload["items"]))
            self.assertGreater(float(payload.get("avg_chars_per_second", 0.0)), 0.0)

    def test_regression_check(self):
        ok, _msg = check_regression({"avg_chars_per_second": 1200.0}, 1000.0)
        self.assertTrue(ok)
        ok, _msg = check_regression({"avg_chars_per_second": 800.0}, 1000.0)
        self.assertFalse(ok)

    def test_baseline_store_and_regression(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            baseline_path = Path(temp_dir) / "baseline.json"
            save_baseline({"avg_chars_per_second": 1000.0, "items": []}, baseline_path)
            baseline = load_baseline(baseline_path)
            self.assertIsNotNone(baseline)
            self.assertFalse(baseline_is_stale(baseline, period_hours=24))
            ok, _msg = check_regression_vs_baseline(
                {"avg_chars_per_second": 950.0},
                baseline,
                max_regression_pct=10.0,
            )
            self.assertTrue(ok)
            ok, _msg = check_regression_vs_baseline(
                {"avg_chars_per_second": 850.0},
                baseline,
                max_regression_pct=10.0,
            )
            self.assertFalse(ok)
