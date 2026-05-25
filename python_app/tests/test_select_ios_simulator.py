"""Tests for scripts/select_ios_simulator.py.

The selector is the source of truth for the `IOS_DEST` value passed to
`xcodebuild`. The mise `ios:build` task previously hard-coded
`name=iPhone SE,OS=17.2`, which silently broke whenever the locally
installed simulator was named `iPhone SE (2nd generation)`. The
selector reads the live `xcrun simctl list -j devices available`
payload and picks the best match, preferring:

1. A booted iOS simulator (any model, any iOS version).
2. An available iPhone SE (any generation) on the newest installed iOS.
3. Any available iPhone on the newest installed iOS.

If nothing matches, the selector exits non-zero with a clear message so
CI / local dev sees an actionable error instead of a generic
xcodebuild "Unable to find a device matching the provided destination
specifier" trace.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "select_ios_simulator.py"


def _run(payload: dict) -> subprocess.CompletedProcess[str]:
    """Invoke the script with the given simctl JSON piped on stdin."""
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--stdin"],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        check=False,
    )


def test_prefers_booted_simulator() -> None:
    payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-2": [
                {
                    "name": "iPhone SE (2nd generation)",
                    "udid": "AAA",
                    "state": "Booted",
                    "isAvailable": True,
                },
                {
                    "name": "iPhone 15",
                    "udid": "BBB",
                    "state": "Shutdown",
                    "isAvailable": True,
                },
            ]
        }
    }
    result = _run(payload)
    assert result.returncode == 0, result.stderr
    assert "id=AAA" in result.stdout
    assert "platform=iOS Simulator" in result.stdout


def test_prefers_iphone_se_when_nothing_booted() -> None:
    payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-2": [
                {
                    "name": "iPhone 15",
                    "udid": "BBB",
                    "state": "Shutdown",
                    "isAvailable": True,
                },
                {
                    "name": "iPhone SE (3rd generation)",
                    "udid": "CCC",
                    "state": "Shutdown",
                    "isAvailable": True,
                },
            ]
        }
    }
    result = _run(payload)
    assert result.returncode == 0, result.stderr
    assert "id=CCC" in result.stdout


def test_falls_back_to_any_iphone() -> None:
    payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-2": [
                {
                    "name": "iPhone 15 Pro",
                    "udid": "DDD",
                    "state": "Shutdown",
                    "isAvailable": True,
                }
            ]
        }
    }
    result = _run(payload)
    assert result.returncode == 0, result.stderr
    assert "id=DDD" in result.stdout


def test_picks_newest_runtime_when_multiple_present() -> None:
    payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-2": [
                {
                    "name": "iPhone SE (2nd generation)",
                    "udid": "OLD",
                    "state": "Shutdown",
                    "isAvailable": True,
                }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
                {
                    "name": "iPhone SE (3rd generation)",
                    "udid": "NEW",
                    "state": "Shutdown",
                    "isAvailable": True,
                }
            ],
        }
    }
    result = _run(payload)
    assert result.returncode == 0, result.stderr
    # Newest runtime wins when only iPhone-SE fallback applies — id=NEW.
    assert "id=NEW" in result.stdout


def test_ignores_unavailable_devices() -> None:
    payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-2": [
                {
                    "name": "iPhone SE (2nd generation)",
                    "udid": "AAA",
                    "state": "Shutdown",
                    "isAvailable": False,
                    "availabilityError": "runtime profile not found",
                }
            ]
        }
    }
    result = _run(payload)
    assert result.returncode != 0
    assert "no available ios simulator" in result.stderr.lower()


def test_errors_when_no_ios_runtime() -> None:
    payload = {"devices": {}}
    result = _run(payload)
    assert result.returncode != 0
    assert "no available ios simulator" in result.stderr.lower()


def test_ignores_non_ios_runtimes() -> None:
    payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.watchOS-10-2": [
                {
                    "name": "Apple Watch Series 9",
                    "udid": "WATCH",
                    "state": "Booted",
                    "isAvailable": True,
                }
            ]
        }
    }
    result = _run(payload)
    assert result.returncode != 0


def test_ignores_non_iphone_when_no_iphone_present() -> None:
    payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-2": [
                {
                    "name": "iPad Pro (12.9-inch) (6th generation)",
                    "udid": "IPAD",
                    "state": "Shutdown",
                    "isAvailable": True,
                }
            ]
        }
    }
    result = _run(payload)
    # iPad is acceptable as last-resort iOS Simulator target.
    assert result.returncode == 0
    assert "id=IPAD" in result.stdout
