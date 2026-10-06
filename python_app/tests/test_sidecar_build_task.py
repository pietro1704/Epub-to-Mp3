"""Regression checks for fast native macOS sidecar rebuild decisions."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_mac_run_replaces_the_previous_debug_instance() -> None:
    mise = (ROOT / "mise.toml").read_text(encoding="utf-8")
    start = mise.index('[tasks."mac:run"]')
    end = mise.index('[tasks."ios:build"]', start)
    task = mise[start:end]

    assert 'APP_EXECUTABLE="$APP_PATH/Contents/MacOS/EpubToMp3"' in task
    assert 'pkill -TERM -f "$APP_EXECUTABLE"' in task
    assert 'open "$APP_PATH"' in task
    assert 'open -n "$APP_PATH"' not in task
