"""Regression tests for persistent path overrides."""

import os
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def test_persistent_root_override_controls_local_cache_and_output(tmp_path: Path) -> None:
    persistent_root = tmp_path / "persistent"
    env = os.environ.copy()
    env["PERSISTENT_ROOT"] = str(persistent_root)
    env.pop("SPACE_ID", None)
    env.pop("CACHE_DIR", None)
    env.pop("OUTPUT_DIR", None)

    probe = subprocess.run(
        [
            sys.executable,
            "-c",
            (
                "from python_app.src import paths; "
                "print(paths.PERSISTENT_ROOT); "
                "print(paths.CACHE_DIR); "
                "print(paths.OUTPUT_DIR)"
            ),
        ],
        cwd=PROJECT_ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )

    lines = probe.stdout.strip().splitlines()
    assert lines == [
        str(persistent_root.resolve()),
        str((persistent_root / ".cache").resolve()),
        str((persistent_root / "output").resolve()),
    ]
    assert (persistent_root / ".cache").is_dir()
    assert (persistent_root / "output").is_dir()
