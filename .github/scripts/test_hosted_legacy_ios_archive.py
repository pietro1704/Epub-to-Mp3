"""Host fixtures only. Mocks never establish Apple trust or runtime compatibility."""

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import contextmanager
from unittest.mock import patch

SOURCE = Path(__file__).with_name("hosted-legacy-ios-archive.py")
SPEC = importlib.util.spec_from_file_location("legacy_archive", SOURCE)
archive = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archive)

# Exact hosted attach-help receipt from run38906144750/63a3ed6, 03-hdiutil.log.
# Its bracketed autoopen spelling and omitted nobrowse exposed the real gate bug.
REAL_ATTACH_HELP = b"""hdiutil attach: attach disk image
Usage:\thdiutil attach <image>
\tDevice options:
\t    -readonly\t\tforce read-only
\t    -kernel\t\tattempt to attach the image in-kernel

\tMount options:
\t    -mount required|optional|suppressed\t\tmount volumes?
\t    -nomount\t\tsame as -mount suppressed
\t    -mountpoint <path>\tmount at <path> instead of inside /Volumes
\t    -mountroot <path>\tmount volumes on <path>/<volname>
\t    -mountrandom <path>\tmount volumes on <path>/<random>

\tProcessing options (defaults per framework preferences):
\t    -[no]verify\t\t(do not) verify image checksums
\t    -[no]autofsck\t(do not) perform automatic filesystem checks
\t    -[no]autoopen\t(do not) open root of new mounts

\tCommon options:
\t    -encryption <crypto method>
\t    \tAES-128 - 128-bit AES encryption
\t    \tAES-256 - 256-bit AES encryption (recommended)
\t    -stdinpass
\t    -agentpass
\t    -recover <keychain-file>
\t    -imagekey <key>=<value>
\t    -drivekey <key>=<value>
\t    -shadow <shadowfile>
\t    -insecurehttp
\t    -cacert <file | dir>
\t    -plist
\t    -puppetstrings
\t    -verbose
\t    -debug
\t    -quiet
"""


# Entire real pkgutil receipt, run38909806259/66ce7ec, 10-pkgutil.log.
# This fixture validates parsing only, never cryptographic authenticity.
REAL_APPLE_SIGNATURE = """Package "iPhoneSimulatorSDK15_5.pkg":
   Status: signed Apple Software (Development)
   Signed with a trusted timestamp on: 2022-05-26 01:15:02 +0000
   Certificate Chain:
    1. Development Update
       Expires: 2029-04-14 21:28:23 +0000
       SHA256 Fingerprint:
           D8 F1 22 D9 79 88 EB 12 D7 13 7B BD 53 74 E5 5A 9C 4B 38 F5 3D 25 
           56 62 27 74 E2 3D DD 55 D3 6A
       ------------------------------------------------------------------------
    2. Apple Software Update Certification Authority
       Expires: 2031-10-15 00:00:00 +0000
       SHA256 Fingerprint:
           12 99 E9 BF E7 76 A2 9F F4 52 F8 C4 F5 E5 5F 3B 4D FD 29 34 34 9D 
           D1 85 0B 82 74 F3 5C 71 74 5C
       ------------------------------------------------------------------------
    3. Apple Root CA
       Expires: 2035-02-09 21:40:36 +0000
       SHA256 Fingerprint:
           B0 B1 73 0E CB C7 FF 45 05 14 2C 49 F1 29 5E 6E DA 6B CA ED 7E 2C 
           68 C5 BE 91 B5 A1 10 01 F0 24

"""


class ArchiveSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="archive-safety-fixture-")
        self.base = Path(self.temporary.name)
        self.inspector = archive.Inspector(self.base, self.base / "reports")

    def tearDown(self):
        self.temporary.cleanup()

    def test_owned_cleanup_preserves_unrelated_bytes_and_rejects_symlink_root(self):
        unrelated = self.base / "unrelated"
        unrelated.mkdir()
        (unrelated / "keep").write_bytes(b"preserve")
        self.inspector.cleanup()
        self.assertFalse(self.inspector.root.exists())
        self.assertEqual((unrelated / "keep").read_bytes(), b"preserve")
        link = self.base / "legacy-ios-archive-owned-link"
        link.symlink_to(unrelated, target_is_directory=True)
        self.inspector.root = link
        with self.assertRaises(archive.Blocked):
            self.inspector.cleanup()
        self.assertTrue(unrelated.exists())

    def test_registry_cleanup_cannot_target_unrelated_or_forged_directories(self):
        registry = self.inspector.reports / "owned-root.json"
        unrelated = self.base / "unrelated"
        unrelated.mkdir()
        (unrelated / ".owned").write_text(archive.MARKER)
        registry.write_text(json.dumps({"root": str(unrelated)}))
        with self.assertRaises(archive.Blocked):
            archive.Inspector.recover_cleanup(self.base, self.inspector.reports)
        self.assertTrue(unrelated.exists())

    def test_marker_mismatch_and_payload_symlink_refuse_cleanup_or_read(self):
        (self.inspector.root / ".owned").write_text("wrong marker")
        with self.assertRaises(archive.Blocked):
            self.inspector.cleanup()
        outside = self.base / "outside.plist"
        outside.write_text("outside")
        linked = self.inspector.root / "linked"
        linked.symlink_to(outside)
        with self.assertRaises(archive.Blocked):
            archive.within(self.inspector.root, linked)
        self.assertEqual(outside.read_text(), "outside")

    def test_disk_reserve_and_declared_expansion_bounds(self):
        usage = lambda free: lambda _: type("Usage", (), {"free": free})()
        self.assertEqual(archive.disk_gate(self.base, 1024, usage(archive.RESERVE + 1024)), archive.RESERVE + 1024)
        for additional, free in [(1024, archive.RESERVE), (-1, archive.RESERVE), (archive.MAX_PAYLOAD + archive.SIZE + 1, 10**15)]:
            with self.assertRaises(archive.Blocked):
                archive.disk_gate(self.base, additional, usage(free))
        flat = self.inspector.root / "flat"
        flat.mkdir()
        info = flat / "PackageInfo"
        info.write_text('<pkg-info><payload installKBytes="1024"/></pkg-info>')
        self.assertEqual(archive.declared_payload(flat), 1024**2)
        for xml in ['<pkg-info/>', '<pkg-info><payload installKBytes="0"/></pkg-info>',
                    f'<pkg-info><payload installKBytes="{archive.MAX_PAYLOAD}"/></pkg-info>']:
            info.write_text(xml)
            with self.assertRaises(archive.Blocked):
                archive.declared_payload(flat)

    def test_signed_payload_count_metadata_is_bounded_and_absence_is_explicit(self):
        flat = self.inspector.root / "flat"
        flat.mkdir()
        info = flat / "PackageInfo"
        info.write_text('<pkg-info><payload installKBytes="1024"/></pkg-info>')
        metadata = []
        archive.declared_payload(flat, metadata)
        self.assertIsNone(metadata[0]["number_of_files"])
        for count in ["-1", "not-a-count", "9" * 11]:
            with self.subTest(count=count):
                info.write_text(f'<pkg-info><payload installKBytes="1024" numberOfFiles="{count}"/></pkg-info>')
                with self.assertRaisesRegex(archive.Blocked, "file count is malformed"):
                    archive.declared_payload(flat, [])

    def test_download_size_and_free_space_are_checked_while_child_is_active(self):
        with self.inspector.archive.open("wb") as handle:
            handle.truncate(archive.SIZE + 1)  # Sparse fixture, no actual multi-GB download.
        with patch.object(archive, "disk_gate", return_value=10**15):
            with self.assertRaisesRegex(archive.Blocked, "exceeds"):
                self.inspector.download_monitor()
        with patch.object(archive, "disk_gate", side_effect=archive.Blocked("reserve")):
            with self.assertRaisesRegex(archive.Blocked, "reserve"):
                self.inspector.download_monitor()

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

    def test_http_receipt_uses_final_block_and_never_keeps_cookie_or_unlisted_headers(self):
        headers = (b"HTTP/1.1 200 Connection established\r\nProxy-Agent: fixture\r\n\r\n"
                   b"HTTP/2 206\r\nContent-Length: 16\r\nContent-Range: bytes 0-15/5430783739\r\n"
                   b"Content-Type: application/octet-stream\r\nSet-Cookie: never-retain-fixture\r\n\r\n")
        self.inspector.command = self.http_command("HEAD", headers)
        with patch.object(archive.shutil, "which", return_value="/fixture/curl"):
            receipt = self.inspector.http_transfer("HEAD")
        self.assertEqual(receipt["http_status"], 206)
        self.assertEqual(receipt["content_length"], 16)
        self.assertEqual(receipt["content_range"], "bytes 0-15/5430783739")
        self.assertEqual(receipt["expected_archive_bytes"], archive.SIZE)
        self.assertNotIn("never-retain-fixture", json.dumps(receipt))
        self.assertNotIn("Proxy-Agent", json.dumps(receipt))
        self.assertFalse(self.inspector.archive.exists())

    def test_http_ambiguous_or_incomplete_metadata_is_blocked(self):
        for headers in [
            b"HTTP/2 200\r\nContent-Length: 16\r\nContent-Length: 16\r\n\r\n",
            b"HTTP/2 200\r\n Content-Length: 16\r\n\r\n",
            b"HTTP/2 200\r\nContent-Length: 16\r\n",
            b"HTTP/2 200\r\nContent-Length: 1,2\r\n\r\n",
            b"HTTP/2 200\r\nX-Large: " + b"x" * archive.MAX_HEADERS + b"\r\n\r\n"
        ]:
            with self.subTest(headers=headers[:80]):
                self.inspector.command = self.http_command("HEAD", headers)
                with patch.object(archive.shutil, "which", return_value="/fixture/curl"):
                    with self.assertRaises(archive.Blocked):
                        self.inspector.http_transfer("HEAD")

    def test_http_failed_redirect_and_missing_header_receipts_remain_blocked(self):
        headers = b"HTTP/2 200\r\nContent-Length: 0\r\n\r\n"
        for status, missing in [(47, False), (0, True)]:
            with self.subTest(status=status, missing=missing):
                (self.inspector.root / "http-head.headers").unlink(missing_ok=True)
                self.inspector.command = self.http_command("HEAD", headers, status=status, missing_headers=missing)
                with patch.object(archive.shutil, "which", return_value="/fixture/curl"):
                    with self.assertRaises(archive.Blocked):
                        self.inspector.http_transfer("HEAD")
                self.assertFalse(self.inspector.archive.exists())

    def test_future_get_records_actual_bytes_before_size_gate_or_transport_error(self):
        headers = b"HTTP/2 200\r\nContent-Length: 5\r\nContent-Type: application/octet-stream\r\n\r\n"
        self.inspector.check_capabilities = lambda: None
        for status, body in [(0, b"short"), (56, b"cut")]:
            with self.subTest(status=status):
                self.inspector.command = self.http_command("GET", headers, body=body, status=status)
                with patch.object(archive.shutil, "which", return_value="/fixture/curl"):
                    with self.assertRaises(archive.Blocked):
                        self.inspector.download_archive()
                receipt = self.inspector.report["http_get"]
                self.assertEqual(receipt["actual_archive_bytes"], len(body))
                self.assertEqual(receipt["content_length"], 5)
                self.assertEqual(receipt["curl_exit"], status)
                self.assertFalse(self.inspector.report["signature_verified"])

    def test_reviewed_get_exception_requires_literal_status_url_length_and_actual_bytes(self):
        self.assertEqual(archive.SIZE, 5_430_783_739)
        self.assertEqual(archive.OBSERVED_ARCHIVE_BYTES, 5_415_504_705)
        self.inspector.check_capabilities = lambda: None
        cases = [
            (200, archive.URL, archive.OBSERVED_ARCHIVE_BYTES, archive.OBSERVED_ARCHIVE_BYTES, None, True),
            (206, archive.URL, archive.OBSERVED_ARCHIVE_BYTES, archive.OBSERVED_ARCHIVE_BYTES, None, False),
            (200, archive.URL, archive.OBSERVED_ARCHIVE_BYTES, archive.OBSERVED_ARCHIVE_BYTES,
             "bytes 0-5415504704/5415504705", False),
            (200, archive.URL + "?different", archive.OBSERVED_ARCHIVE_BYTES, archive.OBSERVED_ARCHIVE_BYTES, None, False),
            (200, archive.URL, archive.SIZE, archive.OBSERVED_ARCHIVE_BYTES, None, False),
            (200, archive.URL, archive.OBSERVED_ARCHIVE_BYTES - 1, archive.OBSERVED_ARCHIVE_BYTES - 1, None, False),
            (200, archive.URL, archive.OBSERVED_ARCHIVE_BYTES, archive.OBSERVED_ARCHIVE_BYTES - 1, None, False),
        ]
        for code, url, declared, actual, content_range, accepted in cases:
            with self.subTest(code=code, url=url, declared=declared, actual=actual, content_range=content_range):
                headers = f"HTTP/2 {code}\r\nContent-Length: {declared}\r\n"
                if content_range is not None:
                    headers += f"Content-Range: {content_range}\r\n"
                headers += "\r\n"
                base_command = self.http_command("GET", headers.encode())

                def command(arguments, **options):
                    base_command(arguments, **options)
                    # Sparse owned fixture: no multi-GB allocation or network traffic.
                    with self.inspector.archive.open("r+b") as handle:
                        handle.truncate(actual)
                    return f"\nhttp_code={code}\nurl_effective={url}\n".encode(), 0

                self.inspector.command = command
                with patch.object(archive.shutil, "which", return_value="/fixture/curl"):
                    if accepted:
                        self.inspector.download_archive()
                    else:
                        with self.assertRaises(archive.Blocked):
                            self.inspector.download_archive()
                receipt = self.inspector.report["http_get"]
                self.assertEqual(receipt["actual_archive_bytes"], actual)
                self.assertEqual(receipt["observed_exception_bytes"], 5_415_504_705)
                self.assertEqual(receipt["archive_authenticity"], "unverified")
                self.assertFalse(self.inspector.report["signature_verified"])

    def test_head_cannot_change_reviewed_get_exception(self):
        headers = b"HTTP/2 200\r\nContent-Length: 123\r\n\r\n"
        self.inspector.command = self.http_command("HEAD", headers)
        with patch.object(archive.shutil, "which", return_value="/fixture/curl"):
            receipt = self.inspector.http_transfer("HEAD")
        self.assertEqual(receipt["content_length"], 123)
        self.assertEqual(archive.OBSERVED_ARCHIVE_BYTES, 5_415_504_705)
        self.assertFalse(receipt["declared_length_matches_catalog"])
        self.assertFalse(receipt["get_size_verified_by_head"])

    def test_metadata_only_mode_never_calls_probe_download_or_apple_extraction(self):
        entry = {"identifier": "com.apple.pkg.iPhoneSimulatorSDK15_5", "fileSize": archive.SIZE,
                 "source": archive.URL, "contentType": "package",
                 "simulatorVersion": {"buildUpdate": "19F70", "version": "15.5"}}
        class Response:
            url = archive.CATALOG
            def __enter__(self):
                return self
            def __exit__(self, *_):
                return False
            def read(self, _limit):
                return plistlib.dumps({"downloadables": [entry]})
        calls = []
        self.inspector.command = lambda arguments, **_: b"VirtualMac2,1\n" if arguments == ["/usr/sbin/sysctl", "-n", "hw.model"] else self.fail("Unexpected native command")
        self.inspector.http_transfer = lambda method: calls.append(method)
        self.inspector.download_archive = lambda: self.fail("Metadata-only mode invoked GET/probe")
        with patch.dict(os.environ, {"INVENTORY_RUNNER_ENVIRONMENT": "github-hosted", "INVENTORY_RUNNER_ARCH": "ARM64",
                                     "INVENTORY_WORKFLOW_SHA": "a" * 40, "INVENTORY_EVENT_SHA": "a" * 40}), \
                patch.object(archive.platform, "system", return_value="Darwin"), \
                patch.object(archive.platform, "machine", return_value="arm64"), \
                patch.object(archive, "read_plist", return_value={"ProductVersion": "16.4", "ProductBuildVersion": "16F6"}), \
                patch.object(archive, "disk_gate", return_value=40 * archive.GIB), \
                patch.object(archive.urllib.request, "urlopen", return_value=Response()):
            self.inspector.inspect(http_metadata_only=True)
        self.assertEqual(calls, ["HEAD"])
        self.assertEqual(self.inspector.report["state"], "http_metadata_only_not_archive_verified")
        self.assertFalse(self.inspector.report["download_attempted"])
        self.assertFalse(self.inspector.archive.exists())

    def test_failed_signature_never_lists_or_expands_payload(self):
        calls = []
        def command(arguments, **_):
            calls.append(arguments)
            return b"Status: no signature\n"
        self.inspector.command = command
        with self.assertRaises(archive.Blocked):
            self.inspector.verify_and_expand(self.inspector.mount / "runtime.pkg")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1], "--check-signature")
        self.assertFalse(self.inspector.report["signature_verified"])

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

    def test_inert_expand_full_probe_succeeds_without_apple_trust_or_download(self):
        calls = []
        self.inspector.command = self.capability_command("success", calls)
        self.inspector.check_capabilities()
        self.assertTrue(self.inspector.report["expand_full_probe"]["exact_bytes"])
        self.assertFalse(self.inspector.report["signature_verified"])
        self.assertEqual(len(calls), 5)
        self.assertFalse(self.inspector.archive.exists())
        self.assertFalse((self.inspector.root / "capability-probe").exists())

    def test_unsupported_expand_full_probe_blocks_before_any_download(self):
        calls = []
        self.inspector.command = self.capability_command("unsupported", calls)
        with self.assertRaisesRegex(archive.Blocked, "rejects expand-full"):
            self.inspector.download_archive()
        self.assertFalse(self.inspector.archive.exists())
        self.assertFalse((self.inspector.root / "capability-probe").exists())

    def test_real_help_requires_manual_nobrowse_and_explicit_negative_autoopen(self):
        for mode in ("failed-man", "absent-man", "missing-nobrowse", "empty-man", "missing-noautoopen"):
            with self.subTest(mode=mode):
                calls = []
                self.inspector.command = self.capability_command(mode, calls)
                with self.assertRaises(archive.Blocked):
                    self.inspector.download_archive()
                self.assertFalse(any(call[0] == "/usr/bin/pkgbuild" for call in calls))
                self.assertFalse(self.inspector.archive.exists())
                self.assertFalse((self.inspector.root / "capability-probe").exists())

    def test_incorrect_probe_bytes_or_payload_path_block_before_any_download(self):
        for mode in ("wrong-bytes", "extra-path"):
            with self.subTest(mode=mode):
                calls = []
                self.inspector.command = self.capability_command(mode, calls)
                with self.assertRaisesRegex(archive.Blocked, "bytes/path differ"):
                    self.inspector.download_archive()
                self.assertFalse(self.inspector.archive.exists())
                self.assertFalse((self.inspector.root / "capability-probe").exists())

    def test_symlink_probe_payload_blocks_before_any_download(self):
        calls = []
        self.inspector.command = self.capability_command("symlink", calls)
        with self.assertRaisesRegex(archive.Blocked, "symlink"):
            self.inspector.download_archive()
        self.assertFalse(self.inspector.archive.exists())
        self.assertFalse((self.inspector.root / "capability-probe").exists())

    def test_nonzero_pkgutil_is_fatal_even_if_its_text_looks_trusted(self):
        calls = []
        def command(arguments, **_):
            calls.append(arguments[1])
            # The command supervisor rejects nonzero before returning stdout;
            # even the complete real-looking receipt cannot authorize expansion.
            raise archive.Blocked("pkgutil failed: " + REAL_APPLE_SIGNATURE)
        self.inspector.command = command
        with self.assertRaisesRegex(archive.Blocked, "pkgutil failed"):
            self.inspector.verify_and_expand(self.inspector.mount / "runtime.pkg")
        self.assertEqual(calls, ["--check-signature"])
        self.assertFalse(self.inspector.report["signature_verified"])

    def test_payload_expansion_follows_successful_trust_and_declared_disk_budget(self):
        calls = []
        trusted = REAL_APPLE_SIGNATURE.encode()
        def command(arguments, **options):
            calls.append(arguments[1])
            if arguments[1] == "--check-signature":
                return trusted
            if arguments[1] == "--payload-files":
                self.assertEqual(options["timeout"], 90)
                options["consumer"].feed(b"Library/runtime/file\n")
                return options["consumer"].finish()
            destination = Path(arguments[-1])
            destination.mkdir()
            if arguments[1] == "--expand":
                (destination / "PackageInfo").write_text('<pkg-info><payload installKBytes="1024" numberOfFiles="1"/></pkg-info>')
            return b""
        self.inspector.command = command
        with patch.object(archive, "disk_gate", return_value=100 * archive.GIB) as gate, \
                patch.object(self.inspector, "inspect_bom_modes", return_value=1) as diagnostic:
            expanded = self.inspector.verify_and_expand(self.inspector.mount / "runtime.pkg")
        diagnostic.assert_called_once()
        flat, snapshots = diagnostic.call_args.args
        self.assertEqual(flat, self.inspector.root / "flat")
        self.assertEqual(set(snapshots), {flat / "PackageInfo"})
        self.assertEqual(snapshots[flat / "PackageInfo"][2:], (1024**2, 1))
        self.assertEqual(calls, ["--check-signature", "--expand", "--payload-files", "--expand-full"])
        self.assertEqual(gate.call_args_list[0].args, (self.inspector.root, archive.SIZE))
        self.assertEqual(gate.call_args_list[1].args, (self.inspector.root, 1024**2 + archive.SIZE))
        self.assertTrue(expanded.is_dir())
        self.assertFalse((self.inspector.root / "flat").exists())
        self.assertEqual(self.inspector.report["package_payload_metadata"][0]["number_of_files"], 1)

    def test_trust_text_requires_the_exact_apple_ca_and_rejects_expired_chain(self):
        output = REAL_APPLE_SIGNATURE
        self.assertEqual(archive.signature_gate(output)[1], archive.APPLE_CA)
        legacy = output.replace("signed Apple Software (Development)", "signed by a certificate trusted by macOS").replace("Update Certification Authority", "Update Certificate Authority")
        self.assertEqual(archive.signature_gate(legacy)[1], archive.APPLE_CA)
        for invalid in [output.replace("12 99 E9 BF", "00 99 E9 BF"), output + "expired", output.replace("Apple Software Update Certification Authority", "Other Authority")]:
            with self.assertRaises(archive.Blocked):
                archive.signature_gate(invalid)

    def test_real_signature_mutations_never_reach_payload_listing_or_expansion(self):
        output = REAL_APPLE_SIGNATURE
        intermediate = output.split("    2. ")[1].split("    3. ")[0]
        moved_pin = output.replace(intermediate, intermediate.replace("12 99 E9 BF", "00 99 E9 BF"))
        moved_pin = moved_pin.replace("D8 F1 22 D9 79 88 EB 12 D7 13 7B BD 53 74 E5 5A 9C 4B 38 F5 3D 25 \n           56 62 27 74 E2 3D DD 55 D3 6A", "12 99 E9 BF E7 76 A2 9F F4 52 F8 C4 F5 E5 5F 3B 4D FD 29 34 34 9D \n           D1 85 0B 82 74 F3 5C 71 74 5C")
        invalid_outputs = [
            output.replace("signed Apple Software (Development)", "signed by a developer certificate issued by Apple (Development)"),
            output.replace("Development Update", "Arbitrary Developer"),
            output.replace("Apple Root CA", "Other Root CA"), moved_pin,
            output + "   Status: signed Apple Software (Development)\n",
            output.replace("   Signed with a trusted timestamp on: 2022-05-26 01:15:02 +0000\n", ""),
            output.replace("2022-05-26 01:15:02 +0000", "malformed"),
            output.replace("2022-05-26 01:15:02 +0000", "2999-05-26 01:15:02 +0000"),
            output + "revoked", output + "invalid", output + "untrusted", output + "unsigned",
        ]
        for receipt in invalid_outputs:
            with self.subTest(receipt=receipt):
                calls = []
                def command(arguments, **_):
                    calls.append(arguments[1])
                    return receipt.encode()
                self.inspector.command = command
                with self.assertRaises(archive.Blocked):
                    self.inspector.verify_and_expand(self.inspector.mount / "runtime.pkg")
                self.assertEqual(calls, ["--check-signature"])
                self.assertFalse(self.inspector.report["signature_verified"])

    def test_unsafe_or_unknown_payload_layout_is_not_expanded(self):
        self.assertEqual(archive.safe_payload_listing("./Library/runtime/file\nLibrary/other\n"), 2)
        for listing in ["", "../outside\n", "/Library/global\n", "Library/../../outside\n"]:
            with self.assertRaises(archive.Blocked):
                archive.safe_payload_listing(listing)

    def test_macho_header_architecture_evidence_never_executes_runtime_code(self):
        binary = self.inspector.root / "loader"
        binary.write_bytes(b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x100000C) + b"\0" * 24)
        self.assertEqual(archive.macho_architectures(binary), ["arm64"])
        binary.write_bytes(b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x1000007) + b"\0" * 24)
        self.assertEqual(archive.macho_architectures(binary), ["x86_64"])
        binary.write_bytes(b"not a Mach-O")
        self.assertEqual(archive.macho_architectures(binary), [])
        binary.write_bytes(b"\xca\xfe\xba\xbe" + struct.pack(">I", 2) +
                           struct.pack(">IIIII", 0x1000007, 0, 0, 0, 0) +
                           struct.pack(">IIIII", 0x100000C, 0, 0, 0, 0))
        self.assertEqual(archive.macho_architectures(binary), ["x86_64", "arm64"])

    def test_simulator_and_standard_cache_names_require_actual_architecture_headers(self):
        for prefix in ("dyld_shared_cache_", "dyld_sim_shared_cache_"):
            cache = self.inspector.root / f"{prefix}arm64"
            cache.write_bytes(b"dyld_v1   arm64\x00")
            metadata = archive.cache_metadata(cache, self.inspector.root)
            self.assertEqual(metadata["architecture"], "arm64")
            cache.write_bytes(b"not-a-cache-arm64")
            metadata = archive.cache_metadata(cache, self.inspector.root)
            self.assertIsNone(metadata["architecture"])
            self.assertTrue(metadata["header_hex"])

    def test_failed_owned_detach_preserves_the_entire_tree_without_force_delete(self):
        self.inspector.mount_attempted = True
        self.inspector.archive.write_bytes(b"owned archive")
        self.inspector.owned_images = lambda: [{"system-entities": [{"mount-point": str(self.inspector.mount), "dev-entry": "/dev/disk77s1"}]}]
        calls = []
        def refuse(arguments, **_):
            calls.append(arguments)
            raise archive.Blocked("detach failed")
        self.inspector.command = refuse
        with self.assertRaisesRegex(archive.Blocked, "detach failed"):
            self.inspector.cleanup()
        self.assertEqual(calls, [["/usr/bin/hdiutil", "detach", "/dev/disk77s1"]])
        self.assertTrue(self.inspector.archive.exists())
        self.assertTrue(self.inspector.mount.exists())

    def test_ambiguous_or_still_mounted_image_is_not_deleted(self):
        self.inspector.mount_attempted = True
        self.inspector.owned_images = lambda: [{"system-entities": []}]
        with self.assertRaisesRegex(archive.Blocked, "identity"):
            self.inspector.cleanup()
        self.assertTrue(self.inspector.root.exists())
        self.inspector.owned_images = lambda: []
        with patch.object(archive.os.path, "ismount", return_value=True):
            with self.assertRaisesRegex(archive.Blocked, "remains mounted"):
                self.inspector.cleanup()
        self.assertTrue(self.inspector.root.exists())

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

    def test_incremental_listing_validates_fragmented_utf8_paths_and_finite_budgets(self):
        listing = archive.PayloadListing()
        payload = "./Contents/capítulo\n.\n".encode()
        for value in payload:
            listing.feed(bytes([value]))
        self.assertEqual(listing.finish(), 2)
        for payload in [b"", b"unfinished", b"/absolute\n", b"./a/../b\n", b"nul\0name\n",
                        b"control\tname\n", b"bad\xff\n", b"\n", b"x" * (archive.MAX_LISTING_LINE + 1)]:
            with self.subTest(payload=payload[:30]):
                listing = archive.PayloadListing()
                with self.assertRaises(archive.Blocked):
                    listing.feed(payload)
                    listing.finish()
                self.assertFalse(listing.complete)
        for constant, limit, payload in [("MAX_LISTING_BYTES", 3, b"four\n"),
                                          ("MAX_LISTING_ENTRIES", 1, b"one\ntwo\n")]:
            with patch.object(archive, constant, limit):
                listing = archive.PayloadListing()
                with self.assertRaises(archive.Blocked):
                    listing.feed(payload)
                self.assertFalse(listing.receipt()["complete"])

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
                with patch.object(archive, "disk_gate", return_value=100 * archive.GIB), \
                        patch.object(archive, "MAX_LISTING_ENTRIES", 2), \
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


