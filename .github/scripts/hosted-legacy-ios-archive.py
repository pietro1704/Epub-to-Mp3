"""Hosted ARM archive inspection only. Importing this module performs no work."""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET

SIZE = 5_430_783_739
URL = "https://devimages-cdn.apple.com/downloads/xcode/simulators/com.apple.pkg.iPhoneSimulatorSDK15_5-15.5.1.1653527639.dmg"
CATALOG = "https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex"
APPLE_CA = "1299e9bfe776a29ff452f8c4f5e55f3b4dfd2934349dd1850b8274f35c71745c"
GIB = 1024**3
RESERVE = 8 * GIB
MAX_PAYLOAD = 24 * GIB
MAX_LOG = 16 * 1024**2
MARKER = "legacy-ios-archive-owned-v1\n"


class Blocked(RuntimeError):
    pass


def within(root, candidate):
    root = Path(root).resolve(strict=True)
    candidate = Path(candidate)
    if candidate.is_symlink() or not candidate.resolve().is_relative_to(root):
        raise Blocked("Path is a symlink or escapes the owned root")
    return candidate


def disk_gate(directory, additional=0, usage=shutil.disk_usage):
    if additional < 0 or additional > MAX_PAYLOAD + SIZE:
        raise Blocked("Unrecognized disk expansion budget")
    free = usage(directory).free
    if free < RESERVE + additional:
        raise Blocked("Insufficient free disk for the declared budget and 8 GiB reserve")
    return free


def signature_gate(output):
    # pkgutil performs cryptographic/trust verification. Text/fingerprints do
    # not replace it: the caller must also require its successful exit status.
    if "Status: signed by a certificate trusted by" not in output:
        raise Blocked("Package is not reported as trusted by pkgutil")
    if re.search(r"expired|revoked|invalid|untrusted|unsigned", output, re.I):
        raise Blocked("Package trust status is not acceptable")
    if "Apple Software Update Certificate Authority" not in output:
        raise Blocked("Expected Apple software-update chain is absent")
    fingerprints = []
    for value in re.findall(r"SHA256 Fingerprint:\s*((?:[0-9a-fA-F]{2}[\s:]*){32})", output):
        fingerprints.append(re.sub(r"[^0-9a-fA-F]", "", value).lower())
    if APPLE_CA not in fingerprints:
        raise Blocked("Pinned Apple update CA fingerprint was not verified")
    return fingerprints


def safe_payload_listing(output):
    entries = output.splitlines()
    if not entries or len(entries) > 250_000:
        raise Blocked("Missing or excessive package payload listing")
    for name in entries:
        if not name or name.startswith("/") or ".." in PurePosixPath(name).parts or "\x00" in name:
            raise Blocked("Unsafe package payload path")
    return len(entries)


def declared_payload(directory):
    infos = []
    for info in Path(directory).rglob("PackageInfo"):
        infos.append(info)
        if len(infos) > 128:
            raise Blocked("PackageInfo layout exceeds the component budget")
    if not infos:
        raise Blocked("PackageInfo layout is missing or ambiguous")
    total = 0
    for info in infos:
        within(directory, info)
        if info.stat().st_size > 1024**2:
            raise Blocked("PackageInfo exceeds the metadata budget")
        data = info.read_bytes()
        if b"<!DOCTYPE" in data or b"<!ENTITY" in data:
            raise Blocked("PackageInfo contains unsupported XML declarations")
        root = ET.fromstring(data)
        payloads = root.findall("payload")
        if len(payloads) != 1 or not re.fullmatch(r"[1-9]\d*", payloads[0].get("installKBytes", "")):
            raise Blocked("Package payload size is unknown")
        total += int(payloads[0].get("installKBytes")) * 1024
        if total > MAX_PAYLOAD:
            raise Blocked("Declared package payload exceeds 24 GiB")
    return total


