"""Hosted ARM archive inspection only. Importing this module performs no work."""

import hashlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import selectors
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
# Reviewed observed exception: HEAD run 38908787295 at f84c2d32 reported this
# exact length. Catalog SIZE remains the ceiling/disk budget, not an estimate.
# xcodes 2.0.3 delegates to XcodesKit 1.0.4: fileSize is display metadata,
# not a published checksum or an archive byte-equality check in its download path.
# https://github.com/XcodesOrg/xcodes/blob/2.0.3/Package.resolved
# https://github.com/XcodesOrg/XcodesKit/blob/a9e5d7d701f20f1385071851319cdaecccc9f1e8/Sources/XcodesKit/Models/Runtimes/Runtimes.swift
# https://github.com/XcodesOrg/XcodesKit/blob/a9e5d7d701f20f1385071851319cdaecccc9f1e8/Sources/XcodesKit/Services/RuntimeArchiveService.swift
OBSERVED_ARCHIVE_BYTES = 5_415_504_705
URL = "https://devimages-cdn.apple.com/downloads/xcode/simulators/com.apple.pkg.iPhoneSimulatorSDK15_5-15.5.1.1653527639.dmg"
CATALOG = "https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex"
APPLE_CA = "1299e9bfe776a29ff452f8c4f5e55f3b4dfd2934349dd1850b8274f35c71745c"
GIB = 1024**3
RESERVE = 8 * GIB
MAX_PAYLOAD = 24 * GIB
MAX_LOG = 16 * 1024**2
MAX_HEADERS = 64 * 1024
MAX_LISTING_BYTES = 64 * 1024**2
MAX_LISTING_ENTRIES = 250_000
MAX_LISTING_LINE = 4096
STREAM_CHUNK = 64 * 1024
MARKER = "legacy-ios-archive-owned-v1\n"


class Blocked(RuntimeError):
    pass


def http_headers(payload):
    """Keep only diagnostic fields from the final complete HTTP response block."""
    if len(payload) > MAX_HEADERS:
        raise Blocked("HTTP headers exceed 64 KiB")
    if not payload.endswith(b"\r\n\r\n"):
        raise Blocked("Final HTTP response headers are missing or incomplete")
    blocks = []
    current = None
    for line in payload.decode("iso-8859-1").split("\r\n"):
        if line.startswith("HTTP/"):
            if current is not None:
                raise Blocked("HTTP response blocks are not separated")
            match = re.fullmatch(r"HTTP/(?:1\.[01]|2|3) ([1-5]\d\d)(?: [^\x00-\x1f\x7f]*)?", line)
            if not match:
                raise Blocked("Unrecognized HTTP status line")
            current = {"status": int(match[1]), "headers": {}}
            blocks.append(current)
        elif not line:
            current = None
        elif current is None or line[0].isspace() or ":" not in line:
            raise Blocked("Ambiguous HTTP header framing")
        else:
            name, value = line.split(":", 1)
            if not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name):
                raise Blocked("Invalid HTTP header name")
            key = name.lower()
            if key in ("content-length", "content-range", "content-type"):
                value = value.strip()
                if key in current["headers"] or re.search(r"[\x00-\x1f\x7f]", value):
                    raise Blocked("Ambiguous allowlisted HTTP header")
                current["headers"][key] = value
    if not blocks or current is not None:
        raise Blocked("Final HTTP response headers are missing or incomplete")
    final = blocks[-1]
    length = final["headers"].get("content-length")
    if length is not None and not re.fullmatch(r"\d{1,20}", length):
        raise Blocked("HTTP Content-Length is not an unambiguous byte count")
    return {"http_status": final["status"], "content_length": int(length) if length is not None else None,
            "content_range": final["headers"].get("content-range"),
            "content_type": final["headers"].get("content-type")}


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
    statuses = re.findall(r"^\s*Status: (.+)$", output, re.M)
    if len(statuses) != 1 or statuses[0] not in (
            "signed by a certificate trusted by macOS", "signed Apple Software (Development)"):
        raise Blocked("Package is not reported as trusted by pkgutil")
    if re.search(r"expired|revoked|invalid|untrusted|unsigned", output, re.I):
        raise Blocked("Package trust status is not acceptable")
    # Observed Apple pkgutil output from run38909806259; Apple documents this
    # intermediate's exact pin at https://support.apple.com/en-au/102130.
    # Associate each fingerprint with its numbered certificate, not global text.
    blocks = list(re.finditer(r"^\s*(\d+)\. ([^\r\n]+)\r?\n(.*?)(?=^\s*\d+\. |\Z)", output, re.M | re.S))
    if [block[1] for block in blocks] != ["1", "2", "3"]:
        raise Blocked("Expected exactly three ordered certificate blocks")
    names = [block[2] for block in blocks]
    if names[1] not in ("Apple Software Update Certificate Authority", "Apple Software Update Certification Authority") or names[2] != "Apple Root CA":
        raise Blocked("Expected Apple software-update chain is absent")
    if statuses[0] == "signed Apple Software (Development)":
        if names[0] != "Development Update":
            raise Blocked("Unexpected Apple development-update signer")
        timestamps = re.findall(r"^\s*Signed with a trusted timestamp on: (.+)$", output, re.M)
        if len(timestamps) != 1:
            raise Blocked("Missing or ambiguous trusted signing timestamp")
        try:
            signed_at = datetime.strptime(timestamps[0], "%Y-%m-%d %H:%M:%S %z")
        except ValueError as error:
            raise Blocked("Malformed trusted signing timestamp") from error
        if signed_at > datetime.now(timezone.utc):
            raise Blocked("Trusted signing timestamp is in the future")
    fingerprints = []
    for block in blocks:
        values = re.findall(r"SHA256 Fingerprint:\s*((?:[0-9a-fA-F]{2}[\s:]*){32})", block[3])
        if len(values) != 1:
            raise Blocked("Certificate fingerprint is missing or ambiguous")
        fingerprints.append(re.sub(r"[^0-9a-fA-F]", "", values[0]).lower())
    if fingerprints[1] != APPLE_CA:
        raise Blocked("Pinned Apple update CA fingerprint was not verified")
    return fingerprints


