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
    if os.environ.get("IOS_ALLOW_LOW_RESOURCE_SIMULATOR") == "1":
        return 0

    model = _machine_model()
    memory_gib = _memory_gib()
    arch = platform.machine().lower()
    is_intel = arch in {"x86_64", "i386"}

    if is_intel and memory_gib < _MIN_SAFE_MEMORY_GIB:
        print(
            "ios:build refused: this local Mac is too resource-constrained for "
            "iOS Simulator builds.\n\n"
            f"Detected: {model}, {memory_gib:.1f} GiB RAM, arch={arch}.\n"
            "Reason: recent iOS Simulator/CoreSimulator workloads have caused "
            "kernel panics on this Intel 8 GiB MacBook.\n\n"
            "Safe alternatives:\n"
            "  - Use GitHub Release Desktop / CI for iOS artifacts.\n"
            "  - Run macOS-only local builds with `mise run mac:build`.\n"
            "  - If you deliberately accept the risk on a better machine, set "
            "IOS_ALLOW_LOW_RESOURCE_SIMULATOR=1.\n",
            file=sys.stderr,
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
