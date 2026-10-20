"""Capture sanitized existing build metadata; never establish runtime eligibility."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import stat
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError

MAX_MANIFESTS = 8
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_INFOS = 32
MAX_INFO_BYTES = 256 * 1024
MAX_NODES = 2048
MAX_DEPTH = 12
MAX_OUTPUT_BYTES = 4 * 1024 * 1024
APPLE_DOCTYPE = b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
PATH_FIELDS = {"TestHostPath", "TestBundlePath", "UITargetAppPath"}
STRUCTURES = {"TestConfigurations", "TestTargets", "__xctestrun_metadata__"}
TARGETS = {"EpubToMp3Tests", "EpubToMp3UITests"}
INFO_STRINGS = {
    "CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType", "DTXcode", "DTXcodeBuild",
    "DTPlatformName", "DTPlatformVersion", "DTSDKName", "DTSDKBuild", "MinimumOSVersion",
    "LSMinimumSystemVersion",
}


class Blocked(Exception):
    pass


def components(value):
    if not isinstance(value, str) or not value or len(value) > 4096:
        raise Blocked("invalid_path")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise Blocked("invalid_path")
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise Blocked("path_escape")
    return parts


def absolute(value):
    path = Path(value).absolute()
    components(str(path)[1:])
    return path


def child_directory(root, parts, create=False):
    descriptor = os.dup(root)
    try:
        for part in parts:
            if create:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            following = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = following
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def directory(path, create=False):
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        return child_directory(descriptor, components(str(path)[1:]), create)
    finally:
        os.close(descriptor)


def identity(metadata):
    return (metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_size,
            metadata.st_mtime_ns, metadata.st_ctime_ns)


def read_regular(root, relative, limit):
    parts = components(relative)
    parent = child_directory(root, parts[:-1])
    descriptor = None
    try:
        before = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise Blocked("nonregular_or_oversized_input")
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
        if identity(os.fstat(descriptor)) != identity(before):
            raise Blocked("input_replaced")
        chunks = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > limit or identity(os.fstat(descriptor)) != identity(before):
            raise Blocked("input_changed")
        current_parent = child_directory(root, parts[:-1])
        try:
            after = os.stat(parts[-1], dir_fd=current_parent, follow_symlinks=False)
            if identity(os.fstat(current_parent)) != identity(os.fstat(parent)) or identity(after) != identity(before):
                raise Blocked("input_replaced")
        finally:
            os.close(current_parent)
        return data
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)


def parse_plist(data):
    parse_data = data
    if not data.startswith(b"bplist"):
        # Remove only Apple's exact standard declaration before parsing. No DTD
        # or entity declaration reaches the XML parser, and no resolver is used.
        parse_data = data.replace(APPLE_DOCTYPE, b"", 1)
        declarations = parse_data.upper()
        if b"\0" in data or b"<!ENTITY" in declarations or b"<!DOCTYPE" in declarations:
            raise Blocked("xml_declarations_not_supported")
    try:
        result = plistlib.loads(parse_data)
    except (ValueError, TypeError, OverflowError, ExpatError):
        raise Blocked("invalid_plist") from None
    if not isinstance(result, dict):
        raise Blocked("plist_root_not_object")
    return result


def inventory(root):
    manifests, infos = [], []
    pending = [([], os.dup(root))]
    nodes = 0
    try:
        while pending:
            parts, descriptor = pending.pop()
            try:
                if len(parts) > MAX_DEPTH:
                    raise Blocked("inventory_budget_exceeded")
                with os.scandir(descriptor) as entries:
                    for entry in entries:
                        nodes += 1
                        if nodes > MAX_NODES or len(parts) > MAX_DEPTH:
                            raise Blocked("inventory_budget_exceeded")
                        relative = "/".join([*parts, entry.name])
                        components(relative)
                        if entry.name.endswith(".xctestrun"):
                            manifests.append(relative)
                            if len(manifests) > MAX_MANIFESTS:
                                raise Blocked("manifest_count_exceeded")
                        elif entry.name == "Info.plist" and any(part.endswith((".app", ".xctest")) for part in parts):
                            infos.append(relative)
                            if len(infos) > MAX_INFOS:
                                raise Blocked("bundle_count_exceeded")
                        elif entry.is_dir(follow_symlinks=False):
                            if entry.name in {"Resources", "Frameworks", "models"} or entry.name.endswith((".dSYM", ".swiftmodule")):
                                continue
                            pending.append(([*parts, entry.name], child_directory(root, [*parts, entry.name])))
                        elif entry.is_symlink() and entry.name.endswith((".app", ".xctest")):
                            raise Blocked("symlink_bundle")
            finally:
                os.close(descriptor)
    finally:
        for _, descriptor in pending:
            os.close(descriptor)
    return sorted(manifests), sorted(infos)


def validate_reference(root, relative):
    parts = components(relative)
    parent = child_directory(root, parts[:-1])
    try:
        metadata = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
            raise Blocked("unsafe_bundle_reference")
    finally:
        os.close(parent)


def sanitize_manifest(value, products, descriptor):
    redacted = 0
    paths = []
    nodes = 0

    def visit(item, position=(), depth=0):
        nonlocal redacted, nodes
        nodes += 1
        if nodes > MAX_NODES or depth > MAX_DEPTH:
            raise Blocked("manifest_structure_budget_exceeded")
        if isinstance(item, list):
            return [visit(child, (*position, index), depth + 1) for index, child in enumerate(item)]
        if not isinstance(item, dict):
            redacted += 1
            return {}
        result = {}
        for key, child in item.items():
            if key in STRUCTURES or (not position and key in TARGETS):
                if not isinstance(child, (dict, list)):
                    raise Blocked("invalid_structural_type")
                result[key] = visit(child, (*position, key), depth + 1)
            elif key == "FormatVersion" and type(child) is int and 0 <= child <= 100:
                result[key] = child
            elif key in {"IsUITestBundle", "IsAppHostedTestBundle"} and type(child) is bool:
                result[key] = child
            elif key in {"BlueprintName", "ProductModuleName", "TestTargetName"} and child in TARGETS:
                result[key] = child
            elif key in PATH_FIELDS and isinstance(child, str):
                if child.startswith("/"):
                    absolute_path = absolute(child)
                    try:
                        relative = str(absolute_path.relative_to(products))
                    except ValueError:
                        raise Blocked("absolute_reference_outside_products") from None
                    validate_reference(descriptor, relative)
                    paths.append({"field": list((*position, key)), "original_form": "absolute_products",
                                  "products_relative": relative, "observed_type": "string"})
                    redacted += 1
                elif child.startswith("__TESTROOT__/"):
                    validate_reference(descriptor, child.removeprefix("__TESTROOT__/"))
                    result[key] = child
                elif child.startswith("__TESTHOST__/"):
                    components(child.removeprefix("__TESTHOST__/"))
                    result[key] = child
                elif "$" not in child and "__" not in child:
                    validate_reference(descriptor, child)
                    result[key] = child
                else:
                    redacted += 1
            else:
                redacted += 1
        return result

    sanitized = visit(value)
    return plistlib.dumps(sanitized, fmt=plistlib.FMT_BINARY, sort_keys=True), paths, redacted


def sanitize_info(value):
    result = {}
    for key, item in value.items():
        if key in INFO_STRINGS and isinstance(item, str) and re.fullmatch(r"[A-Za-z0-9_.+\-]{1,255}", item):
            result[key] = item
        elif key == "CFBundleSupportedPlatforms" and isinstance(item, list) and len(item) <= 4:
            if all(isinstance(platform_name, str) and platform_name in {"MacOSX", "iPhoneSimulator", "iPhoneOS"} for platform_name in item):
                result[key] = item
    return result


def source_receipt(environment):
    result = {}
    for key in ("CHECKOUT_SHA", "TREE_SHA", "PR_HEAD_SHA", "EVENT_SHA", "WORKFLOW_SHA"):
        value = environment.get(f"INVENTORY_{key}", "")
        if key == "PR_HEAD_SHA" and not value:
            result[key.lower()] = None
        elif re.fullmatch(r"[0-9a-f]{40}", value):
            result[key.lower()] = value
        else:
            raise Blocked("invalid_source_identity")
    state = environment.get("INVENTORY_WORKTREE_STATE", "unknown")
    if state not in {"clean", "dirty", "unknown"}:
        raise Blocked("invalid_worktree_state")
    result["worktree_state"] = state
    for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
        value = environment.get(key, "")
        if not re.fullmatch(r"[1-9][0-9]{0,19}", value):
            raise Blocked("invalid_run_identity")
        result[key.lower()] = value
    if environment.get("GITHUB_JOB") != "macos-preferences":
        raise Blocked("invalid_job_identity")
    arch = environment.get("EXPECTED_ARCH")
    if arch not in {"arm64", "x86_64"}:
        raise Blocked("invalid_architecture")
    host_os, host_arch = platform.system(), platform.machine()
    result.update(job_key="macos-preferences", architecture=arch,
                  observed_host_os=host_os if host_os in {"Darwin", "Linux", "Windows"} else "unknown",
                  observed_host_arch=host_arch if host_arch in {"arm64", "x86_64", "aarch64"} else "unknown")
    return result


def write_output(descriptor, name, data, budget):
    budget[0] += len(data)
    if budget[0] > MAX_OUTPUT_BYTES:
        raise Blocked("output_budget_exceeded")
    output = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=descriptor)
    with os.fdopen(output, "wb") as stream:
        stream.write(data)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--xcode-version-file", required=True)
    args = parser.parse_args(argv)
    out = root = None
    receipt = {"schema_version": 1, "capture_state": "blocked", "runtime_eligibility": "unverified",
               "manifests": [], "bundles": []}
    budget = [0]
    status = 2
    try:
        products, output = absolute(args.products), absolute(args.output)
        if output == products or output.is_relative_to(products) or products.is_relative_to(output):
            raise Blocked("overlapping_input_output")
        parent = directory(output.parent, create=True)
        try:
            os.mkdir(output.name, mode=0o700, dir_fd=parent)
            out = child_directory(parent, [output.name])
        finally:
            os.close(parent)
        receipt["source"] = source_receipt(os.environ)
        version_path = absolute(args.xcode_version_file)
        version_parent = directory(version_path.parent)
        try:
            version = read_regular(version_parent, version_path.name, 4096).decode("ascii")
        finally:
            os.close(version_parent)
        match = re.fullmatch(r"Xcode (16\.4)\nBuild version (16F6)\n?", version)
        if not match:
            raise Blocked("unsupported_xcode_receipt")
        receipt["xcode"] = {"version": match[1], "build": match[2]}
        try:
            root = directory(products)
        except FileNotFoundError:
            receipt["capture_state"] = "missing_manifest"
            status = 0
        else:
            manifests, infos = inventory(root)
            for index, relative in enumerate(manifests):
                original = read_regular(root, relative, MAX_MANIFEST_BYTES)
                sanitized, paths, redactions = sanitize_manifest(parse_plist(original), products, root)
                name = f"manifest-{index}.sanitized.plist"
                write_output(out, name, sanitized, budget)
                receipt["manifests"].append({"sanitized_file": name, "original_bytes": len(original),
                    "original_sha256": hashlib.sha256(original).hexdigest(),
                    "sanitized_sha256": hashlib.sha256(sanitized).hexdigest(),
                    "path_sidecar": paths, "redacted_fields": redactions})
            for relative in infos:
                original = read_regular(root, relative, MAX_INFO_BYTES)
                receipt["bundles"].append({"products_relative": relative,
                    "original_sha256": hashlib.sha256(original).hexdigest(),
                    "allowed_info": sanitize_info(parse_plist(original))})
            current = directory(products)
            try:
                if identity(os.fstat(current)) != identity(os.fstat(root)):
                    raise Blocked("products_replaced")
            finally:
                os.close(current)
            receipt["capture_state"] = "captured" if manifests else "missing_manifest"
            status = 0
    except Blocked as error:
        receipt["blocked_reason"] = str(error)
    except (OSError, UnicodeError, ValueError, TypeError, RecursionError):
        receipt["blocked_reason"] = "unreadable_or_unsafe_metadata"
    finally:
        if root is not None:
            os.close(root)
        if out is not None:
            try:
                current = directory(output)
                try:
                    if identity(os.fstat(current)) != identity(os.fstat(out)):
                        raise Blocked("output_replaced")
                finally:
                    os.close(current)
                write_output(out, "receipt.json", json.dumps(receipt, sort_keys=True, indent=2).encode(), budget)
            except (Blocked, OSError):
                status = 2
            os.close(out)
    if status:
        print("Native test metadata capture blocked; no runtime eligibility established.", file=sys.stderr)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