def macho_architectures(filename):
    data = Path(filename).open("rb")
    with data:
        header = data.read(4096)
    if len(header) < 8:
        return []
    magic = header[:4]
    if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
        cpus = [struct.unpack_from("<I", header, 4)[0]]
    elif magic in (b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
        cpus = [struct.unpack_from(">I", header, 4)[0]]
    elif magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        count = struct.unpack_from(">I", header, 4)[0]
        stride = 32 if magic[-1] == 0xBF else 20
        if count < 1 or count > 64 or 8 + count * stride > len(header):
            raise Blocked("Unknown fat Mach-O header")
        cpus = [struct.unpack_from(">I", header, 8 + index * stride)[0] for index in range(count)]
    else:
        return []
    return ["arm64" if cpu == 0x100000C else "x86_64" if cpu == 0x1000007 else f"cpu:{cpu}" for cpu in cpus]


def interrupt(signum, _frame):
    raise Blocked(f"Inspection interrupted by signal {signum}")


def read_plist(filename, limit=1024**2):
    if filename.is_symlink() or filename.stat().st_size > limit:
        raise Blocked("Plist identity or size exceeds its metadata budget")
    return plistlib.loads(filename.read_bytes())


def cache_metadata(filename, root):
    # Apple's TARGET_OS_SIMULATOR cache basename is dyld_sim_shared_cache_.
    # https://github.com/apple-oss-distributions/dyld/blob/main/include/mach-o/dyld_cache_format.h
    if not filename.name.startswith(("dyld_shared_cache_", "dyld_sim_shared_cache_")):
        return None
    with filename.open("rb") as handle:
        raw = handle.read(16)
    match = re.fullmatch(rb"dyld_v1 +(?P<architecture>arm64e?|x86_64h?)\x00*", raw) if len(raw) == 16 else None
    return {"path": str(filename.relative_to(root)), "header_hex": raw.hex(),
            "header": raw.decode("ascii", errors="replace"),
            "architecture": match["architecture"].decode() if match else None}


class Inspector:
    def __init__(self, temporary, reports):
        self.temporary = Path(temporary).resolve(strict=True)
        self.reports = Path(reports)
        self.reports.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix="legacy-ios-archive-owned-", dir=self.temporary))
        (self.root / ".owned").write_text(MARKER)
        self.archive = self.root / "runtime.dmg"
        self.mount = self.root / "mount"
        self.mount.mkdir()
        self.mount_attempted = False
        self.device = None
        self.sequence = 0
        self.report = {"phase": "archive_only", "state": "blocked", "blockers": [],
                       "runtime_installed": False, "device_created": False, "simulator_started": False,
                       "runtime_launchability": "unverified", "app_acceptance": "unverified",
                       "signature_verified": False, "archive_arm_evidence": "unverified", "cleanup": "pending"}
        (self.reports / "owned-root.json").write_text(json.dumps({"root": str(self.root)}))

    @staticmethod
    def stop(process):
        if process.pid <= 1 or process.pid == os.getpgrp():
            raise Blocked("Invalid owned process group")
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        # A leader may exit while descendants ignore TERM.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)

    def command(self, arguments, timeout=60, monitor=None):
        self.sequence += 1
        log = self.reports / f"{self.sequence:02d}-{Path(arguments[0]).name}.log"
        deadline = time.monotonic() + timeout
        with log.open("xb") as output:
            process = subprocess.Popen(arguments, stdout=output, stderr=subprocess.STDOUT,
                                       stdin=subprocess.DEVNULL, start_new_session=True,
                                       env={**os.environ, "LC_ALL": "C"})
            active = self.reports / "active-command.json"
            try:
                active.write_text(json.dumps({"pid": process.pid, "tool": Path(arguments[0]).name}))
                while process.poll() is None:
                    if time.monotonic() >= deadline or log.stat().st_size > MAX_LOG:
                        raise Blocked("Owned command exceeded its time/log budget")
                    if monitor:
                        monitor()
                    time.sleep(0.1)
                if process.returncode != 0:
                    raise Blocked(f"{Path(arguments[0]).name} failed; see {log.name}")
            finally:
                self.stop(process)
                active.unlink(missing_ok=True)
        if log.stat().st_size > MAX_LOG:
            raise Blocked("Command output exceeded the metadata budget")
        return log.read_bytes()

    def download_monitor(self):
        disk_gate(self.root)
        if self.archive.exists():
            within(self.root, self.archive)
            if self.archive.stat().st_size > SIZE:
                raise Blocked("Download exceeds the exact Apple archive size")

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
        curl = shutil.which("curl")
        if not curl:
            raise Blocked("Preinstalled curl unavailable")
        # Use curl here because its protocol/redirect bounds are explicit;
        # preferred aria2/xcodes must not weaken the exact Apple HTTPS origin.
        self.command([curl, "--disable", "--fail", "--show-error", "--silent", "--proto", "=https",
                      "--proto-redir", "=https", "--max-redirs", "0", "--location",
                      "--connect-timeout", "15", "--max-time", "900", "--max-filesize", str(SIZE),
                      "--output", str(self.archive), URL], timeout=910, monitor=self.download_monitor)
        self.download_monitor()
        if self.archive.stat().st_size != SIZE:
            raise Blocked("Downloaded archive size differs from Apple metadata")

    def verify_and_expand(self, package):
        output = self.command(["/usr/sbin/pkgutil", "--check-signature", str(package)], timeout=90)
        self.report["certificate_sha256"] = signature_gate(output.decode())
        self.report["signature_verified"] = True
        listing = self.command(["/usr/sbin/pkgutil", "--payload-files", str(package)], timeout=90)
        self.report["payload_file_count"] = safe_payload_listing(listing.decode())
        disk_gate(self.root, SIZE)
        flat = self.root / "flat"
        self.command(["/usr/sbin/pkgutil", "--expand", str(package), str(flat)],
                     timeout=180, monitor=lambda: disk_gate(self.root))
        expected = declared_payload(flat)
        self.report["declared_payload_bytes"] = expected
        shutil.rmtree(within(self.root, flat))
        disk_gate(self.root, expected + SIZE)
        expanded = self.root / "expanded"
        self.command(["/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded)],
                     timeout=600, monitor=lambda: disk_gate(self.root))
        return expanded

    def inspect_runtime(self, expanded):
        runtimes = [item for item in expanded.rglob("*.simruntime") if not item.is_symlink()]
        if len(runtimes) != 1:
            raise Blocked("Expected one legacy runtime in the package")
        runtime = within(expanded, runtimes[0])
        info_path = within(expanded, runtime / "Contents/Info.plist")
        system_path = within(expanded, runtime / "Contents/Resources/RuntimeRoot/System/Library/CoreServices/SystemVersion.plist")
        info = read_plist(info_path)
        system = read_plist(system_path)
        self.report["runtime_identifier"] = info.get("CFBundleIdentifier")
        self.report["system_version"] = system
        if (info.get("CFBundleIdentifier") != "com.apple.CoreSimulator.SimRuntime.iOS-15-5" or
                system.get("ProductVersion") != "15.5" or system.get("ProductBuildVersion") != "19F70"):
            raise Blocked("Extracted runtime identity differs from iOS 15.5/19F70")
        root = runtime / "Contents/Resources/RuntimeRoot"
        try:
            dyld = within(expanded, root / "usr/lib/dyld_sim")
            arches = macho_architectures(dyld)
        except (OSError, Blocked) as error:
            arches = []
            self.report["loader_metadata_blocker"] = f"{type(error).__name__}: {error}"
        caches = []
        candidates = []
        self.report["cache_candidates"] = candidates
        measured = 0
        count = 0
        for directory, folders, files in os.walk(expanded, followlinks=False):
            folders[:] = [name for name in folders if not (Path(directory) / name).is_symlink()]
            for name in files:
                item = Path(directory) / name
                if item.is_symlink():
                    continue
                count += 1
                measured += item.stat().st_size
                if count > 250_000 or measured > MAX_PAYLOAD:
                    raise Blocked("Expanded payload exceeds its inspection budget")
                if item.is_relative_to(root):
                    metadata = cache_metadata(item, root)
                    if metadata is not None:
                        if len(candidates) >= 64:
                            raise Blocked("Shared-cache candidates exceed their metadata budget")
                        candidates.append(metadata)
                        if metadata["architecture"] is not None:
                            caches.append(metadata)
        self.report.update({"dyld_architectures": arches, "shared_cache_headers": caches,
                            "expanded_bytes": measured, "expanded_files": count})
        if "arm64" not in arches or not any(cache["architecture"] in ("arm64", "arm64e") for cache in caches):
            self.report["archive_arm_evidence"] = "required_loader_has_no_arm64" if arches == ["x86_64"] else "inconclusive"
            raise Blocked("Required loader/cache evidence does not establish ARM runtime support")
        self.report["archive_arm_evidence"] = "arm64_loader_and_cache_present_not_boot_verified"
        profiles = Path("/Applications/Xcode_16.4.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Library/Developer/CoreSimulator/Profiles/DeviceTypes")
        matches = []
        for filename in profiles.glob("*.simdevicetype/Contents/Info.plist"):
            if filename.is_symlink() or filename.stat().st_size > 1024**2:
                continue
            profile = read_plist(filename)
            if profile.get("CFBundleIdentifier") == "com.apple.CoreSimulator.SimDeviceType.iPhone-SE":
                matches.append({"identifier": profile["CFBundleIdentifier"], "name": profile.get("CFBundleName"), "path": str(filename)})
        self.report["exact_se1_profiles"] = matches
        if len(matches) != 1:
            raise Blocked("Exact original SE1 device type metadata is missing or ambiguous")

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
        if (self.root / ".owned").is_symlink() or (self.root / ".owned").read_text() != MARKER:
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
        inspector.sequence = max([int(item.name.split("-")[0]) for item in reports.glob("[0-9]*-*.log")] + [0])
        inspector.report = {"cleanup": "pending"}
        inspector.cleanup()

    def inspect(self):
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
        self.report["free_disk_bytes_before_download"] = disk_gate(self.root, 2 * SIZE)
        if self.report["free_disk_bytes_before_download"] < 30 * GIB:
            raise Blocked("Phase-1 initial free disk is below 30 GiB")
        with urllib.request.urlopen(CATALOG, timeout=15) as response:
            if response.url != CATALOG:
                raise Blocked("Unexpected catalog URL")
            payload = response.read(2 * 1024**2 + 1)
        if len(payload) > 2 * 1024**2:
            raise Blocked("Catalog metadata exceeds budget")
        entries = [item for item in plistlib.loads(payload)["downloadables"] if item.get("identifier") == "com.apple.pkg.iPhoneSimulatorSDK15_5"]
        if len(entries) != 1 or entries[0].get("fileSize") != SIZE or entries[0].get("source") != URL or entries[0].get("contentType") != "package" or entries[0].get("simulatorVersion") != {"buildUpdate": "19F70", "version": "15.5"}:
            raise Blocked("Apple catalog identity changed")
        self.report["catalog_sha256"] = hashlib.sha256(payload).hexdigest()
        self.report["catalog_entry"] = {key: entries[0].get(key) for key in (
            "identifier", "contentType", "fileSize", "source", "simulatorVersion", "hostRequirements"
        )}
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


def main():
    # The runner may signal an active step. Raise into command/finally cleanup;
    # hard-kill recovery is separately fail-closed, with no untrusted PID kill.
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    if sys.argv[1:] == ["--cleanup-owned"]:
        reports = Path(os.environ["RUNNER_TEMP"]) / "legacy-ios-archive-report"
        result = {"phase": "owned_cleanup_recovery", "state": "complete_or_already_absent"}
        try:
            Inspector.recover_cleanup(os.environ["RUNNER_TEMP"], reports)
        except Exception as error:
            result.update({"state": "blocked_preserving_owned_tree", "reason": f"{type(error).__name__}: {error}"})
        reports.mkdir(exist_ok=True)
        (reports / "cleanup-recovery.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result))
        return 2 if result["state"].startswith("blocked") else 0
    if sys.argv[1:]:
        raise Blocked("Unknown archive inspection arguments")
    inspector = Inspector(os.environ["RUNNER_TEMP"], Path(os.environ["RUNNER_TEMP"]) / "legacy-ios-archive-report")
    try:
        inspector.inspect()
    except Exception as error:
        inspector.report["blockers"].append(f"{type(error).__name__}: {error}")
    finally:
        try:
            inspector.cleanup()
        except Exception as error:
            inspector.report["cleanup"] = "blocked_owned_tree_preserved"
            inspector.report["blockers"].append(f"Cleanup: {type(error).__name__}: {error}")
        if inspector.report["blockers"]:
            inspector.report["state"] = "blocked"
        (inspector.reports / "report.json").write_text(json.dumps(inspector.report, indent=2) + "\n")
        print(json.dumps(inspector.report))
    return 2 if inspector.report["blockers"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
