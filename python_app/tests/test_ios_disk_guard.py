"""Tests for scripts/ios_disk_guard.sh (age + size cap eviction)."""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "ios_disk_guard.sh"


def _make_dir(path: Path, size_mb: int, age_days: float = 0) -> None:
    # Write real bytes, not a sparse file via truncate() — `du` (used by the
    # script to measure disk usage) reports allocated blocks, and a sparse
    # file allocates none, making the size cap never trigger.
    path.mkdir(parents=True, exist_ok=True)
    with (path / "payload.bin").open("wb") as f:
        f.write(os.urandom(size_mb * 1024 * 1024))
    mtime = time.time() - age_days * 86400
    os.utime(path, (mtime, mtime))
    os.utime(path / "payload.bin", (mtime, mtime))


def _run(
    derived_data_root: Path, ios_build_dir: Path, **env_overrides: str
) -> subprocess.CompletedProcess:
    env = {
        **os.environ,
        "IOS_DISK_GUARD_DERIVED_DATA_ROOT": str(derived_data_root),
        "IOS_DISK_GUARD_IOS_BUILD_DIR": str(ios_build_dir),
        **env_overrides,
    }
    return subprocess.run(
        ["bash", str(SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=True,
    )


def test_evicts_build_dir_older_than_age_cap(tmp_path: Path) -> None:
    derived = tmp_path / "DerivedData"
    ios_dir = tmp_path / "EpubToMp3"
    old_build = ios_dir / ".build-old"
    fresh_build = ios_dir / ".build-fresh"
    _make_dir(old_build, size_mb=1, age_days=10)
    _make_dir(fresh_build, size_mb=1, age_days=0)

    _run(derived, ios_dir, IOS_DISK_GUARD_MAX_AGE_DAYS="3", IOS_DISK_GUARD_MAX_TOTAL_MB="4096")

    assert not old_build.exists(), "build dir older than the age cap must be evicted"
    assert fresh_build.exists(), "recently built dir must survive the age cap"


def test_evicts_oldest_first_when_over_size_cap(tmp_path: Path) -> None:
    derived = tmp_path / "DerivedData"
    ios_dir = tmp_path / "EpubToMp3"
    oldest = ios_dir / ".build-a"
    newest = ios_dir / ".build-b"
    # Both within the age cap so only the size cap can evict them.
    _make_dir(oldest, size_mb=5, age_days=1)
    _make_dir(newest, size_mb=5, age_days=0)

    _run(derived, ios_dir, IOS_DISK_GUARD_MAX_AGE_DAYS="30", IOS_DISK_GUARD_MAX_TOTAL_MB="6")

    assert not oldest.exists(), "oldest dir must be evicted first once over the size cap"
    assert newest.exists(), "newest dir must be kept when it alone fits under the size cap"


def test_leaves_everything_when_under_both_caps(tmp_path: Path) -> None:
    derived = tmp_path / "DerivedData"
    ios_dir = tmp_path / "EpubToMp3"
    build = ios_dir / ".build-current"
    _make_dir(build, size_mb=1, age_days=0)

    _run(derived, ios_dir, IOS_DISK_GUARD_MAX_AGE_DAYS="3", IOS_DISK_GUARD_MAX_TOTAL_MB="4096")

    assert build.exists(), "dirs under both caps must never be touched"


def test_never_touches_other_projects_derived_data(tmp_path: Path) -> None:
    derived = tmp_path / "DerivedData"
    ios_dir = tmp_path / "EpubToMp3"
    other_project = derived / "SomeOtherApp-abcdef"
    _make_dir(other_project, size_mb=1, age_days=30)

    _run(derived, ios_dir, IOS_DISK_GUARD_MAX_AGE_DAYS="3", IOS_DISK_GUARD_MAX_TOTAL_MB="4096")

    assert (
        other_project.exists()
    ), "only EpubToMp3-* DerivedData dirs may be touched, never other projects'"
