"""Exercise legacy UTC formats without deprecated datetime operations."""

from __future__ import annotations

import json
import os
import re
import time
import warnings
from datetime import datetime, timezone
from pathlib import Path

import pytest

from python_app import server
from python_app.src.job_manager import JobManager
from python_app.src.telemetry import TelemetryRecorder


@pytest.fixture(autouse=True)
def deprecated_datetime_calls_fail():
    with warnings.catch_warnings():
        warnings.simplefilter("error", DeprecationWarning)
        yield


def assert_naive_utc_iso(value: str, before: datetime) -> None:
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{6})?", value)
    parsed = datetime.fromisoformat(value)
    assert parsed.tzinfo is None
    assert before <= parsed.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc)


def test_job_save_preserves_naive_utc_metadata_and_original_payload(tmp_path):
    manager = JobManager(tmp_path / "jobs")
    payload = {"jobId": "owned-job", "state": "running", "chaptersCompleted": 2}
    before = datetime.now(timezone.utc)

    assert manager.save_job("owned-job", payload) is True

    stored = json.loads((manager.jobs_dir / "owned-job.json").read_text())
    assert_naive_utc_iso(stored.pop("_saved_at"), before)
    assert stored == payload
    assert "_saved_at" not in payload
    assert JobManager(manager.jobs_dir).load_job("owned-job") == payload


@pytest.mark.parametrize("inaccessible_member", [False, True])
def test_cleanup_removes_only_expired_jobs_and_continues_after_stat_failure(
    tmp_path, monkeypatch, inaccessible_member
):
    manager = JobManager(tmp_path / "jobs")
    now = time.time()
    old = manager.jobs_dir / "expired.json"
    fresh = manager.jobs_dir / "recent.json"
    inaccessible = manager.jobs_dir / "unreadable.json"
    foreign = manager.jobs_dir / "unrelated.txt"
    outside = tmp_path / "outside.json"
    for path in (old, fresh, inaccessible, foreign, outside):
        path.write_text('{"state":"completed"}')
    for path in (old, inaccessible, foreign, outside):
        os.utime(path, (now - 72 * 3600, now - 72 * 3600))
    os.utime(fresh, (now - 12 * 3600, now - 12 * 3600))
    manager._memory_cache["expired"] = {"state": "completed"}
    original_stat = Path.stat
    original_glob = Path.glob

    def ordered_job_members(path, pattern, *args, **kwargs):
        if path == manager.jobs_dir and pattern == "*.json":
            return iter((inaccessible, old, fresh))
        return original_glob(path, pattern, *args, **kwargs)

    def stat_with_one_failure(path, *args, **kwargs):
        if inaccessible_member and path == inaccessible:
            raise OSError("owned stat failure")
        return original_stat(path, *args, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(Path, "stat", stat_with_one_failure)
        patch.setattr(Path, "glob", ordered_job_members)
        deleted = manager.cleanup_old_jobs(max_age_hours=48)

    assert deleted == (1 if inaccessible_member else 2)
    assert not old.exists()
    assert "expired" not in manager._memory_cache
    assert fresh.exists()
    assert inaccessible.exists() is inaccessible_member
    assert foreign.exists()
    assert outside.exists()


def test_telemetry_keeps_second_precision_single_z_and_ignores_invalid_sample(tmp_path):
    recorder = TelemetryRecorder(telemetry_file=tmp_path / "samples.json")
    sample = dict(
        engine="piper", voice="fixture", chars=50, synth_seconds=2,
        total_seconds=3, audio_seconds=4, job_id="owned-job", chapter="chapter-1",
    )
    before = datetime.now(timezone.utc).replace(microsecond=0)

    recorder.record_sample(**sample)
    stored = json.loads(recorder.jsonl_file.read_text())
    stamp = stored["timestamp"]
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", stamp)
    assert before <= datetime.fromisoformat(stamp) <= datetime.now(timezone.utc)
    assert stored["job_id"] == "owned-job"
    assert stored["chapter"] == "chapter-1"
    original_bytes = recorder.jsonl_file.read_bytes()
    recorder.record_sample(**{**sample, "chars": 0})
    assert recorder.jsonl_file.read_bytes() == original_bytes
    recorder.flush()
    assert recorder.recent_samples(limit=1)[0]["timestamp"] == stamp


@pytest.mark.parametrize("saved_at,metadata", [
    (None, {}),
    ("2026-01-02T03:04:05.123456", {"_saved_at": "older"}),
    (None, {"_saved_at": "2025-12-01T02:03:04"}),
])
def test_resume_summary_preserves_supplied_dates_and_naive_utc_fallback(saved_at, metadata):
    before = datetime.now(timezone.utc)
    payload = {"state": "running", "bookTitle": "Owned book", **metadata}

    summary = server._summarize_resume_job("owned-job", payload, saved_at=saved_at)

    expected = saved_at or metadata.get("_saved_at")
    if expected is None:
        assert_naive_utc_iso(summary["savedAt"], before)
    else:
        assert summary["savedAt"] == expected
    assert summary["jobId"] == "owned-job"
    assert summary["bookTitle"] == "Owned book"
    assert payload == {"state": "running", "bookTitle": "Owned book", **metadata}


@pytest.mark.parametrize("raw", [None, "literal raw message"])
def test_event_log_preserves_utc_clock_format_and_broadcast_identity(monkeypatch, raw):
    broadcasts = []
    monkeypatch.setattr(
        server, "_schedule_job_broadcast",
        lambda job_id, payload: broadcasts.append((job_id, payload)),
    )
    job = {"jobId": "owned-job"}
    before = datetime.now(timezone.utc).replace(microsecond=0)

    server._append_event(job, "Owned event", raw=raw)

    after = datetime.now(timezone.utc)
    stamp, message = job["_raw_log"][0].split(" ", 1)
    assert re.fullmatch(r"\d{2}:\d{2}:\d{2}", stamp)
    clock = datetime.strptime(stamp, "%H:%M:%S").time()
    assert any(
        before <= datetime.combine(day, clock, tzinfo=timezone.utc) <= after
        for day in {before.date(), after.date()}
    )
    assert message == (raw if raw is not None else "Owned event")
    assert job["events"] == ["Owned event"]
    assert len(broadcasts) == 1
    assert broadcasts[0][0] == "owned-job"
    assert broadcasts[0][1] is job
    assert isinstance(job["_lastActivityTs"], float)
