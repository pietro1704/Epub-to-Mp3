"""Host archive process contracts; mocks do not establish Apple runtime trust."""

import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from contextlib import contextmanager
from unittest.mock import patch
from hosted_archive_test_fixtures import REAL_APPLE_SIGNATURE as REAL_APPLE_SIGNATURE, REAL_ATTACH_HELP as REAL_ATTACH_HELP, archive as archive

from hosted_archive_bom_cases import HostedArchiveBomCases
from hosted_archive_http_cases import HostedArchiveHttpCases
from hosted_archive_ownership_cases import HostedArchiveOwnershipCases
from hosted_archive_process_cases import HostedArchiveProcessCases
from hosted_archive_trust_cases import HostedArchiveTrustCases


class ArchiveSafetyTests(HostedArchiveHttpCases, HostedArchiveOwnershipCases, HostedArchiveProcessCases, HostedArchiveTrustCases, unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="archive-safety-fixture-")
        self.base = Path(self.temporary.name)
        self.inspector = archive.Inspector(self.base, self.base / "reports")

    def tearDown(self):
        self.temporary.cleanup()







    def http_command(self, method, headers, body=b"", status=0, missing_headers=False):
        def command(arguments, **options):
            self.assertEqual(arguments[-1], archive.URL)
            self.assertEqual("--head" in arguments, method == "HEAD")
            self.assertEqual(arguments[arguments.index("--proto") + 1], "=https")
            self.assertEqual(arguments[arguments.index("--max-redirs") + 1], "0")
            self.assertTrue(options["allow_failure"])
            if not missing_headers:
                Path(arguments[arguments.index("--dump-header") + 1]).write_bytes(headers)
            Path(arguments[arguments.index("--output") + 1]).write_bytes(body)
            code = 206 if b"HTTP/2 206" in headers else 200
            return f"\nhttp_code={code}\nurl_effective={archive.URL}\n".encode(), status
        return command









    def capability_command(self, mode, calls):
        def command(arguments, **_):
            calls.append(arguments)
            if arguments == ["/usr/sbin/pkgutil", "--help"]:
                return b"--check-signature --payload-files --expand\n"
            if arguments == ["/usr/bin/hdiutil", "attach", "-help"]:
                return REAL_ATTACH_HELP.replace(b"-[no]autoopen", b"-autoopen") if mode == "missing-noautoopen" else REAL_ATTACH_HELP
            if arguments == ["/usr/bin/man", "-P", "/bin/cat", "hdiutil"]:
                self.assertEqual(_["timeout"], 15)
                if mode == "failed-man":
                    raise archive.Blocked("Fixture man failed")
                if mode == "absent-man":
                    raise FileNotFoundError("Fixture man unavailable")
                if mode == "missing-nobrowse":
                    return b"HDIUTIL(1)\n-browse-never-trusted\n"
                if mode == "empty-man":
                    return b""
                rendered = "".join(f"{char}\b{char}" for char in "-nobrowse")
                return f"HDIUTIL(1)\n  {rendered}\nDo not make the volume browsable.\n".encode()
            if arguments[0] == "/usr/bin/pkgbuild":
                source = Path(arguments[arguments.index("--root") + 1])
                self.assertEqual([item.name for item in source.iterdir()], ["legacy-archive-probe.txt"])
                self.assertFalse((source / "legacy-archive-probe.txt").stat().st_mode & 0o111)
                self.assertNotIn("--scripts", arguments)
                self.assertEqual(arguments[arguments.index("--install-location") + 1], "/")
                Path(arguments[-1]).write_bytes(b"owned unsigned package fixture")
                return b""
            if arguments[:2] == ["/usr/sbin/pkgutil", "--expand-full"]:
                if mode == "unsupported":
                    raise archive.Blocked("Fixture tool rejects expand-full")
                output = Path(arguments[-1])
                payload = output / "Payload"
                payload.mkdir(parents=True)
                filename = payload / "legacy-archive-probe.txt"
                if mode == "symlink":
                    filename.symlink_to(output.parent / "source/legacy-archive-probe.txt")
                else:
                    filename.write_bytes(b"wrong bytes" if mode == "wrong-bytes" else b"Legacy archive extraction capability probe.\n")
                if mode == "extra-path":
                    (payload / "unexpected.txt").write_bytes(b"unexpected")
                return b""
            self.fail(f"Unexpected command or download reached: {arguments}")
        return command



























