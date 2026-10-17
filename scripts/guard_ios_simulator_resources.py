#!/usr/bin/env python3
"""Read-only macOS resource preflight/observer. This never releases quarantine."""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

GIB = 1024**3
MIB = 1024**2


class CollectionError(Exception):
    """A required observation could not be established."""


class PanicDetected(CollectionError):
    """A new host panic is a stop event, never a reason to retry collection."""


@dataclass(frozen=True)
class Policy:
    minimum_free_percent: int = 20
    minimum_disk_bytes: int = 8 * GIB
    maximum_swap_growth_bytes: int = 256 * MIB
    maximum_sample_seconds: float = 5.0
    query_timeout_seconds: float = 2.0


def run_query(argv: list[str], timeout: float) -> str:
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CollectionError(f"required query unavailable: {argv[0]}") from error
    if result.returncode != 0 or len(result.stdout) > 65536:
        raise CollectionError(f"required query failed: {argv[0]}")
    return result.stdout


class Collector:
    """Fixed read-only queries; dependency injection is for host-free unit tests."""

    def __init__(
        self,
        *,
        runner=run_query,
        clock=time.monotonic,
        host=platform.system,
        disk_usage=shutil.disk_usage,
        disk_path: Path = Path.cwd(),
        panic_directories=None,
        policy: Policy = Policy(),
    ):
        self.runner, self.clock, self.host = runner, clock, host
        self.disk_usage, self.disk_path, self.policy = disk_usage, disk_path, policy
        self.panic_directories = (
            panic_directories
            if panic_directories is not None
            else (
                Path("/Library/Logs/DiagnosticReports"),
                Path.home() / "Library/Logs/DiagnosticReports",
            )
        )

    def panic_identities(self) -> list[str]:
        identities = []
        inspected = 0
        for directory in self.panic_directories:
            if not directory.exists():
                continue
            inspected += 1
            with os.scandir(directory) as entries:
                for count, entry in enumerate(entries):
                    if count >= 4096:
                        raise CollectionError("panic directory exceeds bounded inspection")
                    name = entry.name.lower()
                    if not (
                        name.endswith(".panic")
                        or (
                            name.endswith(".ips") and ("panic" in name or name.startswith("kernel"))
                        )
                    ):
                        continue
                    info = entry.stat(follow_symlinks=False)
                    if not stat.S_ISREG(info.st_mode):
                        raise CollectionError("panic report is not a regular file")
                    identities.append(
                        f"{directory}/{entry.name}:{info.st_ino}:{info.st_size}:{info.st_mtime_ns}"
                    )
        if not inspected:
            raise CollectionError("no panic-report directory could be inspected")
        return sorted(identities)

    def collect(
        self, *, deadline: float | None = None, panic_baseline: list[str] | None = None
    ) -> dict:
        if self.host() != "Darwin":
            raise CollectionError("unsupported host: macOS observations are required")
        started = self.clock()
        sample_deadline = started + self.policy.maximum_sample_seconds
        if deadline is not None:
            sample_deadline = min(sample_deadline, deadline)

        def query(argv):
            remaining = sample_deadline - self.clock()
            if remaining <= 0:
                raise CollectionError("sample collection exceeded its deadline")
            return self.runner(argv, min(remaining, self.policy.query_timeout_seconds))

        try:
            initial_panics = set(self.panic_identities())
            if panic_baseline is not None and initial_panics - set(panic_baseline):
                raise PanicDetected("new or changed panic report detected before collection")
            capacity = query(["/usr/sbin/sysctl", "-n", "hw.memsize", "hw.ncpu"]).splitlines()
            if len(capacity) != 2 or not all(
                re.fullmatch(r"[1-9]\d*", value) for value in capacity
            ):
                raise CollectionError("invalid memory/CPU capacity")
            memory_bytes, logical_cpus = map(int, capacity)
            pressure = query(["/usr/bin/memory_pressure", "-Q"])
            percentages = re.findall(r"System-wide memory free percentage:\s*(\d+)%", pressure)
            if len(percentages) != 1 or not 0 <= int(percentages[0]) <= 100:
                raise CollectionError("invalid memory-pressure observation")
            free_percent = int(percentages[0])
            vm = query(["/usr/bin/vm_stat"])
            page_size = re.search(r"page size of ([1-9]\d*) bytes", vm)
            vm_values = dict(re.findall(r"^([A-Za-z ]+):\s*(\d+)\.?\s*$", vm, re.MULTILINE))
            required = (
                "Pages free",
                "Pages active",
                "Pages inactive",
                "Pages wired down",
                "Pages occupied by compressor",
                "Pageouts",
                "Swapouts",
            )
            if page_size is None or not all(key in vm_values for key in required):
                raise CollectionError("invalid VM observation")
            swap = query(["/usr/sbin/sysctl", "-n", "vm.swapusage"])
            used = re.search(r"\bused\s*=\s*(\d+(?:\.\d+)?)([KMGT])\b", swap)
            if used is None:
                raise CollectionError("invalid swap observation")
            swap_bytes = int(float(used[1]) * 1024 ** ("KMGT".index(used[2]) + 1))
            load = query(["/usr/sbin/sysctl", "-n", "vm.loadavg"])
            values = re.fullmatch(
                r"\s*\{\s*(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s*\}\s*", load
            )
            if values is None:
                raise CollectionError("invalid load observation")
            load_averages = [float(value) for value in values.groups()]
            if not all(math.isfinite(value) for value in load_averages):
                raise CollectionError("invalid load observation")
            free_disk = self.disk_usage(self.disk_path).free
            if not isinstance(free_disk, int) or free_disk < 0:
                raise CollectionError("invalid disk observation")
            panics = self.panic_identities()
            if set(panics) - initial_panics:
                raise PanicDetected("new or changed panic report detected during collection")
            finished = self.clock()
            if finished > sample_deadline or finished < started:
                raise CollectionError("stale sample: collection exceeded its deadline")
            return {
                "started_monotonic": started,
                "collected_monotonic": finished,
                "collection_seconds": finished - started,
                "memory_bytes": memory_bytes,
                "logical_cpus": logical_cpus,
                "memory_free_percent": free_percent,
                "vm_page_size": int(page_size[1]),
                "vm_pages": {key: int(vm_values[key]) for key in required},
                "swap_used_bytes": swap_bytes,
                "load_averages": load_averages,
                "disk_free_bytes": free_disk,
                "panic_identities": panics,
            }
        except CollectionError:
            raise
        except (OSError, ValueError, OverflowError) as error:
            raise CollectionError(f"required observation failed: {type(error).__name__}") from error


