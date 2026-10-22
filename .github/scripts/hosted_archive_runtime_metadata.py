"""Bounded runtime layout and loader/cache metadata, without launching a runtime."""

import hosted_archive_contracts as contracts
import json
import os
from pathlib import Path
import stat
import time
from hosted_archive_contracts import (
    Blocked,
    cache_metadata,
    diagnostic_kind,
    diagnostic_path,
    macho_architectures,
    read_plist,
    within,
)


class ArchiveRuntimeMetadata:
    def __init__(self, root, report):
        self.root, self.report = root, report

    def runtime_layout(self, expanded):
        """Shallow diagnostic only; never selects or authorizes a runtime."""
        result = {"records": [], "scanned": 0, "invalid_paths": 0,
                  "depth_limit": contracts.LAYOUT_DEPTH, "truncated": False}
        deadline = time.monotonic() + contracts.LAYOUT_SECONDS

        def encoded_size(receipt):
            # Include the field wrapper and the final report's indentation.
            return len(json.dumps({"expanded_layout": receipt}, indent=2).encode())

        def walk(descriptor, relative, depth):
            with os.scandir(descriptor) as entries:
                for entry in entries:
                    if (time.monotonic() >= deadline or result["scanned"] >= contracts.LAYOUT_SCANNED or
                            len(result["records"]) >= contracts.LAYOUT_RECORDS):
                        result["truncated"] = True
                        return
                    result["scanned"] += 1
                    path = relative / entry.name
                    try:
                        name = diagnostic_path(Path("."), path)
                    except (Blocked, UnicodeError):
                        result["invalid_paths"] += 1
                        continue
                    details = entry.stat(follow_symlinks=False)
                    record = {"path": name, "kind": diagnostic_kind(details.st_mode)}
                    if encoded_size({**result, "records": result["records"] + [record]}) > contracts.LAYOUT_BYTES:
                        result["truncated"] = True
                        return
                    result["records"].append(record)
                    if stat.S_ISDIR(details.st_mode) and depth < contracts.LAYOUT_DEPTH:
                        child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                        dir_fd=descriptor)
                        try:
                            opened = os.fstat(child)
                            if (opened.st_dev, opened.st_ino) != (details.st_dev, details.st_ino):
                                raise Blocked("Layout directory identity changed")
                            walk(child, path, depth + 1)
                        finally:
                            os.close(child)
                        if result["truncated"]:
                            return

        root = os.open(within(self.root, expanded), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            walk(root, Path("."), 1)
        finally:
            os.close(root)
        # Recheck counters updated after the last retained record as well.
        while encoded_size(result) > contracts.LAYOUT_BYTES:
            if not result["records"]:
                raise Blocked("Layout diagnostic receipt exceeds its byte budget")
            result["records"].pop()
            result["truncated"] = True
        return result


    def inspect_runtime(self, expanded):
        runtimes = [item for item in expanded.rglob("*.simruntime") if not item.is_symlink()]
        discovery = {"count": len(runtimes), "sample": [], "sample_omitted": max(0, len(runtimes) - 8)}
        self.report["runtime_directory_candidates"] = discovery
        for item in runtimes[:8]:
            try:
                discovery["sample"].append({"path": diagnostic_path(expanded, item),
                                            "kind": diagnostic_kind(item.lstat().st_mode)})
            except Exception as error:
                discovery["sample_omitted"] += 1
                discovery["error_type"] = type(error).__name__
        if len(runtimes) != 1:
            try:
                self.report["expanded_layout"] = self.runtime_layout(expanded)
            except Exception as error:
                self.report["expanded_layout"] = {"error_type": type(error).__name__, "truncated": True}
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
                if count > 250_000 or measured > contracts.MAX_PAYLOAD:
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
