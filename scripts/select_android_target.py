#!/usr/bin/env python3
"""Select an Android device, preferring hardware and then the lightest AVD."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


def select_running_android_device(devices: list[dict[str, Any]]) -> str | None:
    """Return a physical Android ID first, then a running Android emulator."""
    android_devices = [
        device
        for device in devices
        if str(device.get("targetPlatform", "")).lower().startswith("android") and device.get("id")
    ]
    physical = [device for device in android_devices if not device.get("emulator", False)]
    selected = physical or android_devices
    return str(selected[0]["id"]) if selected else None


def _size_mebibytes(value: str | None, default: int) -> int:
    if not value:
        return default
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([KMG]?)(?:B)?\s*", value, re.I)
    if not match:
        return default
    amount = float(match.group(1))
    unit = match.group(2).upper()
    multiplier = {"K": 1 / 1024, "M": 1, "G": 1024}.get(unit, 1)
    return int(amount * multiplier)


def _read_avd_config(path: Path) -> dict[str, str]:
    return dict(
        line.split("=", 1)
        for line in path.read_text(encoding="utf-8").splitlines()
        if "=" in line and not line.lstrip().startswith("#")
    )


def find_lightest_avd(avd_root: Path) -> str | None:
    """Return the available AVD with the lowest resource footprint."""
    candidates: list[tuple[tuple[int, int, int, int, str], str]] = []
    for config_path in avd_root.glob("*.avd/config.ini"):
        config = _read_avd_config(config_path)
        name = config_path.parent.stem
        ram_mib = _size_mebibytes(config.get("hw.ramSize"), 4096)
        width = _size_mebibytes(config.get("hw.lcd.width"), 1440)
        height = _size_mebibytes(config.get("hw.lcd.height"), 2960)
        cores = _size_mebibytes(config.get("hw.cpu.ncore"), 4)
        disk_mib = _size_mebibytes(config.get("disk.dataPartition.size"), 8192)
        candidates.append(((ram_mib, width * height, cores, disk_mib, name.lower()), name))
    return min(candidates)[1] if candidates else None


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--devices-json", action="store_true")
    group.add_argument("--lightest-avd", action="store_true")
    args = parser.parse_args()

    if args.devices_json:
        device = select_running_android_device(json.load(sys.stdin))
        if device:
            print(device)
            return 0
        return 1

    avd_root = Path(os.environ.get("ANDROID_AVD_HOME", Path.home() / ".android" / "avd"))
    avd = find_lightest_avd(avd_root)
    if avd:
        print(avd)
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
