"""Check manifest consistency against the distribution installed by CI.

The repo ships two `requirements.txt` files (root + `python_app/`). When a
Dependabot bump touches only one, the two drift and CI installs a different
set of dependencies than local runs.

Pandas 3.0.4 was yanked after the dependency update in #341. Reject that
known-bad installation without freezing the newest acceptable release.
CI must resolve and install the current requirement before running this suite.
"""

from __future__ import annotations

from importlib.metadata import version
from pathlib import Path

import pytest
from packaging.requirements import Requirement
from packaging.version import Version

REPO_ROOT = Path(__file__).resolve().parents[2]

_ROOT_REQ = REPO_ROOT / "requirements.txt"
_APP_REQ = REPO_ROOT / "python_app" / "requirements.txt"

def _pandas_pin(path: Path) -> str:
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("pandas"):
            return stripped
    raise AssertionError(f"{path} does not pin pandas")


def _assert_pandas_installation(installed: str, pin: str) -> None:
    candidate = Version(installed)
    assert candidate != Version("3.0.4"), "pandas 3.0.4 was yanked from PyPI (#341)"
    assert candidate in Requirement(pin).specifier, (
        f"Installed pandas {installed} does not satisfy {pin}"
    )


def test_both_manifests_pin_pandas_identically() -> None:
    root_pin = _pandas_pin(_ROOT_REQ)
    app_pin = _pandas_pin(_APP_REQ)
    assert root_pin == app_pin, (
        "requirements.txt files disagree on the pandas pin — a bump touched "
        f"only one. root={root_pin!r} python_app={app_pin!r}"
    )


def test_installed_pandas_satisfies_current_manifests() -> None:
    installed = version("pandas")
    for manifest in (_ROOT_REQ, _APP_REQ):
        _assert_pandas_installation(installed, _pandas_pin(manifest))


@pytest.mark.parametrize("installed", ["3.1.0", "3.2.0"])
def test_newer_compatible_releases_do_not_require_an_oracle_update(installed: str) -> None:
    _assert_pandas_installation(installed, "pandas>=3.1.0,<4.0.0")


def test_known_yanked_release_is_rejected_even_inside_the_requested_range() -> None:
    with pytest.raises(AssertionError, match="yanked"):
        _assert_pandas_installation("3.0.4", "pandas>=3.0.3,<4.0.0")


@pytest.mark.parametrize("installed", ["3.0.3", "4.0.0"])
def test_installed_release_must_satisfy_both_bounds(installed: str) -> None:
    with pytest.raises(AssertionError, match="does not satisfy"):
        _assert_pandas_installation(installed, "pandas>=3.1.0,<4.0.0")
