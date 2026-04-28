"""Static guard: every release manifest must report the same version.

The auto-release workflow (`.github/workflows/auto-release.yml`) refuses to
tag a new release when `python_app/version.py`, `desktop/src-tauri/tauri.conf.json`
and `web/package.json` disagree, *and* requires a matching CHANGELOG entry.
This test surfaces the mismatch locally so we don't push a commit that the
release pipeline will silently skip.

It also keeps `desktop/src-tauri/Cargo.toml` (and its lockfile) aligned —
those are not validated by the workflow but a stale Cargo version inside
the released binary confuses end users reporting bugs.
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


def _read_tauri_version() -> str:
    return json.loads(
        (REPO_ROOT / "desktop" / "src-tauri" / "tauri.conf.json").read_text(encoding="utf-8")
    )["version"]


def _read_web_version() -> str:
    return json.loads((REPO_ROOT / "web" / "package.json").read_text(encoding="utf-8"))["version"]


def _read_cargo_version() -> str:
    text = (REPO_ROOT / "desktop" / "src-tauri" / "Cargo.toml").read_text(encoding="utf-8")
    match = re.search(r'^version = "([^"]+)"', text, re.MULTILINE)
    assert match, "Cargo.toml must define a version"
    return match.group(1)


def _read_cargo_lock_version() -> str:
    text = (REPO_ROOT / "desktop" / "src-tauri" / "Cargo.lock").read_text(encoding="utf-8")
    match = re.search(
        r'\[\[package\]\]\s*\nname = "epub-to-mp3"\s*\nversion = "([^"]+)"',
        text,
    )
    assert match, "Cargo.lock must contain an epub-to-mp3 package entry"
    return match.group(1)


def test_release_manifests_share_one_version() -> None:
    """The three files validated by `auto-release.yml` must agree."""
    versions = {
        "python_app/version.py": _read_python_version(),
        "desktop/src-tauri/tauri.conf.json": _read_tauri_version(),
        "web/package.json": _read_web_version(),
    }
    assert len(set(versions.values())) == 1, (
        "Release manifests disagree — auto-release.yml will reject the next "
        f"push. Versions: {versions}"
    )


def test_cargo_manifest_matches_release_version() -> None:
    """Keep the Tauri Rust crate aligned with the release manifests."""
    target = _read_python_version()
    assert _read_cargo_version() == target, (
        f"Cargo.toml version ({_read_cargo_version()}) drifted from release " f"version ({target})"
    )
    assert _read_cargo_lock_version() == target, (
        f"Cargo.lock epub-to-mp3 version ({_read_cargo_lock_version()}) "
        f"drifted from release version ({target})"
    )


def test_changelog_has_entry_for_current_version() -> None:
    """`auto-release.yml` aborts if CHANGELOG.md lacks the version heading."""
    target = _read_python_version()
    changelog = (REPO_ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    assert f"## [{target}]" in changelog, (
        f"CHANGELOG.md is missing a `## [{target}]` heading — auto-release "
        "will abort the release tag step."
    )