def decide(sample: dict, baseline: dict, policy: Policy, now: float) -> list[str]:
    reasons = []
    if not 0 <= now - sample["collected_monotonic"] <= policy.maximum_sample_seconds:
        reasons.append("sample is stale or clock moved backwards")
    if sample["memory_free_percent"] < policy.minimum_free_percent:
        reasons.append("memory pressure: free percentage below policy")
    if sample["disk_free_bytes"] < policy.minimum_disk_bytes:
        reasons.append("disk headroom below policy")
    if sample["swap_used_bytes"] - baseline["swap_used_bytes"] > policy.maximum_swap_growth_bytes:
        reasons.append("swap growth exceeded policy")
    if sample["load_averages"][0] > min(6.0, 0.75 * sample["logical_cpus"]):
        reasons.append("CPU load exceeded policy")
    if set(sample["panic_identities"]) - set(baseline["panic_identities"]):
        reasons.append("new or changed panic report detected")
    return reasons


def observe(
    collector: Collector,
    *,
    duration: float = 0,
    interval: float = 1,
    emit,
    clock=time.monotonic,
    sleep=time.sleep,
    cancelled=lambda: False,
) -> int:
    """Observe only; a deny stays latched even if later samples recover."""
    start = clock()
    deadline = start + duration if duration else None
    baseline = None
    denied = []
    count = 0
    cancellation = False
    fatal_stop = False
    emit(
        {
            "event": "policy",
            "limits": asdict(collector.policy),
            "load1_limit": "min(6.0, 0.75 * logical_cpus)",
            "duration_seconds": duration,
            "interval_seconds": interval,
            "scope": "read-only observation; no Simulator authorization or driver stability claim",
        }
    )
    try:
        while True:
            if cancelled():
                cancellation = True
                break
            if deadline is not None and clock() >= deadline:
                break
            try:
                sample = collector.collect(
                    deadline=deadline,
                    panic_baseline=baseline["panic_identities"] if baseline else None,
                )
                if baseline is None:
                    baseline = sample
                reasons = decide(sample, baseline, collector.policy, clock())
                fatal_stop = "new or changed panic report detected" in reasons
                if cancelled():
                    cancellation = True
                    reasons.append("observation cancelled")
                count += 1
                emit(
                    {
                        "event": "sample",
                        "sample": sample,
                        "decision": "deny" if reasons else "allow",
                        "reasons": reasons,
                    }
                )
            except CollectionError as error:
                fatal_stop = isinstance(error, PanicDetected)
                reasons = [str(error)]
                emit({"event": "collection_error", "decision": "deny", "reasons": reasons})
            denied.extend(reason for reason in reasons if reason not in denied)
            if fatal_stop or cancellation:
                break
            if duration == 0 or clock() - start >= duration:
                break
            sleep(min(interval, max(0, duration - (clock() - start))))
    except (KeyboardInterrupt, InterruptedError):
        cancellation = True
    cancellation = cancellation or bool(cancelled())
    if cancellation:
        if "observation cancelled" not in denied:
            denied.append("observation cancelled")
    if count == 0 and not denied:
        denied.append("no valid sample was collected")
    emit(
        {
            "event": "final",
            "decision": "deny" if denied else "allow",
            "reasons": denied,
            "samples": count,
            "elapsed_seconds": clock() - start,
            "cancelled": cancellation,
            "fatal_stop": fatal_stop,
        }
    )
    return 130 if cancellation else 75 if denied else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--observe",
        type=float,
        metavar="SECONDS",
        default=0,
        help="bounded read-only observation (0 means one preflight)",
    )
    parser.add_argument("--interval", type=float, default=1)
    args = parser.parse_args(argv)
    if not math.isfinite(args.observe) or not 0 <= args.observe <= 300:
        parser.error("--observe must be finite and between 0 and 300 seconds")
    if not math.isfinite(args.interval) or not 0.1 <= args.interval <= 5:
        parser.error("--interval must be finite and between 0.1 and 5 seconds")
    interrupted = []
    previous = {
        number: signal.signal(number, lambda sig, frame: interrupted.append(sig))
        for number in (signal.SIGINT, signal.SIGTERM)
    }

    def emit(record):
        record["timestamp_utc"] = datetime.now(timezone.utc).isoformat()
        print(json.dumps(record, sort_keys=True, allow_nan=False), flush=True)

    try:
        result = observe(
            Collector(),
            duration=args.observe,
            interval=args.interval,
            emit=emit,
            cancelled=lambda: bool(interrupted),
        )
        return 128 + interrupted[0] if interrupted else result
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    sys.exit(main())
