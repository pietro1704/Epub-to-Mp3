"""Exercise existing benchmark orchestration with fake CLI subprocesses only."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BENCHMARK = Path(__file__).resolve().parents[2] / "scripts/benchmark_feature_ab.py"
ROUTES = ("baseline_no_stage", "stage_pipeline", "external_worker_pool")
FAKE_CLI = '''import json, os, sys
from pathlib import Path
output = Path(sys.argv[sys.argv.index("--output-dir") + 1])
cache = Path(os.environ["CACHE_DIR"])
cache.mkdir(parents=True, exist_ok=True)
sentinel = cache / "cache-sentinel"
receipt = {"cache_dir": str(cache), "warm": sentinel.exists(),
           "inherited": os.environ.get("AB_FIXTURE_INHERITED")}
sentinel.write_text("child-written", encoding="utf-8")
print(json.dumps(receipt), flush=True)
sys.exit(json.loads(os.environ.get("AB_FIXTURE_EXITS", "{}" )).get(output.name, 0))
'''


class FeatureABCacheIsolationTests(unittest.TestCase):
    def run_fixture(self, exits=None):
        with tempfile.TemporaryDirectory(prefix="ab-cache-contract-") as directory:
            root = Path(directory)
            package = root / "python_app"
            package.mkdir()
            (package / "__init__.py").write_text("", encoding="utf-8")
            (package / "main.py").write_text(FAKE_CLI, encoding="utf-8")
            book = root / "fixture.epub"
            book.write_bytes(b"Not parsed: fake CLI fixture")
            cache = root / "caller-cache"
            cache.mkdir()
            sentinel = cache / "cache-sentinel"
            sentinel.write_bytes(b"caller-owned")
            temporary = root / "temporary"
            temporary.mkdir()
            report = root / "report.json"
            env = {**os.environ, "CACHE_DIR": str(cache), "PERSISTENT_ROOT": str(root / "state"),
                   "TMPDIR": str(temporary), "AB_FIXTURE_INHERITED": "preserve-this-value",
                   "AB_FIXTURE_EXITS": json.dumps(exits or {})}
            before = dict(env)
            result = subprocess.run(
                [sys.executable, str(BENCHMARK), "--book", str(book), "--engine", "edge",
                 "--workers", "2", "--output", str(report)],
                cwd=root, env=env, capture_output=True, text=True, timeout=20, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(env, before)
            payload = json.loads(report.read_text(encoding="utf-8"))
            receipts = {}
            for name in ROUTES:
                lines = payload["results"][name]["stdout_tail"].splitlines()
                receipt = json.loads(next(line for line in lines if line.startswith("{")))
                receipt["owned"] = Path(receipt["cache_dir"]).is_relative_to(temporary)
                receipt["removed"] = not Path(receipt["cache_dir"]).exists()
                receipts[name] = receipt
            return payload, receipts, sentinel.read_bytes(), list(temporary.iterdir())

    def test_each_route_has_a_distinct_cold_owned_cache_and_preserves_caller_state(self):
        payload, receipts, caller_bytes, retained = self.run_fixture()
        self.assertEqual(caller_bytes, b"caller-owned")
        self.assertEqual(len({receipt["cache_dir"] for receipt in receipts.values()}), 3)
        for receipt in receipts.values():
            self.assertFalse(receipt["warm"])
            self.assertTrue(receipt["owned"])
            self.assertTrue(receipt["removed"])
            self.assertEqual(receipt["inherited"], "preserve-this-value")
        self.assertEqual(retained, [], "Only the benchmark-owned temporary tree may be cleaned")
        self.assertEqual(payload["cache_policy"], "isolated-cold-per-route")
        self.assertEqual(payload["engine"], "edge")
        for name in ROUTES:
            self.assertTrue(payload["results"][name]["success"])
            self.assertEqual(payload["results"][name]["exit_code"], 0)

    def test_failed_and_cancelled_children_keep_real_status_and_isolated_cleanup(self):
        payload, receipts, caller_bytes, retained = self.run_fixture({"base": 130, "stage": 143, "pool": 1})
        self.assertEqual(caller_bytes, b"caller-owned")
        self.assertEqual(retained, [])
        self.assertEqual(len({receipt["cache_dir"] for receipt in receipts.values()}), 3)
        self.assertTrue(all(receipt["owned"] and receipt["removed"] for receipt in receipts.values()))
        for name, expected in zip(ROUTES, (130, 143, 2)):
            self.assertFalse(payload["results"][name]["success"])
            self.assertEqual(payload["results"][name]["exit_code"], expected)
            self.assertGreater(payload["results"][name]["elapsed_s"], 0)


if __name__ == "__main__":
    unittest.main()