class BomDiagnosticTests(unittest.TestCase):
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
        with patch.object(archive, "disk_gate", return_value=100 * archive.GIB):
            return self.inspector.verify_and_expand(self.inspector.mount / "runtime.pkg")

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
                with patch.object(archive, "MAX_LISTING_BYTES", byte_limit or 64 * 1024**2):
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
        with patch.object(archive, "MAX_LISTING_BYTES", 6):
            consumer = archive.BomModes("a" * 64)
            with self.assertRaises(archive.Blocked):
                consumer.feed(b"100644\n")
            self.assertFalse(consumer.receipt()["complete"])


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
        with patch.object(archive, "LAYOUT_BYTES", 256):
            layout = self.inspector.runtime_layout(self.expanded)
        self.assertTrue(layout["truncated"])
        self.assertLessEqual(len(json.dumps({"expanded_layout": layout}, indent=2).encode()), 256)
        with patch.object(archive.time, "monotonic", side_effect=[0, 2]):
            layout = self.inspector.runtime_layout(self.expanded)
        self.assertTrue(layout["truncated"])
        self.assertEqual(layout["scanned"], 0)
        with patch.object(archive, "LAYOUT_SCANNED", 2), patch.object(archive, "LAYOUT_RECORDS", 64):
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
                patch.object(archive, "LAYOUT_BYTES", budget):
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
