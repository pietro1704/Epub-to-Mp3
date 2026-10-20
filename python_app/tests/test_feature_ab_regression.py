"""Exercise the real A/B report checker CLI without running a benchmark."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECKER = Path(__file__).resolve().parents[2] / "scripts/check_feature_ab_regression.py"
RESULTS = ("baseline_no_stage", "stage_pipeline", "external_worker_pool")


def valid_report():
    return {
        "results": {
            name: {"success": True, "exit_code": 0, "elapsed_s": elapsed}
            for name, elapsed in zip(RESULTS, (10.0, 8.0, 7.2))
        },
        "comparisons": {"stage_vs_baseline_gain_pct": 20.0, "pool_vs_stage_gain_pct": 10.0},
    }


class FeatureABCheckerTests(unittest.TestCase):
    def assert_invalid(self, result):
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("A/B regression check: INVALID", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertLess(len(result.stderr), 250)

    def check(self, payload, *arguments):
        with tempfile.TemporaryDirectory(prefix="ab-checker-contract-") as directory:
            report = Path(directory) / "report.json"
            report.write_text(json.dumps(payload), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(CHECKER), "--report", str(report), *arguments],
                capture_output=True, text=True, timeout=10, check=False,
            )

    def test_success_exact_boundaries_and_actual_threshold_losses(self):
        cases = [(20.0, 10.0, 0), (-25.0, -35.0, 0), (-25.01, 0.0, 1), (0.0, -35.01, 1)]
        for stage, pool, expected in cases:
            with self.subTest(stage=stage, pool=pool):
                payload = valid_report()
                payload["comparisons"].update(stage_vs_baseline_gain_pct=stage, pool_vs_stage_gain_pct=pool)
                result = self.check(payload)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        result = self.check(valid_report(), "--max-stage-loss-pct=-25", "--max-pool-loss-pct=-35")
        self.assertEqual(result.returncode, 0, "Existing absolute-value threshold compatibility is preserved")

    def test_all_partial_failed_and_cancelled_results_never_pass(self):
        for failed_names in [RESULTS, *[(name,) for name in RESULTS]]:
            for exit_code in [1, 130, 143, -15]:
                with self.subTest(failed_names=failed_names, exit_code=exit_code):
                    payload = valid_report()
                    for name in failed_names:
                        payload["results"][name].update(success=False, exit_code=exit_code)
                    self.assert_invalid(self.check(payload))
        for name in RESULTS:
            payload = valid_report()
            payload["results"][name]["exit_code"] = 130
            self.assert_invalid(self.check(payload))

    def test_missing_or_malformed_schema_cannot_default_to_zero_gain(self):
        cases = [None, [], {}, {"results": {}}, {"comparisons": {}},
                 {"results": [], "comparisons": {}}, {"results": valid_report()["results"]}]
        for name in RESULTS:
            payload = valid_report()
            del payload["results"][name]
            cases.append(payload)
            payload = valid_report()
            payload["results"][name] = None
            cases.append(payload)
        for payload in cases:
            with self.subTest(payload=payload):
                self.assert_invalid(self.check(payload))

    def test_result_fields_require_explicit_success_and_numeric_evidence(self):
        for field, values in {
            "success": [None, False, 1, "true"],
            "exit_code": [None, True, False, "0", 0.0],
            "elapsed_s": [None, True, False, "10", 0, -1, float("nan"), float("inf"), -float("inf")],
        }.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    payload = valid_report()
                    payload["results"][RESULTS[0]][field] = value
                    self.assert_invalid(self.check(payload))
            payload = valid_report()
            del payload["results"][RESULTS[0]][field]
            self.assert_invalid(self.check(payload))

    def test_both_comparisons_are_required_finite_numbers(self):
        for name in valid_report()["comparisons"]:
            for value in [None, True, False, "20", float("nan"), float("inf"), -float("inf")]:
                with self.subTest(name=name, value=value):
                    payload = valid_report()
                    payload["comparisons"][name] = value
                    self.assert_invalid(self.check(payload))
            payload = valid_report()
            del payload["comparisons"][name]
            self.assert_invalid(self.check(payload))
        for comparisons in [None, [], {}]:
            payload = valid_report()
            payload["comparisons"] = comparisons
            self.assert_invalid(self.check(payload))

    def test_nonfinite_thresholds_never_disable_validation(self):
        for option in ["--max-stage-loss-pct", "--max-pool-loss-pct"]:
            for value in ["nan", "inf", "-inf"]:
                with self.subTest(option=option, value=value):
                    self.assert_invalid(self.check(valid_report(), f"{option}={value}"))

    def test_missing_or_invalid_json_report_fails(self):
        with tempfile.TemporaryDirectory(prefix="ab-invalid-report-") as directory:
            report = Path(directory) / "report.json"
            command = [sys.executable, str(CHECKER), "--report", str(report)]
            self.assert_invalid(subprocess.run(command, capture_output=True, text=True, timeout=10, check=False))
            report.write_text("{invalid JSON", encoding="utf-8")
            self.assert_invalid(subprocess.run(command, capture_output=True, text=True, timeout=10, check=False))


if __name__ == "__main__":
    unittest.main()
