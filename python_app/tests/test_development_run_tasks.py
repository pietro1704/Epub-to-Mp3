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


def test_simulator_resume_task_launches_only_an_installed_app() -> None:
    """A legacy simulator may run an installed build without being buildable."""
    mise = (ROOT / "mise.toml").read_text(encoding="utf-8")
    start = mise.index('[tasks."ios:simulator:resume"]')
    end = mise.index('[tasks."ios:simulator:test"]', start)
    task = mise[start:end]

    assert "guard_ios_simulator_resources.py" in task
    assert "simctl bootstatus" in task
    assert "simctl get_app_container" in task
    assert "simctl launch" in task
    assert "simctl install" not in task
    assert "mise run ios:build" not in task
    assert "xcodebuild" not in task


def test_vscode_exposes_debug_run_tasks() -> None:
    tasks = (ROOT / ".vscode" / "tasks.json").read_text(encoding="utf-8")

    assert '"mise run mac:run"' in tasks
    assert '"mise run ios:run"' in tasks
    assert '"IOS_TARGET=simulator mise run ios:run"' in tasks
    assert '"mise run flutter:run"' in tasks
