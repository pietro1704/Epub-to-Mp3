"""Tests for the Android development target selector."""

from __future__ import annotations

import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "select_android_target.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("select_android_target", SCRIPT)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_prefers_a_connected_android_device_over_an_emulator() -> None:
    module = _load_module()

    selected = module.select_running_android_device(
        [
            {"id": "emulator-5554", "targetPlatform": "android-x64", "emulator": True},
            {"id": "R5CT123", "targetPlatform": "android-arm64", "emulator": False},
        ]
    )

    assert selected == "R5CT123"


def test_uses_a_running_emulator_when_no_phone_is_connected() -> None:
    module = _load_module()

    assert (
        module.select_running_android_device(
            [{"id": "emulator-5554", "targetPlatform": "android-x64", "emulator": True}]
        )
        == "emulator-5554"
    )


def test_selects_the_lightest_available_avd(tmp_path: Path) -> None:
    module = _load_module()
    heavy = tmp_path / "Pixel_Heavy.avd"
    heavy.mkdir()
    (heavy / "config.ini").write_text(
        "hw.ramSize=4096\nhw.lcd.width=1440\nhw.lcd.height=3120\nhw.cpu.ncore=4\n",
        encoding="utf-8",
    )
    light = tmp_path / "Pixel_Light.avd"
    light.mkdir()
    (light / "config.ini").write_text(
        "hw.ramSize=1536\nhw.lcd.width=720\nhw.lcd.height=1280\nhw.cpu.ncore=2\n",
        encoding="utf-8",
    )

    assert module.find_lightest_avd(tmp_path) == "Pixel_Light"
