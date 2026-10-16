"""Host fixtures only. Mocks never establish Apple trust or runtime compatibility."""

import importlib.util
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
        def command(arguments, **_):
            calls.append(arguments[1])
            if arguments[1] == "--check-signature":
                return trusted
            if arguments[1] == "--payload-files":
                return b"Library/runtime/file\n"
            destination = Path(arguments[-1])
            destination.mkdir()
            if arguments[1] == "--expand":
                (destination / "PackageInfo").write_text('<pkg-info><payload installKBytes="1024"/></pkg-info>')
            return b""
        self.inspector.command = command
        with patch.object(archive, "disk_gate", return_value=100 * archive.GIB) as gate:
            expanded = self.inspector.verify_and_expand(self.inspector.mount / "runtime.pkg")
        self.assertEqual(calls, ["--check-signature", "--payload-files", "--expand", "--expand-full"])
        self.assertEqual(gate.call_args_list[0].args, (self.inspector.root, archive.SIZE))
        self.assertEqual(gate.call_args_list[1].args, (self.inspector.root, 1024**2 + archive.SIZE))
        self.assertTrue(expanded.is_dir())
        self.assertFalse((self.inspector.root / "flat").exists())

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
                self.inspector.command([sys.executable, "-c", parent_script], timeout=10, monitor=cancel_when_started)
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


if __name__ == "__main__":
    unittest.main()
