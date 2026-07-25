"""Regression checks for local Debug run tasks."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_run_tasks_use_debug_development_paths() -> None:
    mise = (ROOT / "mise.toml").read_text(encoding="utf-8")

    assert '[tasks."mac:run"]' in mise
    assert "mise run mac:build:dev" in mise
    assert '[tasks."ios:run"]' in mise
    assert 'TARGET="${IOS_TARGET:-device}"' in mise
    assert 'IOS_DEVICE_ID="$DEVICE" mise run ios:device:build' in mise
    assert "mise run ios:build" in mise
    assert '[tasks."flutter:run"]' in mise
    assert "select_android_target.py" in mise
    assert 'flutter run -d "$DEVICE"' in mise


def test_vscode_exposes_debug_run_tasks() -> None:
    tasks = (ROOT / ".vscode" / "tasks.json").read_text(encoding="utf-8")

    assert '"mise run mac:run"' in tasks
    assert '"mise run ios:run"' in tasks
    assert '"IOS_TARGET=simulator mise run ios:run"' in tasks
    assert '"mise run flutter:run"' in tasks
