"""Verify actual interpreter identity and mise's explicit environment routing."""

import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def test_interpreter_matches_the_declared_host_python() -> None:
    configuration = tomllib.loads((ROOT / "mise.toml").read_text(encoding="utf-8"))
    declared = configuration["tools"]["python"]
    actual = ".".join(str(part) for part in sys.version_info[:3])
    assert actual == declared, f"Stale virtualenv: running {actual}, configured {declared}"


@pytest.mark.parametrize("environment,expected", [(None, "3.14.10"), ("coqui", "3.11.18")])
def test_child_directory_selects_the_requested_python(environment: str | None, expected: str) -> None:
    process_environment = os.environ.copy()
    for key in ("MISE_ENV", "MISE_PYTHON_VERSION"):
        process_environment.pop(key, None)
    process_environment.update(
        MISE_AUTO_INSTALL="0",
        MISE_ENABLE_TOOLS="python",
        MISE_TRUSTED_CONFIG_PATHS=str(ROOT),
    )
    command = ["mise", "-C", str(ROOT / "python_app")]
    if environment:
        command.extend(["-E", environment])
    command.extend(["ls", "--current", "--json", "python"])
    result = subprocess.run(
        command, env=process_environment, check=True, capture_output=True, text=True
    )
    selected = json.loads(result.stdout)
    assert [tool["version"] for tool in selected] == [expected]
