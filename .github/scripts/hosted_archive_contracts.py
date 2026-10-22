"""Bounded archive identity, signature, HTTP and payload-format contracts."""

import hashlib
from datetime import datetime, timezone
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
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
# Complete signed BOM in hosted run 39163845178 at 8c5b5f1: 225519 regular,
# 85186 directories and 79 symlinks. This is a ceiling, not a listing equality.
MAX_SIGNED_BOM_ENTRIES = 310_784
MAX_LISTING_LINE = 4096
STREAM_CHUNK = 64 * 1024
LAYOUT_DEPTH = 2
LAYOUT_SCANNED = 256
LAYOUT_RECORDS = 64
LAYOUT_BYTES = 64 * 1024
LAYOUT_SECONDS = 1
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

    def __init__(self, entry_limit=None):
        self.entry_limit = MAX_LISTING_ENTRIES if entry_limit is None else entry_limit
        if (type(self.entry_limit) is not int or
                not 0 < self.entry_limit <= MAX_SIGNED_BOM_ENTRIES):
            raise Blocked("Payload listing entry budget is invalid")
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
            if self.entries > self.entry_limit:
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


class BomModes:
    """Bounded mode counts; paired signed metadata must authorize their use."""

    report_key = "bom_mode_inventory"

    def __init__(self, sha256):
        self.sha256 = sha256
        self.pending = b""
        self.entries = self.bytes = 0
        self.counts = dict.fromkeys(("regular", "directory", "symlink", "other"), 0)
        self.complete = False

    def feed(self, chunk):
        if len(chunk) > STREAM_CHUNK:
            raise Blocked("BOM modes chunk exceeds its read budget")
        self.bytes += len(chunk)
        if self.bytes > MAX_LISTING_BYTES:
            raise Blocked("BOM modes exceed the metadata byte budget")
        self.pending += chunk
        while b"\n" in self.pending:
            line, self.pending = self.pending.split(b"\n", 1)
            if not re.fullmatch(rb"[0-7]{1,6}", line):
                raise Blocked("Malformed BOM octal mode")
            kind = stat.S_IFMT(int(line, 8))
            if kind not in (stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK, stat.S_IFBLK,
                            stat.S_IFCHR, stat.S_IFIFO, stat.S_IFSOCK):
                raise Blocked("Unknown BOM mode type")
            label = {stat.S_IFREG: "regular", stat.S_IFDIR: "directory",
                     stat.S_IFLNK: "symlink"}.get(kind, "other")
            self.counts[label] += 1
            self.entries += 1
        if len(self.pending) > 6:
            raise Blocked("Malformed BOM octal mode")

    def finish(self):
        if self.pending or not self.entries:
            raise Blocked("Missing or incomplete BOM modes")
        self.complete = True
        return self.entries

    def receipt(self):
        return {"bom_sha256": self.sha256, "total": self.entries, **self.counts,
                "bytes": self.bytes, "complete": self.complete}


def safe_payload_listing(output):
    listing = PayloadListing()
    encoded = output.encode("utf-8")
    for offset in range(0, len(encoded), STREAM_CHUNK):
        listing.feed(encoded[offset:offset + STREAM_CHUNK])
    return listing.finish()


def package_info_metadata(directory, info):
    def identity(item):
        return item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns

    within(directory, info)
    before = info.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > 1024**2:
        raise Blocked("PackageInfo must be a bounded regular file")
    with os.fdopen(os.open(info, os.O_RDONLY | os.O_NOFOLLOW), "rb") as handle:
        if identity(os.fstat(handle.fileno())) != identity(before):
            raise Blocked("PackageInfo identity changed before reading")
        data = handle.read(1024**2 + 1)
        if identity(os.fstat(handle.fileno())) != identity(before):
            raise Blocked("PackageInfo identity changed while reading")
    after = info.lstat()
    if len(data) > 1024**2 or identity(before) != identity(after):
        raise Blocked("PackageInfo identity changed during inspection")
    if b"<!DOCTYPE" in data or b"<!ENTITY" in data:
        raise Blocked("PackageInfo contains unsupported XML declarations")
    root = ET.fromstring(data)
    payloads = root.findall("payload")
    if len(payloads) != 1 or not re.fullmatch(r"[1-9]\d*", payloads[0].get("installKBytes", "")):
        raise Blocked("Package payload size is unknown")
    count = payloads[0].get("numberOfFiles")
    if count is not None and not re.fullmatch(r"[0-9]{1,10}", count):
        raise Blocked("Declared package file count is malformed")
    location = root.get("install-location")
    location_form = "missing"
    suffix = False
    if location is not None:
        if (not location or len(location.encode("utf-8")) > MAX_LISTING_LINE or
                ".." in PurePosixPath(location).parts or
                any(ord(character) < 32 or ord(character) == 127 for character in location)):
            location_form = "invalid"
        else:
            location_form = "absolute" if location.startswith("/") else "relative"
            suffix = location.endswith(".simruntime")
    return ({"package_info_sha256": hashlib.sha256(data).hexdigest(),
             "install_bytes": int(payloads[0].get("installKBytes")) * 1024,
             "number_of_files": int(count) if count is not None else None,
             "install_location": {"form": location_form, "simruntime_suffix": suffix,
                                  "sha256": hashlib.sha256(location.encode("utf-8")).hexdigest()
                                  if location is not None else None}}, identity(after))


def declared_payload(directory, metadata=None, snapshots=None):
    infos = []
    for info in Path(directory).rglob("PackageInfo"):
        infos.append(info)
        if len(infos) > 128:
            raise Blocked("PackageInfo layout exceeds the component budget")
    if not infos:
        raise Blocked("PackageInfo layout is missing or ambiguous")
    total = 0
    for info in infos:
        details, identity = package_info_metadata(directory, info)
        total += details["install_bytes"]
        if total > MAX_PAYLOAD:
            raise Blocked("Declared package payload exceeds 24 GiB")
        if metadata is not None:
            metadata.append(details)
        if snapshots is not None:
            snapshots[info] = (identity, details["package_info_sha256"],
                               details["install_bytes"], details["number_of_files"])
    return total


def macho_architectures(filename):
    binary_file = Path(filename).open("rb")
    with binary_file:
        header = binary_file.read(4096)
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


def diagnostic_path(root, path):
    relative = path.relative_to(root).as_posix()
    if (".." in PurePosixPath(relative).parts or len(relative.encode("utf-8")) > MAX_LISTING_LINE or
            any(ord(character) < 32 or ord(character) == 127 for character in relative)):
        raise Blocked("Layout diagnostic path is invalid")
    return relative


def diagnostic_kind(mode):
    return {stat.S_IFREG: "regular", stat.S_IFDIR: "directory",
            stat.S_IFLNK: "symlink"}.get(stat.S_IFMT(mode), "other")
