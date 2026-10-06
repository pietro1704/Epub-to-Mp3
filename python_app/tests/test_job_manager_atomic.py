# -*- coding: utf-8 -*-
"""Regression tests for JobManager atomic-write guarantee.

Job state is persisted many times per conversion. A non-atomic write
(write_text or json.dump straight to the target path) leaves the file
half-written if the process is killed mid-write — the next load_job
call fails to parse the JSON and returns None, so the job appears
gone from disk even though it was running seconds earlier.

The fix is the standard write-to-tmp-then-os.replace pattern:
os.replace is atomic on POSIX and atomic-since-3.3 on Windows.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from python_app.src.job_manager import JobManager


@pytest.fixture()
def jm(tmp_path: Path) -> JobManager:
    return JobManager(tmp_path / ".jobs")


def _read_raw(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_save_job_writes_target_file(jm: JobManager) -> None:
    """Baseline: a successful save leaves the final file with valid JSON."""
    ok = jm.save_job("job-a", {"state": "running", "chaptersCompleted": 3})
    assert ok is True

    target = jm._get_job_file("job-a")
    assert target.exists()

    raw = _read_raw(target)
    parsed = json.loads(raw)  # must be valid JSON, not partial
    assert parsed["state"] == "running"
    assert parsed["chaptersCompleted"] == 3


def test_save_job_preserves_previous_on_crash(
    jm: JobManager, monkeypatch: pytest.MonkeyPatch
) -> None:
    """If json.dump raises mid-write, the previously persisted file
    must remain intact and parseable. Pre-fix this regressed because
    open(target, "w") truncated the target before json.dump ran.
    """
    assert jm.save_job("job-b", {"state": "running", "chaptersCompleted": 1}) is True
    target = jm._get_job_file("job-b")
    original_bytes = target.read_bytes()

    real_dump = json.dump

    def _exploding_dump(obj: Any, fp: Any, **kwargs: Any) -> None:  # type: ignore[no-untyped-def]
        # Simulate a SIGTERM or disk-full landing partway through the
        # serialisation. The atomic-write fix writes to a sibling
        # tmp file, so the target stays untouched.
        fp.write('{"state": "run')  # partial JSON
        raise RuntimeError("simulated mid-write crash")

    monkeypatch.setattr(json, "dump", _exploding_dump)
    ok = jm.save_job("job-b", {"state": "running", "chaptersCompleted": 2})
    assert ok is False, "save_job must report failure when the write crashes"

    # The original file content is still intact and still parseable.
    assert target.read_bytes() == original_bytes
    parsed = json.loads(_read_raw(target))
    assert parsed["chaptersCompleted"] == 1

    monkeypatch.setattr(json, "dump", real_dump)
    # And a follow-up clean save still wins on the target path.
    assert jm.save_job("job-b", {"state": "completed", "chaptersCompleted": 5}) is True
    parsed = json.loads(_read_raw(target))
    assert parsed["state"] == "completed"
    assert parsed["chaptersCompleted"] == 5


def test_save_job_cleans_up_tmp_on_crash(jm: JobManager, monkeypatch: pytest.MonkeyPatch) -> None:
    """A failed write must not leave dangling *.tmp files in the jobs dir."""
    assert jm.save_job("job-c", {"state": "running"}) is True
    target = jm._get_job_file("job-c")

    def _exploding_dump(obj: Any, fp: Any, **kwargs: Any) -> None:  # type: ignore[no-untyped-def]
        fp.write("garbage")
        raise RuntimeError("boom")

    monkeypatch.setattr(json, "dump", _exploding_dump)
    assert jm.save_job("job-c", {"state": "completed"}) is False

    # No leftover *.tmp file should remain in the jobs directory.
    leftovers = list(target.parent.glob("*.tmp"))
    assert leftovers == [], f"unexpected tmp leftovers: {leftovers}"


def test_save_job_first_write_is_atomic_no_partial_on_crash(
    jm: JobManager, monkeypatch: pytest.MonkeyPatch
) -> None:
    """First-ever save for a job_id: if it crashes mid-write, the
    target file must NOT exist as a half-written stub. With the old
    direct-open pattern, the target was created and truncated before
    json.dump ran, leaving a 0-byte file that load_job would treat as
    a json error.
    """

    def _exploding_dump(obj: Any, fp: Any, **kwargs: Any) -> None:  # type: ignore[no-untyped-def]
        fp.write("{")
        raise RuntimeError("boom-first-write")

    monkeypatch.setattr(json, "dump", _exploding_dump)
    assert jm.save_job("job-d", {"state": "queued"}) is False

    target = jm._get_job_file("job-d")
    # Atomicity contract: either the final file exists with valid JSON,
    # or it does not exist at all. A partial file is never observable.
    if target.exists():
        json.loads(_read_raw(target))  # raises if partial
