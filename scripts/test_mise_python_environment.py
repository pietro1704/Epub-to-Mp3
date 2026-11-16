"""Verify the host interpreter matches the Python declared in mise."""

import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_interpreter_matches_the_declared_host_python() -> None:
    configuration = tomllib.loads((ROOT / "mise.toml").read_text(encoding="utf-8"))
    declared = configuration["tools"]["python"]
    actual = ".".join(str(part) for part in sys.version_info[:3])
    assert actual == declared, f"Stale virtualenv: running {actual}, configured {declared}"
