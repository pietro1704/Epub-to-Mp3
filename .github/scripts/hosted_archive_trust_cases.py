"""Inherited archive assertion cases; loaded by the original unittest classes."""

from pathlib import Path
from unittest.mock import patch
from hosted_archive_test_fixtures import REAL_APPLE_SIGNATURE, archive

class HostedArchiveTrustCases:
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
        with patch.object(archive.inspection, "disk_gate", return_value=100 * archive.GIB) as gate, \
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
            with patch.object(archive.contracts, constant, limit):
                listing = archive.PayloadListing()
                with self.assertRaises(archive.Blocked):
                    listing.feed(payload)
                self.assertFalse(listing.receipt()["complete"])
