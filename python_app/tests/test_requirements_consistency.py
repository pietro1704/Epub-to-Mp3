"""Static guard: the two requirements manifests must agree on shared pins.

The repo ships two `requirements.txt` files (root + `python_app/`). When a
Dependabot bump touches only one, the two drift and CI installs a different
set of dependencies than local runs.

This test also pins the lower bound of `pandas` at 3.0.3. The 3.0.4 release
was *yanked* from PyPI after Dependabot pinned `pandas>=3.0.4` (#341), which
broke every `pip install -r requirements.txt` with
`No matching distribution found for pandas<4.0.0,>=3.0.4`. The lower bound
must never climb to a version that is not installable — guard against that
regression here.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

_ROOT_REQ = REPO_ROOT / "requirements.txt"
_APP_REQ = REPO_ROOT / "python_app" / "requirements.txt"

# Lowest pandas release that is currently installable from PyPI. 3.0.4 was
# yanked; if the lower bound is ever raised above the newest published
# release again, CI breaks — this floor documents the known-good minimum.
_PANDAS_MIN_INSTALLABLE = (3, 0, 3)


def _pandas_pin(path: Path) -> str:
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("pandas"):
            return stripped
    raise AssertionError(f"{path} does not pin pandas")


def _pandas_lower_bound(pin: str) -> tuple[int, ...]:
    match = re.search(r">=\s*(\d+(?:\.\d+)*)", pin)
    assert match, f"pandas pin missing a >= lower bound: {pin!r}"
    return tuple(int(part) for part in match.group(1).split("."))


def test_both_manifests_pin_pandas_identically() -> None:
    root_pin = _pandas_pin(_ROOT_REQ)
    app_pin = _pandas_pin(_APP_REQ)
    assert root_pin == app_pin, (
        "requirements.txt files disagree on the pandas pin — a bump touched "
        f"only one. root={root_pin!r} python_app={app_pin!r}"
    )


def test_pandas_lower_bound_is_installable() -> None:
    """Regression guard for the yanked 3.0.4 that broke CI (#341)."""
    lower = _pandas_lower_bound(_pandas_pin(_ROOT_REQ))
    assert lower <= _PANDAS_MIN_INSTALLABLE, (
        f"pandas lower bound {lower} is above the last known-installable "
        f"release {_PANDAS_MIN_INSTALLABLE}; 3.0.4 was yanked from PyPI. "
        "Do not raise the floor past a published version."
    )
