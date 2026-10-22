"""Inherited archive assertion cases; loaded by the original unittest classes."""

import json
import struct
from unittest.mock import patch
from hosted_archive_test_fixtures import archive

class HostedArchiveOwnershipCases:
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