class PayloadListing:
    """Bounded incremental path validation; the digest is an observed receipt only."""

    def __init__(self):
        self.pending = b""
        self.entries = 0
        self.bytes = 0
        self.digest = hashlib.sha256()
        self.complete = False

    def feed(self, chunk):
        if len(chunk) > STREAM_CHUNK:
            raise Blocked("Payload listing chunk exceeds its read budget")
        self.bytes += len(chunk)
        self.digest.update(chunk)
        if self.bytes > MAX_LISTING_BYTES:
            raise Blocked("Payload listing exceeds its byte budget")
        self.pending += chunk
        while b"\n" in self.pending:
            line, self.pending = self.pending.split(b"\n", 1)
            if len(line) > MAX_LISTING_LINE:
                raise Blocked("Payload listing path exceeds its line budget")
            try:
                name = line.decode("utf-8", errors="strict")
            except UnicodeDecodeError as error:
                raise Blocked("Payload listing contains invalid UTF-8") from error
            if (not name or name.startswith("/") or ".." in PurePosixPath(name).parts or
                    any(ord(character) < 32 or ord(character) == 127 for character in name)):
                raise Blocked("Unsafe package payload path")
            self.entries += 1
            if self.entries > MAX_LISTING_ENTRIES:
                raise Blocked("Payload listing exceeds its entry budget")
        if len(self.pending) > MAX_LISTING_LINE:
            raise Blocked("Payload listing path exceeds its line budget")

    def finish(self):
        if self.pending or not self.entries:
            raise Blocked("Missing or incomplete package payload listing")
        self.complete = True
        return self.entries

    def receipt(self):
        return {"entries": self.entries, "bytes": self.bytes,
                "sha256_observed_listing_receipt": self.digest.hexdigest(), "complete": self.complete}


