"""Compatibility-only script: this is not a native safety certification.

Intel quarantine and preflight belong to native_job.rb and its Ruby tests.
This retained entry point must never start native work or revive RAM overrides.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "guard_ios_simulator_resources.py"


@pytest.mark.parametrize("arguments", [[], ["--device-test"]])
@pytest.mark.parametrize("old_override", ["0", "1"])
def test_compatibility_entrypoint_performs_no_native_work(
    tmp_path, arguments, old_override
) -> None:
    marker = tmp_path / "native-started"
    for tool in ("xcrun", "sysctl", "xcodebuild", "swift"):
        fixture = tmp_path / tool
        fixture.write_text('#!/bin/sh\n: > "$NATIVE_MARKER"\nexit 97\n')
        fixture.chmod(0o755)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), *arguments],
        env={
            **os.environ,
            "PATH": str(tmp_path),
            "NATIVE_MARKER": str(marker),
            "IOS_ALLOW_LOW_RESOURCE_SIMULATOR": old_override,
        },
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == result.stderr == ""
    assert not marker.exists()
