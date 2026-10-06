"""Regression checks for mise Python environment configuration."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_mise_uses_the_current_python_venv_configuration() -> None:
    mise = (ROOT / "mise.toml").read_text(encoding="utf-8")

    assert 'python = "3.12.10"' in mise
    assert '_.python.venv = { path = ".venv", create = true }' in mise
    assert "virtualenv =" not in mise
