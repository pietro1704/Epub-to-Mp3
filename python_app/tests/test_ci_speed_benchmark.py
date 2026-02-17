# -*- coding: utf-8 -*-
"""Tests for CI speed benchmark utility."""

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.ci_speed_benchmark import check_regression, run_ci_speed_benchmark


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