def safe_payload_listing(output):
    listing = PayloadListing()
    encoded = output.encode("utf-8")
    for offset in range(0, len(encoded), STREAM_CHUNK):
        listing.feed(encoded[offset:offset + STREAM_CHUNK])
    return listing.finish()


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
                       "download_attempted": False,
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

    def command(self, arguments, timeout=60, monitor=None, allow_failure=False, consumer=None):
        if consumer is not None and allow_failure:
            raise Blocked("Streaming validation requires successful process completion")
        self.sequence += 1
        log = self.reports / f"{self.sequence:02d}-{Path(arguments[0]).name}.log"
        deadline = time.monotonic() + timeout
        with log.open("xb") as output:
            process = subprocess.Popen(arguments, stdout=subprocess.PIPE if consumer else output,
                                       stderr=output if consumer else subprocess.STDOUT,
                                       stdin=subprocess.DEVNULL, start_new_session=True,
                                       env={**os.environ, "LC_ALL": "C"})
            active = self.reports / "active-command.json"
            selector = None
            try:
                active.write_text(json.dumps({"pid": process.pid, "tool": Path(arguments[0]).name}))
                if consumer:
                    selector = selectors.DefaultSelector()
                    os.set_blocking(process.stdout.fileno(), False)
                    selector.register(process.stdout, selectors.EVENT_READ)
                while process.poll() is None or (selector is not None and selector.get_map()):
                    if time.monotonic() >= deadline or log.stat().st_size > MAX_LOG:
                        raise Blocked("Owned command exceeded its time/log budget")
                    if monitor:
                        monitor()
                    if selector is None:
                        time.sleep(0.1)
                    else:
                        for key, _ in selector.select(timeout=0.1):
                            try:
                                chunk = os.read(key.fd, STREAM_CHUNK)
                            except BlockingIOError:
                                continue
                            if chunk:
                                consumer.feed(chunk)
                            else:
                                selector.unregister(key.fileobj)
                if process.returncode != 0 and not allow_failure:
                    raise Blocked(f"{Path(arguments[0]).name} failed; see {log.name}")
                if log.stat().st_size > MAX_LOG:
                    raise Blocked("Command output exceeded the metadata budget")
                if consumer:
                    consumer.finish()
            finally:
                try:
                    self.stop(process)
                    active.unlink(missing_ok=True)
                finally:
                    if selector is not None:
                        selector.close()
                        process.stdout.close()
                        if sys.exc_info()[0] is not None:
                            consumer.complete = False
                        unwinding = sys.exc_info()[0] is not None
                        try:
                            self.report["payload_listing"] = consumer.receipt()
                        except Exception:
                            # Never replace the original process/validation error,
                            # but require a receipt before successful expansion.
                            if not unwinding:
                                raise
        if log.stat().st_size > MAX_LOG:
            raise Blocked("Command output exceeded the metadata budget")
        if consumer:
            return consumer.entries
        result = log.read_bytes()
        return (result, process.returncode) if allow_failure else result

    def download_monitor(self):
        disk_gate(self.root)
        if self.archive.exists():
            within(self.root, self.archive)
            if self.archive.stat().st_size > SIZE:
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
        if self.archive.stat().st_size != OBSERVED_ARCHIVE_BYTES:
            raise Blocked("Downloaded archive size differs from the reviewed observed exception")

    def http_transfer(self, method):
        if method not in ("HEAD", "GET"):
            raise Blocked("Unsupported HTTP diagnostic method")
        curl = shutil.which("curl")
        if not curl:
            raise Blocked("Preinstalled curl unavailable")
        headers = self.root / f"http-{method.lower()}.headers"
        output = self.root / "head-response.txt" if method == "HEAD" else self.archive
        receipt = {"method": method, "expected_archive_bytes": SIZE, "effective_url": None,
                   "curl_exit": None, "archive_authenticity": "unverified", "get_size_verified_by_head": False}
        receipt["observed_exception_bytes"] = OBSERVED_ARCHIVE_BYTES
        receipt["observed_exception_evidence_run"] = "38908787295"
        self.report[f"http_{method.lower()}"] = receipt
        duration = 30 if method == "HEAD" else 900
        # Use curl here because its protocol/redirect bounds are explicit;
        # preferred aria2/xcodes must not weaken the exact Apple HTTPS origin.
        arguments = [curl, "--disable", "--fail", "--show-error", "--silent", "--proto", "=https",
                     "--proto-redir", "=https", "--max-redirs", "0", "--location",
                     "--connect-timeout", "15", "--max-time", str(duration), "--max-filesize", str(SIZE),
                     "--dump-header", str(headers), "--output", str(output),
                     "--write-out", "\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\n"]
        if method == "HEAD":
            arguments.append("--head")
        arguments.append(URL)
        def monitor():
            self.download_monitor()
            if headers.exists():
                within(self.root, headers)
                if headers.stat().st_size > MAX_HEADERS:
                    raise Blocked("HTTP headers exceed 64 KiB")
            if method == "HEAD" and output.exists() and output.stat().st_size > MAX_HEADERS:
                raise Blocked("HEAD output exceeds its metadata budget")
        error = None
        try:
            stdout, status = self.command(arguments, timeout=duration + 10, monitor=monitor, allow_failure=True)
            receipt["curl_exit"] = status
            monitor()
            statuses = re.findall(r"^http_code=(\d{3})$", stdout.decode(), re.M)
            urls = re.findall(r"^url_effective=([^\r\n]+)$", stdout.decode(), re.M)
            if len(statuses) != 1 or len(urls) != 1 or urls[0] != URL:
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
                    if headers.stat().st_size > MAX_HEADERS:
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
            receipt["declared_length_matches_catalog"] = receipt.get("content_length") == SIZE
            if method == "GET":
                receipt["catalog_size_mismatch"] = receipt.get("content_length") != SIZE
                if (receipt.get("http_status") != 200 or receipt.get("content_range") is not None or
                        receipt.get("content_length") != OBSERVED_ARCHIVE_BYTES or
                        receipt.get("actual_archive_bytes") != OBSERVED_ARCHIVE_BYTES):
                    error = error or Blocked("GET must match the reviewed exact 200/no-range/byte-length exception")
        if error:
            raise Blocked(str(error)) from error
        return receipt

    def verify_and_expand(self, package):
        output = self.command(["/usr/sbin/pkgutil", "--check-signature", str(package)], timeout=90)
        self.report["certificate_sha256"] = signature_gate(output.decode())
        self.report["signature_verified"] = True
        self.report["payload_file_count"] = self.command(
            ["/usr/sbin/pkgutil", "--payload-files", str(package)], timeout=90, consumer=PayloadListing())
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
    if sys.argv[1:] not in ([], ["--http-metadata-only"]):
        raise Blocked("Unknown archive inspection arguments")
    inspector = Inspector(os.environ["RUNNER_TEMP"], Path(os.environ["RUNNER_TEMP"]) / "legacy-ios-archive-report")
    try:
        inspector.inspect(http_metadata_only=sys.argv[1:] == ["--http-metadata-only"])
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
