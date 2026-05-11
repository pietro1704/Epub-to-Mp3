"""Static guard: every release manifest must report the same version.

The auto-release workflow (`.github/workflows/auto-release.yml`) refuses to
tag a new release when `python_app/version.py` and `web/package.json`
disagree, *and* requires a matching CHANGELOG entry. This test surfaces
the mismatch locally so we don't push a commit that the release pipeline
will silently skip.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def _read_python_version() -> str:
    text = (REPO_ROOT / "python_app" / "version.py").read_text(encoding="utf-8")
    match = re.search(r'__version__ = "(.+)"', text)
    assert match, "python_app/version.py must define __version__"
    return match.group(1)


def _read_web_version() -> str:
    return json.loads((REPO_ROOT / "web" / "package.json").read_text(encoding="utf-8"))["version"]


def test_release_manifests_share_one_version() -> None:
    """The two files validated by `auto-release.yml` must agree."""
    versions = {
        "python_app/version.py": _read_python_version(),
        "web/package.json": _read_web_version(),
    }
    assert len(set(versions.values())) == 1, (
        "Release manifests disagree — auto-release.yml will reject the next "
        f"push. Versions: {versions}"
    )


def test_changelog_has_entry_for_current_version() -> None:
    """`auto-release.yml` aborts if CHANGELOG.md lacks the version heading."""
    target = _read_python_version()
    changelog = (REPO_ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    assert f"## [{target}]" in changelog, (
        f"CHANGELOG.md is missing a `## [{target}]` heading — auto-release "
        "will abort the release tag step."
    )
