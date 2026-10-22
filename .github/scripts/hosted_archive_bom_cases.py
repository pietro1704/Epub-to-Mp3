"""Inherited archive assertion cases; loaded by the original unittest classes."""

import hashlib
import json
import os
from pathlib import Path
import signal
from unittest.mock import patch
from hosted_archive_test_fixtures import archive

class HostedArchiveBomCases:
    def test_modes_count_types_without_reporting_paths_or_payload_contents(self):
        self.configure()
        self.assertTrue(self.invoke().is_dir())
        receipt = self.inspector.report["signed_bom_inventories"][0]
        self.assertEqual(receipt, {
            "bom_sha256": hashlib.sha256(b"fixture BOM bytes").hexdigest(),
            "regular": 1, "directory": 1, "symlink": 1, "other": 0,
            "total": 3, "bytes": len(b"100644\n40755\n120777\n"), "complete": True,
            "package_info_sha256": hashlib.sha256(
                b'<pkg-info><payload installKBytes="1024" numberOfFiles="2"/></pkg-info>').hexdigest(),
            "number_of_files": 2})
        self.assertNotIn("fixture BOM bytes", json.dumps(receipt))
        self.assertNotIn(str(self.base), json.dumps(receipt))
        self.assertLess(next(index for index, item in enumerate(self.calls) if item[0] == "/usr/bin/lsbom"),
                        next(index for index, item in enumerate(self.calls) if item[1] == "--payload-files"))

    def test_complete_bom_authorizes_paths_above_default(self):
        self.configure(modes="import sys; sys.stdout.buffer.write(b'100644\\n'*225598+b'40755\\n'*24403)",
                       listing="import sys; sys.stdout.buffer.write(b'Library/file\\n'*250001)",
                       metadata=b'<pkg-info><payload installKBytes="1024" numberOfFiles="225598"/></pkg-info>')
        self.assertTrue(self.invoke().is_dir())
        receipt = self.inspector.report["signed_bom_inventories"][0]
        self.assertEqual(receipt["regular"], 225598)
        self.assertEqual(receipt["directory"], 24403)
        self.assertEqual(receipt["total"], 250001)
        self.assertTrue(receipt["complete"])
        self.assertTrue(self.inspector.report["payload_listing"]["complete"])
        self.assertTrue(any(item[1] == "--expand-full" for item in self.calls))
        self.assertFalse((self.inspector.reports / "active-command.json").exists())
        self.inspector.cleanup()
        self.assertFalse(self.inspector.root.exists())

    def test_observed_bom_budget_accepts_ceiling_and_shorter_complete_listing(self):
        for count in (310784, 7):
            with self.subTest(count=count):
                self.reset_components()
                self.configure_observed_counts(count)
                self.assertTrue(self.invoke().is_dir())
                self.assertEqual(self.inspector.report["payload_listing_budget"], {
                    "source": "complete_signed_component_boms", "entries": 310784, "ceiling": 310784})
                self.assertEqual(self.inspector.report["payload_listing"]["entries"], count)
                self.assertTrue(self.inspector.report["payload_listing"]["complete"])
                self.assertFalse((self.inspector.reports / "active-command.json").exists())
        self.assertEqual(archive.MAX_LISTING_ENTRIES, 250000)
        default = archive.PayloadListing()
        with self.assertRaisesRegex(archive.Blocked, "entry budget"):
            for _ in range(250001):
                default.feed(b"file\n")

    def test_observed_bom_budget_plus_one_blocks_expansion_and_cleans_owned_tree(self):
        self.configure_observed_counts(310785)
        with self.assertRaisesRegex(archive.Blocked, "entry budget"):
            self.invoke()
        self.assertEqual(self.inspector.report["payload_listing"]["entries"], 310785)
        self.assertFalse(self.inspector.report["payload_listing"]["complete"])
        self.assertFalse(any(item[1] == "--expand-full" for item in self.calls))
        self.assertFalse((self.inspector.reports / "active-command.json").exists())
        self.inspector.cleanup()
        self.assertFalse(self.inspector.root.exists())

    def test_invalid_component_counts_never_authorize_listing_or_expansion(self):
        cases = [
            ("print('100644')", b'<pkg-info><payload installKBytes="1024"/></pkg-info>'),
            ("print('100644')", b'<pkg-info><payload installKBytes="1024" numberOfFiles="0"/></pkg-info>'),
            ("print('100644')", b'<pkg-info><payload installKBytes="1024" numberOfFiles="2"/></pkg-info>'),
            ("print('100644\\n10644')", b'<pkg-info><payload installKBytes="1024" numberOfFiles="1"/></pkg-info>'),
            ("print('100644')", b'<pkg-info><payload installKBytes="1024" numberOfFiles="1"/><payload installKBytes="1"/></pkg-info>'),
            ("import sys; sys.stdout.buffer.write(b'100644\\n'+b'40755\\n'*310784)",
             b'<pkg-info><payload installKBytes="1024" numberOfFiles="1"/></pkg-info>'),
        ]
        for modes, metadata in cases:
            with self.subTest(modes=modes, metadata=metadata):
                self.reset_components()
                self.configure(modes=modes, metadata=metadata)
                with self.assertRaises(archive.Blocked):
                    self.invoke()
                self.assertFalse(any(item[1] in ("--payload-files", "--expand-full") for item in self.calls))
                self.assertFalse((self.inspector.reports / "active-command.json").exists())

    def test_file_counts_must_match_each_component_not_only_the_aggregate(self):
        self.configure(metadata=b'<pkg-info><payload installKBytes="1024" numberOfFiles="1"/></pkg-info>')
        command = self.inspector.command
        def paired_components(arguments, **options):
            result = command(arguments, **options)
            if arguments[1] == "--expand":
                component = Path(arguments[-1]) / "second"
                component.mkdir()
                (component / "PackageInfo").write_bytes(
                    b'<pkg-info><payload installKBytes="1024" numberOfFiles="3"/></pkg-info>')
                (component / "Bom").write_bytes(b"second fixture BOM")
            return result
        self.inspector.command = paired_components
        # Each subprocess emits two regular/link entries. The aggregate is four,
        # but neither component matches its own declared count (one and three).
        with self.assertRaisesRegex(archive.Blocked, "counts do not match"):
            self.invoke()
        self.assertFalse(any(item[1] in ("--payload-files", "--expand-full") for item in self.calls))

    def test_package_info_replacement_between_disk_budget_and_bom_is_rejected(self):
        self.configure()
        inspect = self.inspector.inspect_bom_modes
        replacement = b'<pkg-info><payload installKBytes="2048" numberOfFiles="2"/></pkg-info>'
        def replace_after_snapshot(flat, *snapshots):
            (flat / "replacement").write_bytes(replacement)
            os.replace(flat / "replacement", flat / "PackageInfo")
            # Reports are receipts only: changing one cannot authorize the new
            # file or replace the private snapshot used for the disk budget.
            self.inspector.report["package_payload_metadata"][0]["install_bytes"] = 2048 * 1024
            return inspect(flat, *snapshots)
        with patch.object(self.inspector, "inspect_bom_modes", side_effect=replace_after_snapshot):
            with self.assertRaisesRegex(archive.Blocked, "declared payload snapshot"):
                self.invoke()
        self.assertFalse(any(item[1] in ("--payload-files", "--expand-full") for item in self.calls))
        self.assertFalse((self.inspector.reports / "active-command.json").exists())

    def test_derived_budget_keeps_byte_limit_and_stream_failure_gates(self):
        cases = [
            ("print('unfinished',end='',flush=True)", None),
            ("import sys; print('valid',flush=True); sys.exit(7)", None),
            ("import sys; print('valid',flush=True); sys.exit(130)", None),
            ("import sys; print('valid',flush=True); sys.exit(143)", None),
            ("import time; print('valid',flush=True); time.sleep(30)", None),
            ("print('x'*100,flush=True)", 64),
            ("print('../outside',flush=True)", None),
        ]
        for script, byte_limit in cases:
            with self.subTest(script=script):
                self.reset_components()
                self.configure(listing=script)
                command = self.inspector.command
                def bounded(arguments, **options):
                    if arguments[1] == "--payload-files":
                        options["timeout"] = 1
                    return command(arguments, **options)
                self.inspector.command = bounded
                with patch.object(archive.contracts, "MAX_LISTING_BYTES", byte_limit or 64 * 1024**2):
                    with self.assertRaises(archive.Blocked):
                        self.invoke()
                self.assertFalse(any(item[1] == "--expand-full" for item in self.calls))
                self.assertFalse(self.inspector.report["payload_listing"]["complete"])
                self.assertFalse((self.inspector.reports / "active-command.json").exists())

    def test_derived_budget_monitor_cancellation_stops_child_before_expansion(self):
        self.configure(listing="import time; print('valid',flush=True); time.sleep(30)")
        command = self.inspector.command
        def cancellable(arguments, **options):
            if arguments[1] == "--payload-files":
                options["monitor"] = lambda: archive.interrupt(signal.SIGTERM, None)
            return command(arguments, **options)
        self.inspector.command = cancellable
        with self.assertRaisesRegex(archive.Blocked, "interrupted by signal"):
            self.invoke()
        self.assertFalse(any(item[1] == "--expand-full" for item in self.calls))
        self.assertFalse(self.inspector.report["payload_listing"]["complete"])
        self.assertFalse((self.inspector.reports / "active-command.json").exists())

    def test_diagnostic_failure_blocks_listing_and_expansion_and_cleans_owned_child(self):
        for script in ["print('../escape')", "print('100888')", "print('0')",
                       "print('100644',end='')", "import sys; print('100644'); sys.exit(7)",
                       "import time; print('100644',flush=True); time.sleep(30)"]:
            with self.subTest(script=script):
                flat = self.inspector.root / "flat"
                if flat.exists():
                    archive.shutil.rmtree(flat)
                self.calls.clear()
                self.configure(modes=script)
                with self.assertRaises(archive.Blocked):
                    self.invoke()
                self.assertFalse(self.inspector.report["signed_bom_inventories"][0]["complete"])
                self.assertFalse(any(item[1] in ("--payload-files", "--expand-full") for item in self.calls))
                self.assertFalse((self.inspector.reports / "active-command.json").exists())

    def test_missing_escaping_or_changed_bom_identity_never_reaches_listing(self):
        for layout, changed in [("missing", False), ("missing_info", False), ("orphan", False),
                                ("escape", False), ("regular", True), ("regular", "info")]:
            with self.subTest(layout=layout, changed=changed):
                flat = self.inspector.root / "flat"
                if flat.exists():
                    archive.shutil.rmtree(flat)
                self.calls.clear()
                self.configure(layout=layout, changed=changed)
                with self.assertRaises((archive.Blocked, OSError)):
                    self.invoke()
                self.assertFalse(any(item[1] in ("--payload-files", "--expand-full") for item in self.calls))
                if changed:
                    self.assertFalse(self.inspector.report["signed_bom_inventories"][0]["complete"])
                if layout == "escape":
                    self.assertEqual((self.base / "outside").read_bytes(), b"preserve foreign bytes")

    def test_unknown_hosted_manual_cannot_authorize_bom_query(self):
        self.configure(manual=b"unknown flags")
        with self.assertRaisesRegex(archive.Blocked, "manual"):
            self.invoke()
        self.assertFalse(any(item[0] == "/usr/bin/lsbom" or item[1] in ("--payload-files", "--expand-full")
                             for item in self.calls))

    def test_mode_stream_fragmentation_and_existing_byte_budget(self):
        consumer = archive.BomModes("a" * 64)
        for value in b"100644\n40755\n":
            consumer.feed(bytes([value]))
        self.assertEqual(consumer.finish(), 2)
        with patch.object(archive.contracts, "MAX_LISTING_BYTES", 6):
            consumer = archive.BomModes("a" * 64)
            with self.assertRaises(archive.Blocked):
                consumer.feed(b"100644\n")
            self.assertFalse(consumer.receipt()["complete"])
