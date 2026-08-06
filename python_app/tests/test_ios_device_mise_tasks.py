"""Regression checks for the physical iOS device workflow."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_device_build_targets_a_connected_device_without_simulator_guard() -> None:
    mise = (ROOT / "mise.toml").read_text(encoding="utf-8")
    start = mise.index('[tasks."ios:device:build"]')
    end = mise.index('[tasks."ios:simulator:run"]', start)
    task = mise[start:end]

    assert '-destination "id=$XCODE_DEVICE"' in task
    assert "IOS_DEVICE_ID" in task
    assert "IOS_XCODE_DEVICE_ID" in task
    assert "guard_ios_simulator_resources.py" not in task


def test_vscode_exposes_device_build_and_launch_tasks() -> None:
    tasks = (ROOT / ".vscode" / "tasks.json").read_text(encoding="utf-8")

    assert '"iOS: Build physical device"' in tasks
    assert '"mise run ios:device:build"' in tasks
    assert '"mise run ios:device:run"' in tasks


def test_sweetpad_is_pinned_to_the_nested_ios_project() -> None:
    settings = (ROOT / ".vscode" / "settings.json").read_text(encoding="utf-8")

    assert '"sweetpad.build.xcodeWorkspacePath": "ios/EpubToMp3/EpubToMp3.xcodeproj"' in settings
    assert '"sweetpad.build.scheme": "EpubToMp3"' in settings
    assert '"sweetpad.build.configuration": "Debug"' in settings
