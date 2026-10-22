"""Hosted archive orchestration and owned-tree recovery; no work on import."""

import hosted_archive_contracts as contracts
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import stat
import tempfile
import time
import urllib.request
from hosted_archive_contracts import (
    Blocked,
    BomModes,
    PayloadListing,
    declared_payload,
    disk_gate,
    http_headers,
    package_info_metadata,
    read_plist,
    signature_gate,
    within,
)

from hosted_archive_commands import ArchiveCommands
from hosted_archive_runtime_metadata import ArchiveRuntimeMetadata


class Inspector:
    def __init__(self, temporary, reports):
        self.temporary = Path(temporary).resolve(strict=True)
        self.reports = Path(reports)
        self.reports.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix="legacy-ios-archive-owned-", dir=self.temporary))
        (self.root / ".owned").write_text(contracts.MARKER)
        self.archive = self.root / "runtime.dmg"
        self.mount = self.root / "mount"
        self.mount.mkdir()
        self.mount_attempted = False
        self.device = None
        self.report = {"phase": "archive_only", "state": "blocked", "blockers": [],
                       "download_attempted": False,
                       "runtime_installed": False, "device_created": False, "simulator_started": False,
                       "runtime_launchability": "unverified", "app_acceptance": "unverified",
                       "signature_verified": False, "archive_arm_evidence": "unverified", "cleanup": "pending"}
        self._commands = ArchiveCommands(self.reports, self.report)
        (self.reports / "owned-root.json").write_text(json.dumps({"root": str(self.root)}))



    def download_monitor(self):
        disk_gate(self.root)
        if self.archive.exists():
            within(self.root, self.archive)
            if self.archive.stat().st_size > contracts.SIZE:
                raise Blocked("Download exceeds the pinned catalog ceiling")

    def check_capabilities(self):
        help_pkg = self.command(["/usr/sbin/pkgutil", "--help"]).decode()
        help_mount = self.command(["/usr/bin/hdiutil", "attach", "-help"]).decode()
        # Expand only the explicit spelling printed by the real hosted help.
        help_mount = help_mount.replace("-[no]autoopen", "-noautoopen")
        if not all(flag in help_pkg for flag in ("--check-signature", "--payload-files", "--expand")) or not all(flag in help_mount for flag in ("-readonly", "-noautoopen", "-mountpoint", "-plist")):
            raise Blocked("Required inspection flags are not documented by the runner tools")
        try:
            manual = self.command(["/usr/bin/man", "-P", "/bin/cat", "hdiutil"], timeout=15).decode()
        except (OSError, Blocked) as error:
            raise Blocked("The hdiutil manual could not establish -nobrowse support") from error
        # man may emit bold/underline overstrikes even with a noninteractive pager.
        manual = re.sub(r"[^\n]\x08", "", manual)
        if not re.search(r"(?<![\w-])-nobrowse(?![\w-])", manual):
            raise Blocked("The hdiutil manual does not document -nobrowse")
        # --expand-full is not advertised by pkgutil --help on the hosted image.
        # Prove the API with an unsigned, owned, inert fixture, never Apple data.
        probe = self.root / "capability-probe"
        probe.mkdir()
        try:
            source = probe / "source"
            source.mkdir()
            filename = "legacy-archive-probe.txt"
            expected = b"Legacy archive extraction capability probe.\n"
            text = source / filename
            text.write_bytes(expected)
            text.chmod(0o600)
            package, output = probe / "probe.pkg", probe / "expanded"
            # install-location is package metadata only. No installer is called.
            self.command(["/usr/bin/pkgbuild", "--root", str(source), "--identifier",
                          "com.pietrocode.epubtomp3.archive-capability", "--version", "1",
                          "--install-location", "/", str(package)], timeout=30,
                         monitor=lambda: disk_gate(self.root))
            self.command(["/usr/sbin/pkgutil", "--expand-full", str(package), str(output)],
                         timeout=30, monitor=lambda: disk_gate(self.root))
            payload = output / "Payload"
            result = payload / filename
            within(probe, result)
            if (output.is_symlink() or payload.is_symlink() or not payload.is_dir() or
                    list(payload.iterdir()) != [result] or not result.is_file() or
                    result.stat().st_mode & 0o111 or result.stat().st_size != len(expected) or
                    result.read_bytes() != expected):
                raise Blocked("Inert expand-full capability probe bytes/path differ")
            self.report["expand_full_probe"] = {"scope": "owned_unsigned_plain_text_only",
                                                "payload_path": f"Payload/{filename}", "exact_bytes": True}
        finally:
            if not (self.reports / "active-command.json").exists():
                shutil.rmtree(within(self.root, probe))

    def download_archive(self):
        self.check_capabilities()
        self.report["download_attempted"] = True
        self.http_transfer("GET")
        self.download_monitor()
        if self.archive.stat().st_size != contracts.OBSERVED_ARCHIVE_BYTES:
            raise Blocked("Downloaded archive size differs from the reviewed observed exception")

    def http_transfer(self, method):
        if method not in ("HEAD", "GET"):
            raise Blocked("Unsupported HTTP diagnostic method")
        curl = shutil.which("curl")
        if not curl:
            raise Blocked("Preinstalled curl unavailable")
        headers = self.root / f"http-{method.lower()}.headers"
        output = self.root / "head-response.txt" if method == "HEAD" else self.archive
        receipt = {"method": method, "expected_archive_bytes": contracts.SIZE, "effective_url": None,
                   "curl_exit": None, "archive_authenticity": "unverified", "get_size_verified_by_head": False}
        receipt["observed_exception_bytes"] = contracts.OBSERVED_ARCHIVE_BYTES
        receipt["observed_exception_evidence_run"] = "38908787295"
        self.report[f"http_{method.lower()}"] = receipt
        duration = 30 if method == "HEAD" else 900
        # Use curl here because its protocol/redirect bounds are explicit;
        # preferred aria2/xcodes must not weaken the exact Apple HTTPS origin.
        arguments = [curl, "--disable", "--fail", "--show-error", "--silent", "--proto", "=https",
                     "--proto-redir", "=https", "--max-redirs", "0", "--location",
                     "--connect-timeout", "15", "--max-time", str(duration), "--max-filesize", str(contracts.SIZE),
                     "--dump-header", str(headers), "--output", str(output),
                     "--write-out", "\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\n"]
        if method == "HEAD":
            arguments.append("--head")
        arguments.append(contracts.URL)
        def monitor():
            self.download_monitor()
            if headers.exists():
                within(self.root, headers)
                if headers.stat().st_size > contracts.MAX_HEADERS:
                    raise Blocked("HTTP headers exceed 64 KiB")
            if method == "HEAD" and output.exists() and output.stat().st_size > contracts.MAX_HEADERS:
                raise Blocked("HEAD output exceeds its metadata budget")
        error = None
        try:
            stdout, status = self.command(arguments, timeout=duration + 10, monitor=monitor, allow_failure=True)
            receipt["curl_exit"] = status
            monitor()
            statuses = re.findall(r"^http_code=(\d{3})$", stdout.decode(), re.M)
            urls = re.findall(r"^url_effective=([^\r\n]+)$", stdout.decode(), re.M)
            if len(statuses) != 1 or len(urls) != 1 or urls[0] != contracts.URL:
                raise Blocked("HTTP transfer receipt has missing or unexpected identity")
            receipt["effective_url"] = urls[0]
            receipt["curl_http_status"] = int(statuses[0])
            if status != 0:
                raise Blocked("Curl transport/HTTP/redirect failed; no retry or URL fallback")
        except (Blocked, OSError) as caught:
            error = caught
        finally:
            if method == "GET":
                receipt["actual_archive_bytes"] = self.archive.stat().st_size if self.archive.exists() else 0
            if headers.exists():
                try:
                    within(self.root, headers)
                    if headers.stat().st_size > contracts.MAX_HEADERS:
                        raise Blocked("HTTP headers exceed 64 KiB")
                    receipt.update(http_headers(headers.read_bytes()))
                except (Blocked, OSError) as caught:
                    receipt["header_metadata_blocker"] = str(caught)
                    error = error or caught
            else:
                error = error or Blocked("HTTP response header receipt is missing")
            if receipt.get("curl_http_status") != receipt.get("http_status"):
                error = error or Blocked("HTTP status receipts disagree")
            if receipt.get("content_length") is None:
                error = error or Blocked("HTTP Content-Length receipt is missing")
            receipt["declared_length_matches_catalog"] = receipt.get("content_length") == contracts.SIZE
            if method == "GET":
                receipt["catalog_size_mismatch"] = receipt.get("content_length") != contracts.SIZE
                if (receipt.get("http_status") != 200 or receipt.get("content_range") is not None or
                        receipt.get("content_length") != contracts.OBSERVED_ARCHIVE_BYTES or
                        receipt.get("actual_archive_bytes") != contracts.OBSERVED_ARCHIVE_BYTES):
                    error = error or Blocked("GET must match the reviewed exact 200/no-range/byte-length exception")
        if error:
            raise Blocked(str(error)) from error
        return receipt

    def inspect_bom_modes(self, flat, snapshots):
        if self.report["signature_verified"] is not True:
            raise Blocked("BOM diagnostics require verified package signature")
        # Use the hosted Apple manual as the capability evidence. -p m emits
        # only octal modes, never filenames, owners, checksums or file contents.
        manual = self.command(["/usr/bin/man", "-P", "/bin/cat", "lsbom"], timeout=15).decode()
        manual = re.sub(r".\x08", "", manual)
        if ("-p" not in manual or "octal" not in manual or
                not re.search(r"\bm\s+file mode \(permissions\)", manual)):
            raise Blocked("Hosted lsbom manual did not establish octal -p m output")
        inventories = self.report["signed_bom_inventories"] = []
        infos = []
        for info in flat.rglob("PackageInfo"):
            infos.append(info)
            if len(infos) > 128:
                raise Blocked("BOM component layout exceeds its budget")
        if not infos:
            raise Blocked("BOM component layout is missing or exceeds its budget")
        boms = []
        for bom in flat.rglob("Bom"):
            boms.append(bom)
            if len(boms) > 128:
                raise Blocked("BOM component layout exceeds its budget")
        if (set(infos) != set(snapshots) or
                {info.parent for info in infos} != {bom.parent for bom in boms}):
            raise Blocked("PackageInfo and BOM components are missing or ambiguous")
        entry_limit = 0
        for info in infos:
            bom = info.parent / "Bom"
            metadata, info_identity = package_info_metadata(flat, info)
            if snapshots[info] != (info_identity, metadata["package_info_sha256"],
                                   metadata["install_bytes"], metadata["number_of_files"]):
                raise Blocked("PackageInfo differs from the declared payload snapshot")
            if not metadata["number_of_files"]:
                raise Blocked("Signed BOM budget requires a positive package file count")

            def identity():
                resolved = within(flat, bom)
                details = bom.lstat()
                if not stat.S_ISREG(details.st_mode) or details.st_size > contracts.MAX_LISTING_BYTES:
                    raise Blocked("BOM must be a bounded regular file")
                digest = hashlib.sha256()
                measured = 0
                with resolved.open("rb") as handle:
                    while chunk := handle.read(contracts.STREAM_CHUNK):
                        measured += len(chunk)
                        if measured > contracts.MAX_LISTING_BYTES:
                            raise Blocked("BOM exceeds the metadata byte budget")
                        digest.update(chunk)
                return ((details.st_dev, details.st_ino, details.st_size, details.st_mtime_ns),
                        digest.hexdigest())

            before, digest = identity()
            consumer = BomModes(digest)
            try:
                self.command(["/usr/bin/lsbom", "-p", "m", str(bom)], timeout=90, consumer=consumer)
                if identity() != (before, digest):
                    raise Blocked("BOM identity changed during inspection")
                if package_info_metadata(flat, info) != (metadata, info_identity):
                    raise Blocked("PackageInfo identity changed during BOM inspection")
                if (not consumer.complete or consumer.entries != sum(consumer.counts.values()) or
                        consumer.counts["other"] != 0 or
                        consumer.counts["regular"] + consumer.counts["symlink"] != metadata["number_of_files"]):
                    raise Blocked("Signed BOM counts do not match their package metadata")
                entry_limit += consumer.entries
                if entry_limit > contracts.MAX_SIGNED_BOM_ENTRIES:
                    raise Blocked("Signed BOM count exceeds the reviewed entry ceiling")
            except BaseException:
                consumer.complete = False
                raise
            finally:
                inventories.append({**consumer.receipt(),
                                    "package_info_sha256": metadata["package_info_sha256"],
                                    "number_of_files": metadata["number_of_files"]})
                self.report["bom_mode_inventory"] = consumer.receipt()
        self.report["payload_listing_budget"] = {
            "source": "complete_signed_component_boms", "entries": entry_limit,
            "ceiling": contracts.MAX_SIGNED_BOM_ENTRIES}
        return entry_limit

    def verify_and_expand(self, package):
        output = self.command(["/usr/sbin/pkgutil", "--check-signature", str(package)], timeout=90)
        self.report["certificate_sha256"] = signature_gate(output.decode())
        self.report["signature_verified"] = True
        disk_gate(self.root, contracts.SIZE)
        flat = self.root / "flat"
        self.command(["/usr/sbin/pkgutil", "--expand", str(package), str(flat)],
                     timeout=180, monitor=lambda: disk_gate(self.root))
        # Derive the path budget from complete, identity-checked signed BOMs.
        # PackageInfo counts regular files and links; the BOM also counts dirs.
        self.report["package_payload_metadata"] = []
        snapshots = {}
        expected = declared_payload(flat, self.report["package_payload_metadata"], snapshots)
        self.report["declared_payload_bytes"] = expected
        entry_limit = self.inspect_bom_modes(flat, snapshots)
        shutil.rmtree(within(self.root, flat))
        self.report["payload_file_count"] = self.command(
            ["/usr/sbin/pkgutil", "--payload-files", str(package)], timeout=90,
            consumer=PayloadListing(entry_limit))
        disk_gate(self.root, expected + contracts.SIZE)
        expanded = self.root / "expanded"
        self.command(["/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded)],
                     timeout=600, monitor=lambda: disk_gate(self.root))
        return expanded



    def owned_images(self):
        info = plistlib.loads(self.command(["/usr/bin/hdiutil", "info", "-plist"], timeout=15))
        images = []
        for image in info.get("images", []):
            if image.get("image-path") == str(self.archive):
                images.append(image)
        return images

    def cleanup(self):
        within(self.temporary, self.root)
        if self.root.parent != self.temporary or not self.root.name.startswith("legacy-ios-archive-owned-"):
            raise Blocked("Refusing cleanup of an unrelated temporary directory")
        if (self.root / ".owned").is_symlink() or (self.root / ".owned").read_text() != contracts.MARKER:
            raise Blocked("Refusing cleanup without the original owned marker")
        if (self.reports / "active-command.json").exists():
            # A hard-killed inspector may leave descendants. A saved PID is not
            # proof of present ownership; preserve the tree rather than kill it.
            raise Blocked("Command completion is unconfirmed; preserving the owned tree")
        if self.mount_attempted:
            images = self.owned_images()
            for image in images:
                entities = image.get("system-entities", [])
                mounts = [item for item in entities if item.get("mount-point") == str(self.mount)]
                if len(mounts) != 1 or not re.fullmatch(r"/dev/disk\d+(?:s\d+)*", mounts[0].get("dev-entry", "")):
                    raise Blocked("Owned mount identity could not be established; preserving tree")
                self.command(["/usr/bin/hdiutil", "detach", mounts[0]["dev-entry"]], timeout=20)
            if self.owned_images():
                raise Blocked("Owned image remains attached; preserving tree")
            if os.path.ismount(self.mount):
                raise Blocked("Owned mountpoint remains mounted; preserving tree")
        shutil.rmtree(self.root)
        self.report["cleanup"] = "owned_tree_removed_after_detach"

    @classmethod
    def recover_cleanup(cls, temporary, reports):
        temporary = Path(temporary).resolve(strict=True)
        reports = Path(reports)
        registry = reports / "owned-root.json"
        if not registry.exists():
            return
        if registry.is_symlink() or registry.stat().st_size > 4096:
            raise Blocked("Invalid owned-root registry")
        root = Path(json.loads(registry.read_text())["root"])
        within(temporary, root)
        if not root.exists():
            return
        inspector = cls.__new__(cls)
        inspector.temporary, inspector.reports, inspector.root = temporary, reports, root
        inspector.archive, inspector.mount = root / "runtime.dmg", root / "mount"
        inspector.mount_attempted = True  # Recover a mount even if attach timed out before its receipt.
        sequence = max([int(item.name.split("-")[0]) for item in reports.glob("[0-9]*-*.log")] + [0])
        inspector.report = {"cleanup": "pending"}
        inspector._commands = ArchiveCommands(reports, inspector.report, sequence=sequence)
        inspector.cleanup()

    def inspect(self, http_metadata_only=False):
        if http_metadata_only:
            self.report["phase"] = "http_metadata_only_not_archive_acceptance"
            self.report["download_attempted"] = False
        self.report.update({"workflow_sha": os.environ.get("INVENTORY_WORKFLOW_SHA"),
                            "event_sha": os.environ.get("INVENTORY_EVENT_SHA"),
                            "run_id": os.environ.get("GITHUB_RUN_ID"),
                            "runner_environment": os.environ.get("INVENTORY_RUNNER_ENVIRONMENT"),
                            "runner_context_arch": os.environ.get("INVENTORY_RUNNER_ARCH"),
                            "actual_machine": platform.machine()})
        if (os.environ.get("INVENTORY_RUNNER_ENVIRONMENT") != "github-hosted" or
                os.environ.get("INVENTORY_RUNNER_ARCH") != "ARM64" or
                platform.system() != "Darwin" or platform.machine() != "arm64"):
            raise Blocked("Hosted macOS ARM64 context required")
        if not all(re.fullmatch(r"[a-f0-9]{40}", self.report.get(key) or "") for key in ("workflow_sha", "event_sha")):
            raise Blocked("Immutable SHA evidence unavailable")
        self.report["host_model"] = self.command(["/usr/sbin/sysctl", "-n", "hw.model"]).decode().strip()
        if self.report["host_model"] != "VirtualMac2,1":
            raise Blocked("Reviewed hosted ARM VM model was not established")
        version = read_plist(Path("/Applications/Xcode_16.4.app/Contents/version.plist"))
        if ((version.get("CFBundleShortVersionString") or version.get("ProductVersion")) not in ("16.4", "16.4.0") or version.get("ProductBuildVersion") != "16F6"):
            raise Blocked("Exact Xcode 16.4/16F6 metadata required")
        self.report["free_disk_bytes_before_download"] = disk_gate(self.root, 2 * contracts.SIZE)
        if self.report["free_disk_bytes_before_download"] < 30 * contracts.GIB:
            raise Blocked("Phase-1 initial free disk is below 30 GiB")
        with urllib.request.urlopen(contracts.CATALOG, timeout=15) as response:
            if response.url != contracts.CATALOG:
                raise Blocked("Unexpected catalog URL")
            payload = response.read(2 * 1024**2 + 1)
        if len(payload) > 2 * 1024**2:
            raise Blocked("Catalog metadata exceeds budget")
        entries = [item for item in plistlib.loads(payload)["downloadables"] if item.get("identifier") == "com.apple.pkg.iPhoneSimulatorSDK15_5"]
        if len(entries) != 1 or entries[0].get("fileSize") != contracts.SIZE or entries[0].get("source") != contracts.URL or entries[0].get("contentType") != "package" or entries[0].get("simulatorVersion") != {"buildUpdate": "19F70", "version": "15.5"}:
            raise Blocked("Apple catalog identity changed")
        self.report["catalog_sha256"] = hashlib.sha256(payload).hexdigest()
        self.report["catalog_entry"] = {key: entries[0].get(key) for key in (
            "identifier", "contentType", "fileSize", "source", "simulatorVersion", "hostRequirements"
        )}
        if http_metadata_only:
            self.http_transfer("HEAD")
            self.report["state"] = "http_metadata_only_not_archive_verified"
            return
        self.download_archive()
        digest = hashlib.sha256()
        deadline = time.monotonic() + 180
        with self.archive.open("rb") as handle:
            while chunk := handle.read(8 * 1024**2):
                if time.monotonic() > deadline:
                    raise Blocked("Archive hash exceeded its time budget")
                digest.update(chunk)
        self.report["archive_sha256_receipt_not_published_checksum"] = digest.hexdigest()
        self.command(["/usr/bin/hdiutil", "verify", str(self.archive)], timeout=300)
        self.mount_attempted = True
        attached = plistlib.loads(self.command(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                                               "-mountpoint", str(self.mount), "-plist", str(self.archive)], timeout=90))
        mounts = [item for item in attached.get("system-entities", []) if item.get("mount-point") == str(self.mount)]
        if len(mounts) != 1:
            raise Blocked("Attached mountpoint differs from its owned identity")
        packages = list(self.mount.glob("*.pkg"))
        if (len(packages) != 1 or packages[0].is_symlink() or not packages[0].is_file() or
                re.search(r"[\x00-\x1f\x7f]", packages[0].name)):
            raise Blocked("Expected exactly one flat package at the archive root")
        self.inspect_runtime(self.verify_and_expand(packages[0]))
        self.report["state"] = "signed_archive_metadata_ready_for_review_not_launch_verified"
    stop = staticmethod(ArchiveCommands.stop)

    def command(self, arguments, timeout=60, monitor=None, allow_failure=False, consumer=None):
        self._commands.report = self.report
        self._commands.reports = self.reports
        return self._commands.command(arguments, timeout=timeout, monitor=monitor,
                                      allow_failure=allow_failure, consumer=consumer)

    def runtime_layout(self, expanded):
        return ArchiveRuntimeMetadata(self.root, self.report).runtime_layout(expanded)

    def inspect_runtime(self, expanded):
        return ArchiveRuntimeMetadata(self.root, self.report).inspect_runtime(expanded)
