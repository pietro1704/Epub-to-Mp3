#!/usr/bin/env python3
"""Pick the best iOS Simulator destination for `xcodebuild`.

Usage
-----
- `select_ios_simulator.py`           reads `xcrun simctl list -j devices available`
- `select_ios_simulator.py --stdin`   reads the same JSON from stdin (tests)

Prints a destination string in the form
`platform=iOS Simulator,id=<udid>` on stdout and exits 0 on success, or
exits 1 with an actionable message on stderr when nothing usable is
installed. The mise `ios:build` task pipes the output into
`xcodebuild -destination`.

Preference order:

1. Any booted iOS simulator on an allowed runtime.
2. iPhone SE (any generation) on the newest allowed iOS runtime.
3. Any iPhone on the newest allowed iOS runtime.
4. Any iOS device (iPad, etc.) on the newest allowed iOS runtime.

By default, local selection refuses very recent simulator runtimes (> iOS 17)
because they have triggered kernel panics on resource-constrained Intel Macs.
Set IOS_ALLOW_RECENT_SIMULATOR=1 or IOS_MAX_SIMULATOR_MAJOR=<major> to opt in.

`isAvailable=False` devices are ignored — that matches Xcode's own
filter and avoids picking a simulator whose runtime profile is
missing.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
import sys
from typing import Any

_RUNTIME_PREFIX = "com.apple.CoreSimulator.SimRuntime.iOS-"
_RUNTIME_VERSION_RE = re.compile(r"iOS-(\d+)-(\d+)")
_DEFAULT_MAX_RUNTIME_MAJOR = 17


def _max_runtime_major() -> int | None:
    """Return the newest iOS runtime major allowed for local simulator builds."""
    if os.environ.get("IOS_ALLOW_RECENT_SIMULATOR") == "1":
        return None
    raw = os.environ.get("IOS_MAX_SIMULATOR_MAJOR")
    if raw:
        try:
            return int(raw)
        except ValueError:
            print(
                "select_ios_simulator: IOS_MAX_SIMULATOR_MAJOR must be an integer",
                file=sys.stderr,
            )
            sys.exit(2)
    return _DEFAULT_MAX_RUNTIME_MAJOR


def _sysctl(name: str) -> str:
    return subprocess.check_output(["sysctl", "-n", name], text=True).strip()


def _is_low_resource_intel_mac() -> bool:
    try:
        memory_gib = int(_sysctl("hw.memsize")) / (1024**3)
    except Exception:
        memory_gib = 999.0
    return platform.machine().lower() in {"x86_64", "i386"} and memory_gib < 12


def _refuse_live_simctl_on_low_resource_host() -> bool:
    if os.environ.get("IOS_ALLOW_LOW_RESOURCE_SIMULATOR") == "1":
        return False
    if not _is_low_resource_intel_mac():
        return False
    print(
        "select_ios_simulator: refusing to query CoreSimulator on this "
        "low-resource Intel Mac. Use CI for iOS Simulator builds, or set "
        "IOS_ALLOW_LOW_RESOURCE_SIMULATOR=1 only if you explicitly accept "
        "the kernel-panic risk.",
        file=sys.stderr,
    )
    return True


def _runtime_sort_key(runtime: str) -> tuple[int, int]:
    """Return `(major, minor)` for an iOS runtime identifier, oldest=0."""
    match = _RUNTIME_VERSION_RE.search(runtime)
    if not match:
        return (0, 0)
    return (int(match.group(1)), int(match.group(2)))


def _ios_runtimes(devices: dict[str, list[dict[str, Any]]]) -> list[str]:
    """Return allowed iOS runtime keys, newest first."""
    max_major = _max_runtime_major()
    runtimes = []
    for runtime in devices.keys():
        if not runtime.startswith(_RUNTIME_PREFIX):
            continue
        major, _minor = _runtime_sort_key(runtime)
        if max_major is not None and major > max_major:
            continue
        runtimes.append(runtime)
    runtimes.sort(key=_runtime_sort_key, reverse=True)
    return runtimes


def _available(dev: dict[str, Any]) -> bool:
    return bool(dev.get("isAvailable", False))


def _is_iphone_se(name: str) -> bool:
    return name.lower().startswith("iphone se")


def _is_iphone(name: str) -> bool:
    return name.lower().startswith("iphone")


def select(payload: dict[str, Any]) -> dict[str, Any] | None:
    """Pick the best simulator dict, or return None if nothing usable."""
    devices: dict[str, list[dict[str, Any]]] = payload.get("devices", {}) or {}
    runtimes = _ios_runtimes(devices)

    # Rule 1: any booted iOS simulator wins, but only on an allowed runtime.
    for runtime in runtimes:
        for dev in devices.get(runtime, []):
            if _available(dev) and dev.get("state") == "Booted":
                return dev

    # Rule 2: iPhone SE on the newest runtime that has one available.
    for runtime in runtimes:
        for dev in devices.get(runtime, []):
            if _available(dev) and _is_iphone_se(dev.get("name", "")):
                return dev

    # Rule 3: any iPhone on the newest runtime that has one available.
    for runtime in runtimes:
        for dev in devices.get(runtime, []):
            if _available(dev) and _is_iphone(dev.get("name", "")):
                return dev

    # Rule 4: last resort — any available iOS device (iPad, etc.).
    for runtime in runtimes:
        for dev in devices.get(runtime, []):
            if _available(dev):
                return dev

    return None


def _read_payload(use_stdin: bool) -> dict[str, Any]:
    if use_stdin:
        raw = sys.stdin.read()
    else:
        proc = subprocess.run(
            ["xcrun", "simctl", "list", "-j", "devices", "available"],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            print(
                f"select_ios_simulator: `xcrun simctl list` failed:\n{proc.stderr}",
                file=sys.stderr,
            )
            sys.exit(2)
        raw = proc.stdout
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"select_ios_simulator: malformed simctl JSON: {exc}", file=sys.stderr)
        sys.exit(2)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--stdin",
        action="store_true",
        help="Read simctl JSON from stdin (used by tests).",
    )
    args = parser.parse_args()

    if not args.stdin and _refuse_live_simctl_on_low_resource_host():
        return 2

    payload = _read_payload(args.stdin)
    pick = select(payload)
    if pick is None:
        print(
            "select_ios_simulator: no available allowed iOS simulator. "
            "Use an iOS <=17 runtime on local Intel/8GB Macs, or set "
            "IOS_ALLOW_RECENT_SIMULATOR=1 only on a machine with enough RAM.",
            file=sys.stderr,
        )
        return 1

    udid = pick.get("udid")
    if not udid:
        print(
            f"select_ios_simulator: chosen device has no UDID: {pick!r}",
            file=sys.stderr,
        )
        return 1

    print(f"platform=iOS Simulator,id={udid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
