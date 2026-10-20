"""Host-only metadata fixtures; synthetic plists do not establish Apple compatibility."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).with_name("capture_native_test_metadata.py")
SPEC = importlib.util.spec_from_file_location("metadata_capture", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SECRET = "private-value-never-publish"


class MetadataCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-metadata-fixture-")
        self.root = Path(self.temporary.name)
        self.products = self.root / "Products"
        self.app = self.products / "Debug/EpubToMp3.app"
        self.app.mkdir(parents=True)
        self.version = self.root / "version.txt"
        self.version.write_text("Xcode 16.4\nBuild version 16F6\n", encoding="ascii")
        self.output = self.root / "reports/capture"
        self.environment = dict(os.environ)
        self.environment.update({f"INVENTORY_{key}": value * 40 for key, value in {
            "CHECKOUT_SHA": "a", "TREE_SHA": "b", "PR_HEAD_SHA": "c", "EVENT_SHA": "d", "WORKFLOW_SHA": "e",
        }.items()})
        self.environment.update(INVENTORY_WORKTREE_STATE="dirty", GITHUB_RUN_ID="123",
                                GITHUB_RUN_ATTEMPT="1", GITHUB_JOB="macos-preferences", EXPECTED_ARCH="arm64")
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        for name in ("gh", "plutil", "xcodebuild", "xcrun"):
            (fake_bin / name).write_text('#!/bin/sh\nprintf called > "$FORBIDDEN_CALL"\nexit 99\n')
            (fake_bin / name).chmod(0o755)
        self.environment.update(PATH=f"{fake_bin}:{os.environ['PATH']}", FORBIDDEN_CALL=str(self.root / "called"))
        self.manifest = self.products / "fixture.xctestrun"

    def tearDown(self):
        self.temporary.cleanup()

    def fixture(self, fmt=plistlib.FMT_XML):
        value = {"__xctestrun_metadata__": {"FormatVersion": 2}, "TestConfigurations": [{
            "Name": SECRET, "TestTargets": [{
                "BlueprintName": "EpubToMp3Tests", "IsAppHostedTestBundle": True,
                "TestHostPath": "__TESTROOT__/Debug/EpubToMp3.app",
                "TestBundlePath": "__TESTHOST__/Contents/PlugIns/EpubToMp3Tests.xctest",
                "UITargetAppPath": str(self.app), "EnvironmentVariables": {"SECRET_NAME": SECRET},
                "CommandLineArguments": [SECRET, str(self.root)], "UnknownField": SECRET,
            }],
        }]}
        self.manifest.write_bytes(plistlib.dumps(value, fmt=fmt))
        contents = self.app / "Contents"
        contents.mkdir(exist_ok=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.example.EpubToMp3", "CFBundleExecutable": "EpubToMp3",
            "CFBundleSupportedPlatforms": ["MacOSX"], "DTXcode": "1640", "PrivateField": SECRET,
            "LSMinimumSystemVersion": "12.0", "UnknownPath": str(self.root),
        }, fmt=fmt))

    def invoke(self, products=None, output=None, environment=None):
        result = subprocess.run([sys.executable, str(SOURCE), "--products", str(products or self.products),
                                 "--output", str(output or self.output), "--xcode-version-file", str(self.version)],
                                capture_output=True, text=True, env=environment or self.environment,
                                timeout=10, check=False)
        self.assertNotIn("Traceback", result.stderr)
        self.assertNotIn(str(self.root), result.stderr)
        self.assertLess(len(result.stderr), 250)
        self.assertFalse((self.root / "called").exists())
        return result

    def receipt(self, output=None):
        return json.loads(((output or self.output) / "receipt.json").read_text())

    def test_actual_cli_xml_and_binary_sanitize_without_input_mutation(self):
        for index, fmt in enumerate((plistlib.FMT_XML, plistlib.FMT_BINARY)):
            with self.subTest(fmt=fmt):
                self.fixture(fmt)
                before = {str(path.relative_to(self.products)): path.read_bytes()
                          for path in self.products.rglob("*") if path.is_file()}
                output = self.root / f"capture-{index}"
                result = self.invoke(output=output)
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = self.receipt(output)
                self.assertEqual(receipt["capture_state"], "captured")
                self.assertEqual(receipt["runtime_eligibility"], "unverified")
                self.assertEqual(receipt["source"]["checkout_sha"], "a" * 40)
                self.assertEqual(receipt["source"]["pr_head_sha"], "c" * 40)
                self.assertEqual(receipt["source"]["worktree_state"], "dirty")
                record = receipt["manifests"][0]
                sanitized = (output / record["sanitized_file"]).read_bytes()
                self.assertNotEqual(record["original_sha256"], record["sanitized_sha256"])
                self.assertEqual(record["original_sha256"], hashlib.sha256(self.manifest.read_bytes()).hexdigest())
                self.assertEqual(record["sanitized_sha256"], hashlib.sha256(sanitized).hexdigest())
                target = plistlib.loads(sanitized)["TestConfigurations"][0]["TestTargets"][0]
                self.assertIs(target["IsAppHostedTestBundle"], True)
                self.assertNotIn("UITargetAppPath", target)
                self.assertEqual(record["path_sidecar"][0]["products_relative"], "Debug/EpubToMp3.app")
                self.assertEqual(record["path_sidecar"][0]["observed_type"], "string")
                combined = json.dumps(receipt) + repr(plistlib.loads(sanitized))
                for forbidden in (SECRET, "SECRET_NAME", "CommandLineArguments", "EnvironmentVariables", str(self.root)):
                    self.assertNotIn(forbidden, combined)
                after = {str(path.relative_to(self.products)): path.read_bytes()
                         for path in self.products.rglob("*") if path.is_file()}
                self.assertEqual(before, after)

    def test_missing_products_or_manifest_is_factual_and_never_fabricates_a_manifest(self):
        for index, products in enumerate((self.products, self.root / "missing")):
            output = self.root / f"missing-report-{index}"
            self.assertEqual(self.invoke(products=products, output=output).returncode, 0)
            receipt = self.receipt(output)
            self.assertEqual(receipt["capture_state"], "missing_manifest")
            self.assertEqual(receipt["runtime_eligibility"], "unverified")
            self.assertEqual(receipt["manifests"], [])
            self.assertEqual(list(output.glob("*.plist")), [])

    def test_entities_internal_subsets_and_nonstandard_doctypes_are_rejected(self):
        for index, declaration in enumerate((
            b'<!DOCTYPE plist [<!ENTITY leak "private-value-never-publish">]>',
            b'<!DOCTYPE plist SYSTEM "https://example.invalid/private.dtd">',
            MODULE.APPLE_DOCTYPE + b'<!ENTITY leak "private">',
        )):
            data = plistlib.dumps({"TestConfigurations": []}).replace(MODULE.APPLE_DOCTYPE, declaration)
            self.manifest.write_bytes(data)
            output = self.root / f"bad-xml-{index}"
            self.assertEqual(self.invoke(output=output).returncode, 2)
            self.assertEqual(self.receipt(output)["blocked_reason"], "xml_declarations_not_supported")

    def test_traversal_external_references_and_symlink_inputs_cannot_escape(self):
        outside = self.root / "outside-secret"
        outside.write_bytes(b"outside-preserved")
        for index, reference in enumerate(("__TESTROOT__/../outside-secret", str(outside))):
            self.manifest.write_bytes(plistlib.dumps({"EpubToMp3Tests": {"TestHostPath": reference}}))
            self.assertEqual(self.invoke(output=self.root / f"escape-{index}").returncode, 2)
        self.manifest.unlink()
        self.manifest.symlink_to(outside)
        self.assertEqual(self.invoke(output=self.root / "symlink-leaf").returncode, 2)
        self.manifest.unlink()
        link = self.products / "linked.app"
        link.symlink_to(outside.parent, target_is_directory=True)
        self.assertEqual(self.invoke(output=self.root / "symlink-bundle").returncode, 2)
        self.assertEqual(outside.read_bytes(), b"outside-preserved")

    def test_oversized_or_excessive_metadata_is_bounded(self):
        self.manifest.write_bytes(b"x" * (MODULE.MAX_MANIFEST_BYTES + 1))
        self.assertEqual(self.invoke(output=self.root / "oversized").returncode, 2)
        self.manifest.unlink()
        for index in range(MODULE.MAX_MANIFESTS + 1):
            (self.products / f"{index}.xctestrun").write_bytes(b"invalid")
        self.assertEqual(self.invoke(output=self.root / "too-many").returncode, 2)

    def test_source_identity_validation_and_optional_pr_head_are_explicit(self):
        self.fixture()
        for index, (key, value) in enumerate((("INVENTORY_CHECKOUT_SHA", SECRET), ("INVENTORY_WORKTREE_STATE", "unsafe"))):
            environment = {**self.environment, key: value}
            output = self.root / f"bad-identity-{index}"
            self.assertEqual(self.invoke(output=output, environment=environment).returncode, 2)
            self.assertNotIn(SECRET, json.dumps(self.receipt(output)))
        environment = {**self.environment, "INVENTORY_PR_HEAD_SHA": "", "INVENTORY_WORKTREE_STATE": "unknown"}
        output = self.root / "no-pr"
        self.assertEqual(self.invoke(output=output, environment=environment).returncode, 0)
        self.assertIsNone(self.receipt(output)["source"]["pr_head_sha"])

    def test_outputs_reject_input_overlap_symlink_ancestors_and_existing_paths(self):
        self.fixture()
        self.assertEqual(self.invoke(output=self.products / "capture").returncode, 2)
        self.assertFalse((self.products / "capture").exists())
        outside = self.root / "outside"
        outside.mkdir()
        link = self.root / "reports-link"
        link.symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.invoke(output=link / "capture").returncode, 2)
        self.assertEqual(list(outside.iterdir()), [])
        self.output.parent.mkdir(exist_ok=True)
        self.output.write_bytes(b"existing-output")
        self.assertEqual(self.invoke().returncode, 2)
        self.assertEqual(self.output.read_bytes(), b"existing-output")

    def test_stable_descriptor_rejects_replacement_during_a_real_read(self):
        self.fixture()
        descriptor = MODULE.directory(self.products)
        original_read = os.read
        replaced = False

        def replacing_read(fd, length):
            nonlocal replaced
            result = original_read(fd, length)
            if not replaced:
                replacement = self.products / "replacement"
                replacement.write_bytes(b"replacement-data")
                replacement.replace(self.manifest)
                replaced = True
            return result

        try:
            with patch.object(MODULE.os, "read", side_effect=replacing_read):
                with self.assertRaisesRegex(MODULE.Blocked, "input_replaced|input_changed"):
                    MODULE.read_regular(descriptor, "fixture.xctestrun", MODULE.MAX_MANIFEST_BYTES)
        finally:
            os.close(descriptor)


if __name__ == "__main__":
    unittest.main()
