"""Inherited archive assertion cases; loaded by the original unittest classes."""

import json
import os
import plistlib
from unittest.mock import patch
from hosted_archive_test_fixtures import archive

class HostedArchiveHttpCases:
    def test_download_size_and_free_space_are_checked_while_child_is_active(self):
        with self.inspector.archive.open("wb") as handle:
            handle.truncate(archive.SIZE + 1)  # Sparse fixture, no actual multi-GB download.
        with patch.object(archive.inspection, "disk_gate", return_value=10**15):
            with self.assertRaisesRegex(archive.Blocked, "exceeds"):
                self.inspector.download_monitor()
        with patch.object(archive.inspection, "disk_gate", side_effect=archive.Blocked("reserve")):
            with self.assertRaisesRegex(archive.Blocked, "reserve"):
                self.inspector.download_monitor()

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
                patch.object(archive.inspection, "read_plist", return_value={"ProductVersion": "16.4", "ProductBuildVersion": "16F6"}), \
                patch.object(archive.inspection, "disk_gate", return_value=40 * archive.GIB), \
                patch.object(archive.urllib.request, "urlopen", return_value=Response()):
            self.inspector.inspect(http_metadata_only=True)
        self.assertEqual(calls, ["HEAD"])
        self.assertEqual(self.inspector.report["state"], "http_metadata_only_not_archive_verified")
        self.assertFalse(self.inspector.report["download_attempted"])
        self.assertFalse(self.inspector.archive.exists())
