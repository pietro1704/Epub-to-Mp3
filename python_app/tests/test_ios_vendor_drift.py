"""Regression: the iOS-embedded site-packages must mirror the canonical
``python_app/`` source tree.

The iOS app ships a slim copy of `python_app/` under
``ios/EpubToMp3/Vendor/site-packages/python_app/``. The
``bootstrap-ios-python.sh`` script syncs the tree at build time, but
when a developer edits the canonical source and forgets to re-run the
script (or doesn't full-clean the Xcode build), the bundled copy goes
stale.

A stale copy of ``tts/__init__.py`` or ``ios_entrypoints.py`` is
particularly painful: the eager-factory version of ``tts/__init__.py``
crashes every chapter synthesis with ``No module named '_struct'`` on
iOS, and the developer has no obvious feedback loop because the test
suite passes against the canonical copy.

This test scans the two highest-risk files and surfaces drift early.
"""

from __future__ import annotations

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_DIR = REPO_ROOT / "python_app"
VENDOR_DIR = REPO_ROOT / "ios" / "EpubToMp3" / "Vendor" / "site-packages" / "python_app"


@pytest.mark.parametrize(
    "relpath",
    [
        "version.py",
        "src/ios_entrypoints.py",
        "src/ebook_reader.py",
        "src/paths.py",
        "src/utils.py",
        "src/tts/__init__.py",
        "src/tts/_edge_transport.py",
        "src/tts/_piper_transport.py",
    ],
)
def test_vendored_file_matches_source(relpath: str) -> None:
    """Each critical file must be byte-identical between source and
    Vendor. If you intentionally diverged (e.g. you stripped a
    server-only branch for iOS), update this test to whitelist the
    divergence."""
    source = SOURCE_DIR / relpath
    vendored = VENDOR_DIR / relpath
    if not source.is_file():
        pytest.skip(f"Source file missing: {source}")
    assert vendored.is_file(), (
        f"Missing vendored copy at {vendored}. Run "
        "`ios/EpubToMp3/scripts/bootstrap-ios-python.sh` to rebuild "
        "the embedded site-packages."
    )
    assert source.read_bytes() == vendored.read_bytes(), (
        f"Vendored {relpath} is out of sync with the canonical source. "
        "Run `ios/EpubToMp3/scripts/bootstrap-ios-python.sh` (or "
        "`mise run sidecar:build` for a full rebuild) to re-sync the "
        "iOS embed, then commit the updated Vendor/ tree alongside "
        "the source change."
    )
