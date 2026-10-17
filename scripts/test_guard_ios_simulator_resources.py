"""Runtime contracts for the read-only resource monitor; no Apple actions."""

from __future__ import annotations

import json
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import guard_ios_simulator_resources as monitor


class Clock:
    def __init__(self):
        self.value = 100.0

    def now(self):
        return self.value

    def sleep(self, seconds):
        self.value += seconds


class Queries:
    def __init__(self):
        self.values = {
            ("/usr/sbin/sysctl", "-n", "hw.memsize", "hw.ncpu"): "8589934592\n8\n",
            ("/usr/bin/memory_pressure", "-Q"): "System-wide memory free percentage: 58%\n",
            ("/usr/bin/vm_stat",): (
                "Mach Virtual Memory Statistics: (page size of 4096 bytes)\n"
                "Pages free: 100.\nPages active: 200.\nPages inactive: 300.\n"
                "Pages wired down: 400.\nPages occupied by compressor: 500.\n"
                "Pageouts: 12.\nSwapouts: 13.\n"
            ),
            (
                "/usr/sbin/sysctl",
                "-n",
                "vm.swapusage",
            ): "total = 6144.00M used = 4761.60M free = 1382.40M\n",
            ("/usr/sbin/sysctl", "-n", "vm.loadavg"): "{ 1.50 2.00 2.50 }\n",
        }
        self.calls = []

    def __call__(self, argv, timeout):
        self.calls.append((argv, timeout))
        return self.values[tuple(argv)]


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.clock = Clock()
        self.queries = Queries()
        self.collector = monitor.Collector(
            runner=self.queries,
            clock=self.clock.now,
            host=lambda: "Darwin",
            disk_usage=lambda _: SimpleNamespace(free=12 * monitor.GIB),
            panic_directories=[Path(self.directory.name)],
        )

    def test_normal_snapshot_preserves_observed_capacity_vm_and_existing_swap(self):
        sample = self.collector.collect()
        self.assertEqual(sample["memory_bytes"], 8 * monitor.GIB)
        self.assertEqual(sample["logical_cpus"], 8)
        self.assertEqual(sample["memory_free_percent"], 58)
        self.assertEqual(sample["vm_pages"]["Swapouts"], 13)
        self.assertEqual(sample["vm_page_size"], 4096)
        self.assertEqual(sample["swap_used_bytes"], int(4761.60 * monitor.MIB))
        self.assertEqual(
            monitor.decide(sample, sample, self.collector.policy, self.clock.now()), []
        )
        self.assertTrue(
            all(isinstance(argv, list) and 0 < timeout <= 2 for argv, timeout in self.queries.calls)
        )

    def test_each_required_query_rejects_malformed_or_missing_output(self):
        for key, original in self.queries.values.copy().items():
            with self.subTest(query=key):
                self.queries.values[key] = "unavailable or changed format"
                with self.assertRaises(monitor.CollectionError):
                    self.collector.collect()
                self.queries.values[key] = original

    def test_panic_identity_detects_new_and_changed_reports_without_reading_contents(self):
        baseline = self.collector.collect()
        report = Path(self.directory.name, "panic-full-2026.ips")
        report.write_text("private panic contents are not emitted")
        sample = self.collector.collect()
        reasons = monitor.decide(sample, baseline, self.collector.policy, self.clock.now())
        self.assertIn("new or changed panic report detected", reasons)
        self.assertNotIn("private panic contents", json.dumps(sample))
        report.write_text("changed report")
        changed = self.collector.collect()
        self.assertNotEqual(changed["panic_identities"], sample["panic_identities"])

    def test_preflight_detects_a_panic_created_during_first_collection(self):
        queries = self.queries

        def report_during_query(argv, timeout):
            Path(self.directory.name, "panic-full-created.ips").write_text("fixture report")
            return queries(argv, timeout)

        self.collector.runner = report_during_query
        records = []
        code = monitor.observe(self.collector, emit=records.append, clock=self.clock.now)
        self.assertEqual(code, 75)
        self.assertTrue(any("panic" in reason for reason in records[-1]["reasons"]))

    def test_missing_or_unreadable_panic_directories_fail_closed(self):
        self.collector.panic_directories = [Path(self.directory.name, "absent")]
        with self.assertRaisesRegex(monitor.CollectionError, "panic-report directory"):
            self.collector.collect()
        self.collector.panic_directories = [Path(self.directory.name)]
        with patch.object(monitor.os, "scandir", side_effect=PermissionError):
            with self.assertRaises(monitor.CollectionError):
                self.collector.collect()

    def test_slow_query_exhausts_sample_budget_without_starting_next_query(self):
        calls = []

        def slow(argv, timeout):
            calls.append(argv)
            self.clock.sleep(6)
            return self.queries(argv, timeout)

        self.collector.runner = slow
        with self.assertRaisesRegex(monitor.CollectionError, "deadline"):
            self.collector.collect()
        self.assertEqual(len(calls), 1)

    def test_timeout_nonzero_and_missing_query_fail_closed(self):
        for failure in [FileNotFoundError(), subprocess.TimeoutExpired(["query"], 2)]:
            with self.subTest(failure=failure):
                with patch.object(monitor.subprocess, "run", side_effect=failure):
                    with self.assertRaises(monitor.CollectionError):
                        monitor.run_query(["/usr/bin/vm_stat"], 2)
        with patch.object(
            monitor.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="")
        ):
            with self.assertRaises(monitor.CollectionError):
                monitor.run_query(["/usr/bin/vm_stat"], 2)

    def test_policy_limits_deny_pressure_disk_swap_load_and_staleness(self):
        baseline = self.collector.collect()
        variants = [
            ({"memory_free_percent": 19}, "memory pressure"),
            ({"disk_free_bytes": int(4.2 * monitor.GIB)}, "disk headroom"),
            (
                {"swap_used_bytes": baseline["swap_used_bytes"] + 256 * monitor.MIB + 1},
                "swap growth",
            ),
            ({"load_averages": [6.01, 2, 2]}, "CPU load"),
            ({"logical_cpus": 4, "load_averages": [3.01, 2, 2]}, "CPU load"),
            ({"collected_monotonic": self.clock.now() - 6}, "sample is stale"),
        ]
        for changes, expected in variants:
            with self.subTest(changes=changes):
                reasons = monitor.decide(
                    baseline | changes, baseline, self.collector.policy, self.clock.now()
                )
                self.assertTrue(any(expected in reason for reason in reasons), reasons)

    def test_reviewed_policy_boundaries_are_inclusive(self):
        baseline = self.collector.collect()
        sample = baseline | {
            "memory_free_percent": 20,
            "disk_free_bytes": 8 * monitor.GIB,
            "swap_used_bytes": baseline["swap_used_bytes"] + 256 * monitor.MIB,
            "load_averages": [6.0, 2, 2],
        }
        self.assertEqual(
            monitor.decide(sample, baseline, self.collector.policy, self.clock.now()), []
        )

    def test_observation_deadline_is_shared_by_queries(self):
        timeouts = []

        def advancing(argv, timeout):
            timeouts.append(timeout)
            self.clock.sleep(0.6)
            return self.queries(argv, timeout)

        self.collector.runner = advancing
        with self.assertRaises(monitor.CollectionError):
            self.collector.collect(deadline=self.clock.now() + 1)
        self.assertEqual(len(timeouts), 2)
        self.assertAlmostEqual(timeouts[0], 1)
        self.assertAlmostEqual(timeouts[1], 0.4)

    def test_observe_latches_deny_after_recovery_and_finishes_at_duration(self):
        collect = self.collector.collect
        calls = []

        def snapshots(**kwargs):
            calls.append(1)
            sample = collect(**kwargs)
            if len(calls) == 1:
                sample["disk_free_bytes"] = 4 * monitor.GIB
            return sample

        self.collector.collect = snapshots
        records = []
        code = monitor.observe(
            self.collector,
            duration=2,
            interval=1,
            emit=records.append,
            clock=self.clock.now,
            sleep=self.clock.sleep,
        )
        self.assertEqual(code, 75)
        self.assertEqual(records[-1]["decision"], "deny")
        self.assertTrue(any(record.get("decision") == "allow" for record in records))
        self.assertEqual(records[-1]["elapsed_seconds"], 2)
        self.assertEqual(records[-1]["samples"], 2, "No collection may begin at the deadline")

    def test_observer_emits_final_after_collection_error_and_cancellation(self):
        records = []
        self.collector.runner = lambda argv, timeout: (_ for _ in ()).throw(
            monitor.CollectionError("fixture unavailable")
        )
        self.assertEqual(
            monitor.observe(self.collector, emit=records.append, clock=self.clock.now), 75
        )
        self.assertEqual(records[-1]["reasons"], ["fixture unavailable"])
        records.clear()
        self.assertEqual(
            monitor.observe(
                self.collector, emit=records.append, clock=self.clock.now, cancelled=lambda: True
            ),
            130,
        )
        self.assertTrue(records[-1]["cancelled"])
        self.assertEqual(records[-1]["samples"], 0)

    def test_observation_cannot_allow_when_deadline_prevents_any_sample(self):
        records = []
        code = monitor.observe(
            self.collector,
            duration=1e-20,
            emit=records.append,
            clock=self.clock.now,
            sleep=self.clock.sleep,
        )
        self.assertEqual(code, 75)
        self.assertEqual(records[-1]["decision"], "deny")
        self.assertEqual(records[-1]["samples"], 0)
        self.assertTrue(records[-1]["reasons"])

    def test_cancellation_during_final_collection_is_reflected_in_final_record(self):
        interrupted = False
        queries = self.queries

        def interrupt_during_query(argv, timeout):
            nonlocal interrupted
            value = queries(argv, timeout)
            if len(queries.calls) == 5:
                interrupted = True
            return value

        self.collector.runner = interrupt_during_query
        records = []
        code = monitor.observe(
            self.collector, emit=records.append, clock=self.clock.now, cancelled=lambda: interrupted
        )
        self.assertEqual(code, 130)
        self.assertTrue(records[-1]["cancelled"])
        self.assertEqual(records[-1]["decision"], "deny")

    def test_panic_during_collection_stops_observation_without_another_query(self):
        queries = self.queries

        def panic_during_query(argv, timeout):
            report = Path(self.directory.name, "panic-new.ips")
            if not report.exists():
                report.write_text("new report")
            return queries(argv, timeout)

        self.collector.runner = panic_during_query
        records = []
        code = monitor.observe(
            self.collector,
            duration=3,
            emit=records.append,
            clock=self.clock.now,
            sleep=self.clock.sleep,
        )
        self.assertEqual(code, 75)
        self.assertEqual(len(queries.calls), 5, "No retry or next sample after a new panic")
        self.assertEqual(records[-1]["decision"], "deny")
        self.assertTrue(records[-1]["fatal_stop"])

    def test_panic_between_samples_stops_before_starting_more_resource_queries(self):
        def sleep_and_report(seconds):
            self.clock.sleep(seconds)
            Path(self.directory.name, "panic-between.ips").write_text("new report")

        records = []
        code = monitor.observe(
            self.collector,
            duration=4,
            emit=records.append,
            clock=self.clock.now,
            sleep=sleep_and_report,
        )
        self.assertEqual(code, 75)
        self.assertEqual(len(self.queries.calls), 5)
        self.assertEqual(records[-1]["decision"], "deny")
        self.assertTrue(records[-1]["fatal_stop"])


class CommandLineTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux proves fail-closed host handling")
    def test_default_preflight_rejects_unsupported_host_with_final_record(self):
        result = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("guard_ios_simulator_resources.py"))],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(records[-1]["event"], "final")
        self.assertEqual(records[-1]["decision"], "deny")
        self.assertIn("unsupported host", records[-1]["reasons"][0])

    def test_cli_accepts_neither_arbitrary_children_nor_threshold_overrides(self):
        script = str(Path(__file__).with_name("guard_ios_simulator_resources.py"))
        for arguments in [
            ["--", "ignored-command"],
            ["--minimum-disk-bytes", "0"],
            ["--observe", "nan"],
            ["--observe", "301"],
            ["--interval", "0"],
        ]:
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [sys.executable, script, *arguments],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                self.assertEqual(result.returncode, 2)

    @unittest.skipUnless(sys.platform.startswith("linux"), "No real macOS queries in tests")
    def test_sigterm_observation_emits_cancelled_final_record(self):
        process = subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).with_name("guard_ios_simulator_resources.py")),
                "--observe",
                "30",
                "--interval",
                "0.1",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            first = process.stdout.readline()
            self.assertEqual(json.loads(first)["event"], "policy")
            process.send_signal(signal.SIGTERM)
            output, errors = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143, errors)
            final = json.loads(output.splitlines()[-1])
            self.assertTrue(final["cancelled"])
            self.assertEqual(final["decision"], "deny")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()
