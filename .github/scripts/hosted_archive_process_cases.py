"""Inherited archive assertion cases; loaded by the original unittest classes."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest.mock import patch
from hosted_archive_test_fixtures import REAL_APPLE_SIGNATURE, archive

class HostedArchiveProcessCases:
    def test_unconfirmed_child_completion_never_kills_a_recorded_pid_or_deletes(self):
        registry = self.inspector.reports / "active-command.json"
        registry.write_text(json.dumps({"pid": os.getpid(), "tool": "inconclusive"}))
        with patch.object(archive.os, "killpg") as kill:
            with self.assertRaisesRegex(archive.Blocked, "completion is unconfirmed"):
                self.inspector.cleanup()
            kill.assert_not_called()
        self.assertTrue(self.inspector.root.exists())

    @unittest.skipUnless(sys.platform == "linux", "Cancellation liveness uses Linux /proc on the hosted unit-test job")
    def test_real_monitor_cancellation_stops_owned_descendant_without_touching_foreign_process(self):
        pidfile = self.inspector.root / "child.json"
        foreign = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], start_new_session=True)
        child_script = (
            "import signal,time,os,json; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            f"p={str(pidfile)!r}; open(p+'.tmp','w').write(json.dumps(os.getpid())); os.replace(p+'.tmp',p); time.sleep(30)"
        )
        parent_script = (
            "import subprocess,sys,time; "
            f"child=subprocess.Popen([sys.executable,'-c',{child_script!r}]); "
            "time.sleep(30)"
        )
        def cancel_when_started():
            if pidfile.exists():
                raise archive.Blocked("fixture monitor cancellation")
        try:
            with self.assertRaisesRegex(archive.Blocked, "fixture monitor cancellation"):
                self.inspector.command([sys.executable, "-c", parent_script], timeout=10,
                                       monitor=cancel_when_started, consumer=archive.PayloadListing())
            self.assertIsNone(foreign.poll())
            self.assertTrue(pidfile.exists())
            pid = json.loads(pidfile.read_text())
            self.assertIsInstance(pid, int)
            self.assertGreater(pid, 1)
            self.assertNotIn(pid, (os.getpid(), foreign.pid))
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    state = Path(f"/proc/{pid}/stat").read_text().split()[2]
                    if state == "Z":
                        break
                except FileNotFoundError:
                    break
                time.sleep(0.05)
            else:
                self.fail("Owned descendant survived timeout cancellation")
        finally:
            foreign.terminate()
            foreign.wait(timeout=3)

    def test_owned_command_timeout_is_fatal_and_clears_completion_registry(self):
        with self.assertRaisesRegex(archive.Blocked, "time/log budget"):
            self.inspector.command([sys.executable, "-c", "import time; time.sleep(30)"], timeout=0.1)
        self.assertFalse((self.inspector.reports / "active-command.json").exists())

    def test_real_stream_larger_than_log_budget_retains_only_aggregate_receipt(self):
        line = b"./Contents/" + b"x" * 110 + b"\n"
        count = 150_000
        self.assertGreater(len(line) * count, archive.MAX_LOG)
        script = f"import sys; line={line!r}; [sys.stdout.buffer.write(line*1000) for _ in range({count // 1000})]"
        listing = archive.PayloadListing()
        result = self.inspector.command([sys.executable, "-c", script], timeout=20, consumer=listing)
        digest = hashlib.sha256()
        for _ in range(count):
            digest.update(line)
        self.assertEqual(result, count)
        self.assertEqual(self.inspector.report["payload_listing"], {
            "entries": count, "bytes": count * len(line),
            "sha256_observed_listing_receipt": digest.hexdigest(), "complete": True})
        self.assertEqual(listing.pending, b"")
        self.assertEqual(next(self.inspector.reports.glob("*-*.log")).read_bytes(), b"")
        self.assertNotIn("Contents", json.dumps(self.inspector.report["payload_listing"]))

    def test_selector_failure_stops_started_child_and_clears_registry(self):
        ready = self.inspector.root / "selector-ready"
        launched = []
        real_popen = subprocess.Popen

        def capture(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            launched.append(child)
            return child

        def fail_selector():
            deadline = time.monotonic() + 5
            while not ready.exists():
                if time.monotonic() >= deadline:
                    self.fail("Controlled child did not become ready")
                time.sleep(0.01)
            self.assertTrue(
                (self.inspector.reports / "active-command.json").exists()
            )
            raise OSError("selector fixture failure")

        script = (
            "import os,time; "
            f"p={str(ready)!r}; "
            "open(p+'.tmp','w').write('ready'); "
            "os.replace(p+'.tmp',p); time.sleep(30)"
        )
        try:
            with (
                patch.object(archive.subprocess, "Popen", side_effect=capture),
                patch.object(
                    archive.selectors, "DefaultSelector", side_effect=fail_selector
                ),
            ):
                with self.assertRaisesRegex(OSError, "selector fixture failure"):
                    self.inspector.command(
                        [sys.executable, "-c", script],
                        timeout=10, consumer=archive.PayloadListing()
                    )
            self.assertEqual(len(launched), 1)
            self.assertIsNotNone(launched[0].poll())
            self.assertTrue(launched[0].stdout.closed)
            self.assertFalse(
                (self.inspector.reports / "active-command.json").exists()
            )
            self.assertNotIn("payload_listing", self.inspector.report)
        finally:
            for child in launched:
                archive.Inspector.stop(child)

    def test_real_stream_errors_keep_partial_receipt_and_do_not_finalize(self):
        scripts = [
            "import sys; print('valid',flush=True); sys.exit(7)",
            "print('../escape',flush=True)",
            "import sys,time; print('valid',flush=True); time.sleep(30)",
            "import sys; print('unterminated',end='',flush=True)",
        ]
        for script in scripts:
            with self.subTest(script=script):
                with self.assertRaises(archive.Blocked):
                    self.inspector.command([sys.executable, "-c", script], timeout=2, consumer=archive.PayloadListing())
                self.assertFalse(self.inspector.report["payload_listing"]["complete"])
                self.assertGreater(self.inspector.report["payload_listing"]["bytes"], 0)
                self.assertFalse((self.inspector.reports / "active-command.json").exists())

    def test_receipt_write_failure_does_not_mask_stream_validation_failure(self):
        class FailingReceipt(dict):
            def __setitem__(self, key, value):
                if key == "payload_listing":
                    raise OSError("receipt disk failure")
                super().__setitem__(key, value)

        self.inspector.report = FailingReceipt(self.inspector.report)
        with self.assertRaisesRegex(archive.Blocked, "Unsafe package payload path"):
            self.inspector.command(
                [sys.executable, "-c", "print('../escape',flush=True)"],
                timeout=2, consumer=archive.PayloadListing())
        self.assertFalse((self.inspector.reports / "active-command.json").exists())

    def test_successful_stream_requires_receipt_persistence(self):
        class FailingReceipt(dict):
            def __setitem__(self, key, value):
                if key == "payload_listing":
                    raise OSError("receipt disk failure")
                super().__setitem__(key, value)

        self.inspector.report = FailingReceipt(self.inspector.report)
        with self.assertRaisesRegex(OSError, "receipt disk failure"):
            self.inspector.command(
                [sys.executable, "-c", "print('valid',flush=True)"],
                timeout=2, consumer=archive.PayloadListing())
        self.assertFalse((self.inspector.reports / "active-command.json").exists())

    def test_real_stream_waits_for_eof_when_exited_leader_has_pipe_holding_descendant(self):
        # The descendant inherits stdout; a leader exit must not finalize early.
        child = "import time; time.sleep(30)"
        script = f"import subprocess,sys; print('valid',flush=True); subprocess.Popen([sys.executable,'-c',{child!r}])"
        with self.assertRaisesRegex(archive.Blocked, "time/log budget"):
            self.inspector.command([sys.executable, "-c", script], timeout=2, consumer=archive.PayloadListing())
        self.assertFalse(self.inspector.report["payload_listing"]["complete"])
        self.assertFalse((self.inspector.reports / "active-command.json").exists())

    def test_signed_metadata_survives_real_listing_failure_overflow_and_timeout(self):
        original = self.inspector.command
        metadata = b'<pkg-info><payload installKBytes="1024" numberOfFiles="3"/></pkg-info>'
        scripts = ["print('../escape',flush=True)", "print('a\\nb\\nc',flush=True)",
                   "import time; print('valid',flush=True); time.sleep(30)"]
        for script in scripts:
            with self.subTest(script=script):
                calls = []
                def command(arguments, **options):
                    calls.append(arguments[1])
                    if arguments[1] == "--check-signature":
                        return REAL_APPLE_SIGNATURE.encode()
                    if arguments[1] == "--expand":
                        destination = Path(arguments[-1])
                        destination.mkdir()
                        (destination / "PackageInfo").write_bytes(metadata)
                        return b""
                    if arguments[1] == "--payload-files":
                        options["timeout"] = 1
                        return original([sys.executable, "-c", script], **options)
                    self.fail("Full payload extraction was reached after rejected listing")
                self.inspector.command = command
                with patch.object(archive.inspection, "disk_gate", return_value=100 * archive.GIB), \
                        patch.object(archive.contracts, "MAX_LISTING_ENTRIES", 2), \
                        patch.object(self.inspector, "inspect_bom_modes", return_value=2):
                    with self.assertRaises(archive.Blocked):
                        self.inspector.verify_and_expand(self.inspector.mount / "runtime.pkg")
                self.assertEqual(calls, ["--check-signature", "--expand", "--payload-files"])
                self.assertEqual(self.inspector.report["package_payload_metadata"], [{
                    "package_info_sha256": hashlib.sha256(metadata).hexdigest(),
                    "install_bytes": 1024**2, "number_of_files": 3,
                    "install_location": {"form": "missing", "simruntime_suffix": False, "sha256": None}}])
                self.assertEqual(self.inspector.report["declared_payload_bytes"], 1024**2)
                self.assertTrue(self.inspector.report["signature_verified"])
                self.assertFalse(self.inspector.report["payload_listing"]["complete"])
                self.assertFalse((self.inspector.root / "flat").exists())
                self.assertFalse((self.inspector.reports / "active-command.json").exists())