class BomDiagnosticTests(HostedArchiveBomCases, unittest.TestCase):
    # Formatting fixture only. The real hosted Apple manual must independently
    # establish -p m before any real BOM query; this text proves no Apple trust.
    MANUAL = b"-p parameters\nmode (octal)\nm file mode (permissions)\n"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.inspector = archive.Inspector(self.base, self.base / "reports")
        self.original = self.inspector.command
        self.calls = []

    def configure(self, modes="print('100644\\n40755\\n120777')", *,
                  listing="print('Library/file')", layout="regular", manual=None, changed=False,
                  metadata=b'<pkg-info><payload installKBytes="1024" numberOfFiles="2"/></pkg-info>'):
        def command(arguments, **options):
            self.calls.append(tuple(arguments[:3]))
            if arguments[1] == "--check-signature":
                return REAL_APPLE_SIGNATURE.encode()
            if arguments[1] == "--expand":
                flat = Path(arguments[-1])
                flat.mkdir()
                if layout != "missing_info":
                    (flat / "PackageInfo").write_bytes(metadata)
                if layout not in ("missing", "escape"):
                    (flat / "Bom").write_bytes(b"fixture BOM bytes")
                if layout == "orphan":
                    orphan = flat / "orphan"
                    orphan.mkdir()
                    (orphan / "Bom").write_bytes(b"unpaired BOM")
                if layout == "escape":
                    outside = self.base / "outside"
                    outside.write_bytes(b"preserve foreign bytes")
                    (flat / "Bom").symlink_to(outside)
                return b""
            if arguments[0] == "/usr/bin/man":
                self.assertEqual(arguments, ["/usr/bin/man", "-P", "/bin/cat", "lsbom"])
                return self.MANUAL if manual is None else manual
            if arguments[0] == "/usr/bin/lsbom":
                self.assertEqual(arguments[1:3], ["-p", "m"])
                self.assertTrue(self.inspector.report["signature_verified"])
                options["timeout"] = 1 if "sleep(30)" in modes else 20
                result = self.original([sys.executable, "-c", modes], **options)
                if changed == "info":
                    Path(arguments[-1]).with_name("PackageInfo").write_bytes(metadata + b"\n")
                elif changed:
                    Path(arguments[-1]).write_bytes(b"changed BOM identity")
                return result
            if arguments[1] == "--payload-files":
                return self.original([sys.executable, "-c", listing], **options)
            if arguments[1] == "--expand-full":
                destination = Path(arguments[-1])
                destination.mkdir()
                return b""
            self.fail("Unexpected fixture command")
        self.inspector.command = command

    def invoke(self):
        with patch.object(archive.inspection, "disk_gate", return_value=100 * archive.GIB):
            return self.inspector.verify_and_expand(self.inspector.mount / "runtime.pkg")



    def reset_components(self):
        for name in ("flat", "expanded"):
            directory = self.inspector.root / name
            if directory.exists():
                archive.shutil.rmtree(directory)
        self.calls.clear()

    def configure_observed_counts(self, listing_count):
        self.configure(
            modes="import sys; sys.stdout.buffer.write(b'100644\\n'*225519+b'40755\\n'*85186+b'120777\\n'*79)",
            listing=f"import sys; sys.stdout.buffer.write(b'Library/file\\n'*{listing_count})",
            metadata=b'<pkg-info><payload installKBytes="11546951" numberOfFiles="225598"/></pkg-info>')













class RuntimeLayoutDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.inspector = archive.Inspector(self.base, self.base / "reports")
        self.expanded = self.inspector.root / "expanded"
        self.expanded.mkdir()

    def blocked_discovery(self):
        with self.assertRaisesRegex(archive.Blocked, "Expected one legacy runtime in the package"):
            self.inspector.inspect_runtime(self.expanded)
        return self.inspector.report["runtime_directory_candidates"]

    def test_zero_candidates_records_relative_shallow_layout_without_new_selection(self):
        payload = self.expanded / "Payload"
        (payload / "Contents").mkdir(parents=True)
        (payload / "Contents" / "Info.plist").write_bytes(b"not collected")
        self.assertEqual(self.blocked_discovery()["count"], 0)
        records = self.inspector.report["expanded_layout"]["records"]
        self.assertEqual(records, [{"path": "Payload", "kind": "directory"},
                                   {"path": "Payload/Contents", "kind": "directory"}])
        self.assertNotIn("not collected", json.dumps(self.inspector.report))
        self.assertNotIn(str(self.base), json.dumps(self.inspector.report))

    def test_multiple_candidates_remain_blocked_and_sample_is_bounded(self):
        for index in range(10):
            (self.expanded / f"runtime-{index}.simruntime").mkdir()
        discovery = self.blocked_discovery()
        self.assertEqual(discovery["count"], 10)
        self.assertEqual(len(discovery["sample"]), 8)
        self.assertEqual(discovery["sample_omitted"], 2)
        self.assertTrue(all(item["kind"] == "directory" and "/" not in item["path"]
                            for item in discovery["sample"]))

    def test_exactly_one_candidate_still_requires_original_runtime_identity(self):
        runtime = self.expanded / "one.simruntime"
        contents = runtime / "Contents"
        system = contents / "Resources/RuntimeRoot/System/Library/CoreServices"
        system.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "foreign.bundle"}))
        (system / "SystemVersion.plist").write_bytes(plistlib.dumps(
            {"ProductVersion": "15.5", "ProductBuildVersion": "19F70"}))
        with self.assertRaisesRegex(archive.Blocked, "runtime identity differs"):
            self.inspector.inspect_runtime(self.expanded)
        self.assertEqual(self.inspector.report["runtime_directory_candidates"], {
            "count": 1, "sample": [{"path": "one.simruntime", "kind": "directory"}], "sample_omitted": 0})
        self.assertNotIn("expanded_layout", self.inspector.report)

    def test_symlinks_and_control_paths_do_not_expose_or_change_foreign_tree(self):
        foreign = self.base / "foreign"
        foreign.mkdir()
        sentinel = foreign / "private-name"
        sentinel.write_bytes(b"preserve foreign bytes")
        (self.expanded / "linked.simruntime").symlink_to(foreign)
        (self.expanded / "control\nname").write_bytes(b"not collected")
        self.assertEqual(self.blocked_discovery()["count"], 0)
        layout = self.inspector.report["expanded_layout"]
        self.assertEqual(layout["records"], [{"path": "linked.simruntime", "kind": "symlink"}])
        self.assertEqual(layout["invalid_paths"], 1)
        self.assertEqual(sentinel.read_bytes(), b"preserve foreign bytes")
        self.assertNotIn("private-name", json.dumps(layout))
        self.assertNotIn("control", json.dumps(layout))
        with self.assertRaises(archive.Blocked):
            archive.diagnostic_path(Path("."), Path("x" * 4097))

    def test_layout_record_scan_byte_and_time_limits_are_explicit(self):
        for index in range(70):
            (self.expanded / f"file-{index}").touch()
        self.blocked_discovery()
        layout = self.inspector.report["expanded_layout"]
        self.assertEqual(len(layout["records"]), 64)
        self.assertLessEqual(layout["scanned"], 256)
        self.assertTrue(layout["truncated"])
        with patch.object(archive.contracts, "LAYOUT_BYTES", 256):
            layout = self.inspector.runtime_layout(self.expanded)
        self.assertTrue(layout["truncated"])
        self.assertLessEqual(len(json.dumps({"expanded_layout": layout}, indent=2).encode()), 256)
        with patch.object(archive.time, "monotonic", side_effect=[0, 2]):
            layout = self.inspector.runtime_layout(self.expanded)
        self.assertTrue(layout["truncated"])
        self.assertEqual(layout["scanned"], 0)
        with patch.object(archive.contracts, "LAYOUT_SCANNED", 2), patch.object(archive.contracts, "LAYOUT_RECORDS", 64):
            layout = self.inspector.runtime_layout(self.expanded)
        self.assertTrue(layout["truncated"])
        self.assertEqual(layout["scanned"], 2)

    def test_final_invalid_path_counters_cannot_overflow_the_receipt_byte_budget(self):
        (self.expanded / "valid").touch()
        initial = self.inspector.runtime_layout(self.expanded)
        budget = len(json.dumps({"expanded_layout": initial}, indent=2).encode())
        for index in range(10):
            (self.expanded / f"invalid\n{index}").touch()
        real_scandir = archive.os.scandir

        @contextmanager
        def valid_first(descriptor):
            with real_scandir(descriptor) as entries:
                observed = []
                for entry in entries:
                    entry.stat(follow_symlinks=False)
                    observed.append(entry)
                yield iter(sorted(observed, key=lambda entry: entry.name != "valid"))

        # Cache actual lstat results while the iterator is open, then control
        # ordering so both final counters gain a digit after the valid record.
        with patch.object(archive.os, "scandir", side_effect=valid_first), \
                patch.object(archive.contracts, "LAYOUT_BYTES", budget):
            layout = self.inspector.runtime_layout(self.expanded)
        self.assertEqual(layout["scanned"], 11)
        self.assertEqual(layout["invalid_paths"], 10)
        self.assertEqual(layout["records"], [])
        self.assertTrue(layout["truncated"])
        self.assertLessEqual(len(json.dumps({"expanded_layout": layout}, indent=2).encode()), budget)
        self.inspector.report["expanded_layout"] = layout
        fragment = "\n".join(json.dumps({"expanded_layout": layout}, indent=2).splitlines()[1:-1])
        self.assertIn(fragment, json.dumps(self.inspector.report, indent=2))
        self.assertLessEqual(len(fragment.encode()), budget)

    def test_diagnostic_io_failure_preserves_original_runtime_blocker(self):
        with patch.object(archive.os, "open", side_effect=PermissionError("private diagnostic path")):
            self.blocked_discovery()
        self.assertEqual(self.inspector.report["expanded_layout"], {
            "error_type": "PermissionError", "truncated": True})
        self.assertNotIn("private diagnostic path", json.dumps(self.inspector.report))

    def test_install_location_is_same_read_enums_and_hash_never_a_path_to_open(self):
        info = self.expanded / "PackageInfo"
        for location, form, suffix in [(None, "missing", False),
                                        ("/Library/private.simruntime", "absolute", True),
                                        ("relative/private.simruntime", "relative", True),
                                        ("../private", "invalid", False),
                                        ("private\npath", "invalid", False)]:
            with self.subTest(form=form, location=location):
                root = archive.ET.Element("pkg-info")
                if location is not None:
                    root.set("install-location", location)
                archive.ET.SubElement(root, "payload", installKBytes="1024", numberOfFiles="1")
                raw = archive.ET.tostring(root)
                info.write_bytes(raw)
                metadata, _ = archive.package_info_metadata(self.expanded, info)
                self.assertEqual(metadata["package_info_sha256"], hashlib.sha256(raw).hexdigest())
                self.assertEqual(metadata["install_location"], {
                    "form": form, "simruntime_suffix": suffix,
                    "sha256": hashlib.sha256(location.encode()).hexdigest() if location is not None else None})
                if location:
                    self.assertNotIn(location, json.dumps(metadata))


if __name__ == "__main__":
    unittest.main()
