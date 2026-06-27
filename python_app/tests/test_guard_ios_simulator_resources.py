"""Tests for scripts/guard_ios_simulator_resources.py."""

from __future__ import annotations

import importlib.util
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "guard_ios_simulator_resources.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("guard_ios_simulator_resources", SCRIPT)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_refuses_intel_8gb_mac_by_default(monkeypatch, capsys) -> None:
    module = _load_module()
    monkeypatch.delenv("IOS_ALLOW_LOW_RESOURCE_SIMULATOR", raising=False)
    monkeypatch.setattr(module.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(module, "_machine_model", lambda: "MacBookPro15,2")
    monkeypatch.setattr(module, "_memory_gib", lambda: 8.0)

    assert module.main() == 2
    assert "too resource-constrained" in capsys.readouterr().err


def test_allows_explicit_override_on_low_resource_mac(monkeypatch) -> None:
    module = _load_module()
    monkeypatch.setenv("IOS_ALLOW_LOW_RESOURCE_SIMULATOR", "1")
    monkeypatch.setattr(module.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(module, "_memory_gib", lambda: 8.0)

    assert module.main() == 0


def test_device_test_mode_allows_but_warns_on_low_resource_mac(monkeypatch, capsys) -> None:
    module = _load_module()
    monkeypatch.delenv("IOS_ALLOW_LOW_RESOURCE_SIMULATOR", raising=False)
    monkeypatch.setattr(module.sys, "argv", ["guard", "--device-test"])
    monkeypatch.setattr(module.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(module, "_machine_model", lambda: "MacBookPro15,2")
    monkeypatch.setattr(module, "_memory_gib", lambda: 8.0)

    # Device tests do not boot CoreSimulator, so they are allowed (exit 0)…
    assert module.main() == 0
    # …but must warn to serialize the run (concurrent load is the panic trigger).
    err = capsys.readouterr().err
    assert "concurrent load" in err
    assert "ALONE" in err


def test_allows_apple_silicon_or_larger_intel(monkeypatch) -> None:
    module = _load_module()
    monkeypatch.delenv("IOS_ALLOW_LOW_RESOURCE_SIMULATOR", raising=False)
    monkeypatch.setattr(module, "_machine_model", lambda: "MacBookPro18,3")

    monkeypatch.setattr(module.platform, "machine", lambda: "arm64")
    monkeypatch.setattr(module, "_memory_gib", lambda: 8.0)
    assert module.main() == 0

    monkeypatch.setattr(module.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(module, "_memory_gib", lambda: 16.0)
    assert module.main() == 0
