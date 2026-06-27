#!/usr/bin/env python3
"""Serialize heavy local jobs on panic-prone machines.

The user's MacBookPro15,2 (Intel 2018, 8 GiB) kernel-panics under sustained
concurrent load: the CPU↔T2 PCIe link times out and the CPU raises a
catastrophic error (``x86 CPU CATERR detected`` /
``AppleEmbeddedPCIeUpLinkMgmt::_linkInterruptAction``). The trigger we control
is *concurrent* heavy work — multiple xcodebuild / pytest / flutter / simulator
jobs stacked at once.

This guard enforces a single-heavy-job-at-a-time policy via an advisory file
lock plus a load-average sanity check. It is intentionally local-developer
focused; CI opts out with ``HEAVY_JOB_GUARD_DISABLE=1`` because hosted runners
are sized for parallel builds and do not use this Intel Mac's PCIe stack.

Usage:
    python3 scripts/heavy_job_guard.py <label> -- <command> [args...]

The command runs only while holding the exclusive lock. If another heavy job
holds it, this process waits (default) or fails fast with HEAVY_JOB_GUARD_NOWAIT=1.
"""

from __future__ import annotations

import os
import platform
import subprocess
import sys
import time

_LOCK_PATH = "/tmp/epub2mp3.heavy-job.lock"
_MIN_SAFE_MEMORY_GIB = 12
# 1-minute load average above this on a constrained Intel box means we should
# not pile on another heavy job; wait for it to drain.
_LOAD_CEILING = float(os.environ.get("HEAVY_JOB_LOAD_CEILING", "6.0"))
_WAIT_POLL_SECONDS = 3
_WAIT_TIMEOUT_SECONDS = int(os.environ.get("HEAVY_JOB_WAIT_TIMEOUT", "1800"))


def _sysctl(name: str) -> str:
    return subprocess.check_output(["sysctl", "-n", name], text=True).strip()


def _memory_gib() -> float:
    try:
        return int(_sysctl("hw.memsize")) / (1024**3)
    except Exception:
        return float(_MIN_SAFE_MEMORY_GIB)


def _is_constrained_intel_mac() -> bool:
    """True only on the low-resource Intel Macs that panic under load."""
    if platform.system() != "Darwin":
        return False
    arch = platform.machine().lower()
    is_intel = arch in {"x86_64", "i386"}
    return is_intel and _memory_gib() < _MIN_SAFE_MEMORY_GIB


def _load_too_high() -> bool:
    try:
        one_min = os.getloadavg()[0]
    except (OSError, AttributeError):
        return False
    return one_min > _LOAD_CEILING


def _acquire_lock(label: str) -> "object":
    """Acquire an exclusive advisory lock; wait until free (or fail fast)."""
    import fcntl

    handle = open(_LOCK_PATH, "w")
    nowait = os.environ.get("HEAVY_JOB_GUARD_NOWAIT") == "1"
    deadline = time.monotonic() + _WAIT_TIMEOUT_SECONDS
    announced = False
    while True:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if nowait:
                holder = ""
                try:
                    with open(_LOCK_PATH) as r:
                        holder = r.read().strip()
                except Exception:
                    pass
                print(
                    f"heavy_job_guard: refusing to run '{label}' — another heavy "
                    f"job is already running{f' ({holder})' if holder else ''}.\n"
                    "Serialize heavy work on this Mac (CPU CATERR / PCIe panic risk). "
                    "Wait for it to finish, or set HEAVY_JOB_GUARD_DISABLE=1 to override.",
                    file=sys.stderr,
                )
                handle.close()
                raise SystemExit(75)  # EX_TEMPFAIL
            if not announced:
                print(
                    f"heavy_job_guard: '{label}' waiting for the current heavy job "
                    "to finish (one-at-a-time on this Intel Mac)…",
                    file=sys.stderr,
                )
                announced = True
            if time.monotonic() > deadline:
                print(
                    f"heavy_job_guard: timed out after {_WAIT_TIMEOUT_SECONDS}s "
                    f"waiting to run '{label}'.",
                    file=sys.stderr,
                )
                handle.close()
                raise SystemExit(75)
            time.sleep(_WAIT_POLL_SECONDS)

    handle.seek(0)
    handle.truncate()
    handle.write(f"{label} pid={os.getpid()} ts={int(time.time())}\n")
    handle.flush()
    return handle


def main(argv: list[str]) -> int:
    if "--" not in argv:
        print("usage: heavy_job_guard.py <label> -- <command> [args...]", file=sys.stderr)
        return 2
    split = argv.index("--")
    label = " ".join(argv[:split]) or "heavy-job"
    command = argv[split + 1 :]
    if not command:
        print("heavy_job_guard: no command to run.", file=sys.stderr)
        return 2

    if os.environ.get("HEAVY_JOB_GUARD_DISABLE") == "1" or not _is_constrained_intel_mac():
        return subprocess.call(command)

    # Back off if the machine is already hot before we even queue.
    if _load_too_high() and os.environ.get("HEAVY_JOB_GUARD_NOWAIT") == "1":
        print(
            f"heavy_job_guard: load average too high for '{label}' "
            f"(>{_LOAD_CEILING}); refusing to add load (PCIe panic risk).",
            file=sys.stderr,
        )
        return 75

    handle = _acquire_lock(label)
    try:
        # Once we hold the lock, wait out any transient load spike before
        # launching, so we never start a heavy job onto an already-hot CPU.
        waited = 0
        while _load_too_high() and waited < 60:
            time.sleep(_WAIT_POLL_SECONDS)
            waited += _WAIT_POLL_SECONDS
        return subprocess.call(command)
    finally:
        import fcntl

        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            handle.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
