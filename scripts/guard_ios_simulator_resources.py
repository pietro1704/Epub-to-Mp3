#!/usr/bin/env python3
"""Refuse local iOS Simulator builds on machines known to panic under load.

This guard is intentionally local-developer focused. CI can opt out with
IOS_ALLOW_LOW_RESOURCE_SIMULATOR=1 because GitHub-hosted macOS runners are sized
for simulator builds and do not use this Intel MacBook's PCIe/Simulator stack.
"""

from __future__ import annotations

import os
import platform
import subprocess
import sys

_MIN_SAFE_MEMORY_GIB = 12


def _sysctl(name: str) -> str:
    return subprocess.check_output(["sysctl", "-n", name], text=True).strip()


def _memory_gib() -> float:
    return int(_sysctl("hw.memsize")) / (1024**3)


def _machine_model() -> str:
    try:
        return _sysctl("hw.model")
    except Exception:
        return platform.machine()


def main() -> int:
    # --device-test relaxes the hard refusal: device tests (real iPhone) do not
    # boot CoreSimulator, so they are allowed, but still warn so the operator
    # serializes the work and does not stack it onto another heavy job — the
    # actual CPU CATERR / PCIe panic trigger is *concurrent* load, not the
    # Simulator specifically.
    device_test = "--device-test" in sys.argv

    if os.environ.get("IOS_ALLOW_LOW_RESOURCE_SIMULATOR") == "1":
        return 0

    model = _machine_model()
    memory_gib = _memory_gib()
    arch = platform.machine().lower()
    is_intel = arch in {"x86_64", "i386"}

    if is_intel and memory_gib < _MIN_SAFE_MEMORY_GIB:
        if device_test:
            print(
                f"ios:device:test on a constrained Mac ({model}, "
                f"{memory_gib:.1f} GiB). Device tests are allowed (no Simulator), "
                "but this machine kernel-panics under concurrent load "
                "(CPU CATERR / PCIe↔T2). Run this ALONE — do not stack it on a "
                "build, the full pytest suite, or a flutter build.",
                file=sys.stderr,
            )
            return 0
        print(
            "ios:simulator refused: this local Mac is too resource-constrained for "
            "iOS Simulator work.\n\n"
            f"Detected: {model}, {memory_gib:.1f} GiB RAM, arch={arch}.\n"
            "Reason: recent iOS Simulator/CoreSimulator workloads have caused "
            "kernel panics on this Intel 8 GiB MacBook (CPU CATERR / PCIe↔T2 "
            "link timeout under load).\n\n"
            "Safe alternatives:\n"
            "  - Use GitHub Release Desktop / CI for iOS artifacts.\n"
            "  - Run macOS-only local builds with `mise run mac:build`.\n"
            "  - Use a physical iPhone with `mise run ios:device:run`.\n"
            "  - If you deliberately accept the risk on a better machine, set "
            "IOS_ALLOW_LOW_RESOURCE_SIMULATOR=1.\n",
            file=sys.stderr,
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
