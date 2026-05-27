"""Tests for scripts/select_ios_simulator.py.

The selector is the source of truth for the `IOS_DEST` value passed to
`xcodebuild`. The mise `ios:build` task previously hard-coded
`name=iPhone SE,OS=17.2`, which silently broke whenever the locally
installed simulator was named `iPhone SE (2nd generation)`. The
selector reads the live `xcrun simctl list -j devices available`
payload and picks the best match from allowed runtimes, preferring:

1. A booted iOS simulator on an allowed runtime.
2. An available iPhone SE (any generation) on the newest allowed iOS.
3. Any available iPhone on the newest allowed iOS.

Recent simulator runtimes are blocked by default on this local Intel 8 GiB
Mac because they have triggered kernel panics. If nothing safe matches, the
selector exits non-zero with a clear message so CI / local dev sees an
actionable error instead of a generic xcodebuild "Unable to find a device
matching the provided destination specifier" trace.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "select_ios_simulator.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("select_ios_simulator", SCRIPT)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _run(payload: dict) -> subprocess.CompletedProcess[str]:
    """Invoke the script with the given simctl JSON piped on stdin."""
    env = {**os.environ, "IOS_MAX_SIMULATOR_MAJOR": "17"}
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--stdin"],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        check=False,
        env=env,
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


def test_prefers_newest_allowed_runtime_when_multiple_present() -> None:
    payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
                {
                    "name": "iPhone SE (2nd generation)",
                    "udid": "OLD",
                    "state": "Shutdown",
                    "isAvailable": True,
                }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-17-2": [
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
    assert "id=NEW" in result.stdout


def test_skips_recent_runtime_by_default_even_when_booted() -> None:
    payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-2": [
                {
                    "name": "iPhone SE (2nd generation)",
                    "udid": "SAFE",
                    "state": "Shutdown",
                    "isAvailable": True,
                }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-3": [
                {
                    "name": "iPhone 16 Pro",
                    "udid": "RISKY",
                    "state": "Booted",
                    "isAvailable": True,
                }
            ],
        }
    }
    result = _run(payload)
    assert result.returncode == 0, result.stderr
    assert "id=SAFE" in result.stdout


def test_recent_runtime_requires_explicit_opt_in() -> None:
    payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-3": [
                {
                    "name": "iPhone 16 Pro",
                    "udid": "RISKY",
                    "state": "Shutdown",
                    "isAvailable": True,
                }
            ]
        }
    }
    result = _run(payload)
    assert result.returncode != 0
    assert "allowed ios simulator" in result.stderr.lower()

    opt_in_env = {**os.environ, "IOS_ALLOW_RECENT_SIMULATOR": "1"}
    opted_in = subprocess.run(
        [sys.executable, str(SCRIPT), "--stdin"],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        check=False,
        env=opt_in_env,
    )
    assert opted_in.returncode == 0, opted_in.stderr
    assert "id=RISKY" in opted_in.stdout


def test_live_simctl_is_refused_on_low_resource_intel_mac(monkeypatch, capsys) -> None:
    module = _load_module()
    monkeypatch.delenv("IOS_ALLOW_LOW_RESOURCE_SIMULATOR", raising=False)
    monkeypatch.setattr(module.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(module, "_sysctl", lambda name: str(8 * 1024**3))

    assert module._refuse_live_simctl_on_low_resource_host() is True
    assert "refusing to query CoreSimulator" in capsys.readouterr().err


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
    assert "no available allowed ios simulator" in result.stderr.lower()


def test_errors_when_no_ios_runtime() -> None:
    payload = {"devices": {}}
    result = _run(payload)
    assert result.returncode != 0
    assert "no available allowed ios simulator" in result.stderr.lower()


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
