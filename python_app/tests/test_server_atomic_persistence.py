# -*- coding: utf-8 -*-
"""Regression tests for atomic JSON persistence in server.py.

`_save_stream_index` (per-job streaming manifest) and `_save_cover_cache`
(cover-thumbnail index) both used a raw `Path.write_text(json.dumps(...))`
call against the live target path. The pattern is non-atomic: a SIGTERM,
ENOMEM or disk-full landing between `open(target, "w")` and the final
`close` leaves the target file with partial JSON. The next reader
(`_load_stream_index`, `_load_cover_cache`) catches the parse error and
silently returns `{"chapters": {}}` / `{}` — every stream chunk recorded
for the job vanishes, and every cached cover thumbnail has to be
re-extracted from the source EPUB.

The slice 39 fix to `JobManager.save_job` already shipped the
write-to-tmp-then-`os.replace` pattern. These tests extend the same
contract to the two remaining persistence call sites in server.py:

  * mid-write fault never leaves the target with partial JSON;
  * mid-write fault never leaves orphan `*.tmp` files in the parent;
  * a successful save still rewrites the target byte-for-byte.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pytest

import python_app.server as srv


@pytest.fixture()
def isolated_output(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Redirect output_dir + cover_index_path under tmp_path for isolation."""
    monkeypatch.setattr(srv, "output_dir", tmp_path)
    cover_dir = tmp_path / ".cover_cache"
    cover_dir.mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(srv, "cover_index_path", cover_dir / "index.json")
    return tmp_path


# ---------------------------------------------------------------------------
# _save_stream_index
# ---------------------------------------------------------------------------


def test_save_stream_index_writes_valid_json(isolated_output: Path) -> None:
    """Baseline: a successful save produces a fully-valid JSON target."""
    job_id = "stream-job-baseline"
    srv._save_stream_index(job_id, {"chapters": {"0": {"chunks": []}}})

    target = srv._stream_index_path(job_id)
    assert target.exists()
    parsed = json.loads(target.read_text(encoding="utf-8"))
    assert parsed["chapters"]["0"]["chunks"] == []


def test_save_stream_index_preserves_previous_on_replace_failure(
    isolated_output: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """If the atomic rename fails mid-publish, the previously persisted
    bytes must remain intact on disk. Pre-fix (`write_text` straight on
    the target) this assertion fails because the truncate-then-write
    sequence had already destroyed the previous content before the
    crash hit.
    """
    job_id = "stream-job-replace-fault"
    baseline = {"chapters": {"0": {"chunks": [{"id": "0", "index": 0}]}}}
    srv._save_stream_index(job_id, baseline)
    target = srv._stream_index_path(job_id)
    original_bytes = target.read_bytes()

    def _exploding_replace(src: Any, dst: Any) -> None:
        raise RuntimeError("simulated SIGTERM between tmp write and rename")

    monkeypatch.setattr(os, "replace", _exploding_replace)

    with pytest.raises(RuntimeError, match="simulated SIGTERM"):
        srv._save_stream_index(job_id, {"chapters": {"0": {"chunks": []}}})

    assert target.read_bytes() == original_bytes
    # Parse round-trip just to be sure no partial bytes leaked into the
    # baseline path.
    assert json.loads(target.read_text(encoding="utf-8")) == baseline


def test_save_stream_index_first_write_no_partial_target(
    isolated_output: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """First-ever save crashing must NOT leave a half-written target. With
    the old direct-write pattern the file was created and truncated to
    zero bytes before the dump began, so a crash mid-dump left a 0-byte
    target that `_load_stream_index` couldn't parse.
    """
    job_id = "stream-job-first-write-fault"

    def _exploding_replace(src: Any, dst: Any) -> None:
        raise RuntimeError("simulated crash before rename")

    monkeypatch.setattr(os, "replace", _exploding_replace)

    with pytest.raises(RuntimeError, match="simulated crash before rename"):
        srv._save_stream_index(job_id, {"chapters": {}})

    target = srv._stream_index_path(job_id)
    # Atomicity contract: either the target does not exist, or it has
    # fully valid JSON. A truncated stub is never observable.
    if target.exists():
        json.loads(target.read_text(encoding="utf-8"))  # raises on partial


def test_save_stream_index_cleans_up_tmp_on_failure(
    isolated_output: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A failed atomic publish must not leave dangling *.tmp orphans in
    the streams directory — orphans accumulate across restarts and end
    up shipped to the user as part of the per-job ZIP.
    """
    job_id = "stream-job-tmp-cleanup"
    srv._save_stream_index(job_id, {"chapters": {}})
    target = srv._stream_index_path(job_id)
    streams_dir = target.parent

    def _exploding_replace(src: Any, dst: Any) -> None:
        raise RuntimeError("boom")

    monkeypatch.setattr(os, "replace", _exploding_replace)

    with pytest.raises(RuntimeError, match="boom"):
        srv._save_stream_index(job_id, {"chapters": {"0": {"chunks": []}}})

    leftovers = [p for p in streams_dir.iterdir() if p.suffix == ".tmp" or ".tmp" in p.name]
    assert leftovers == [], f"unexpected tmp leftovers: {leftovers}"


# ---------------------------------------------------------------------------
# _save_cover_cache
# ---------------------------------------------------------------------------


def test_save_cover_cache_writes_valid_json(isolated_output: Path) -> None:
    """Baseline: cover cache index round-trips through save/load cleanly."""
    payload = {"abc123": {"path": "cover.jpg", "ext": ".jpg"}}
    srv._save_cover_cache(payload)

    raw = srv.cover_index_path.read_text(encoding="utf-8")
    parsed = json.loads(raw)
    assert parsed == payload


def test_save_cover_cache_no_partial_on_write_fault(
    isolated_output: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`_save_cover_cache` swallows IOErrors by design, so this test
    exercises the **observable** side-effect: even when the underlying
    write crashes mid-flight, the target file must never end up as
    partial / unparseable JSON. Pre-fix the direct `write_text` left a
    truncated file behind, breaking `_load_cover_cache` on next start.
    """
    baseline = {"abc123": {"path": "cover.jpg"}}
    srv._save_cover_cache(baseline)

    def _exploding_replace(src: Any, dst: Any) -> None:
        raise OSError("simulated disk-full between tmp write and rename")

    monkeypatch.setattr(os, "replace", _exploding_replace)

    # Outer try/except in _save_cover_cache is intentional — must NOT
    # propagate (cover thumbnails are best-effort).
    srv._save_cover_cache({"abc123": {"path": "cover.jpg"}, "def456": {"path": "new.jpg"}})

    # Target must still be valid JSON. With the old direct write_text
    # pattern the file would be truncated/partial here and json.loads
    # would raise.
    parsed = json.loads(srv.cover_index_path.read_text(encoding="utf-8"))
    assert parsed == baseline


def test_save_cover_cache_cleans_up_tmp_on_failure(
    isolated_output: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A swallowed write failure must still tidy up the tmp file so the
    `.cover_cache/` directory doesn't accumulate orphans over time.
    """
    srv._save_cover_cache({"abc": {"path": "c.jpg"}})
    cover_dir = srv.cover_index_path.parent

    def _exploding_replace(src: Any, dst: Any) -> None:
        raise OSError("boom")

    monkeypatch.setattr(os, "replace", _exploding_replace)
    srv._save_cover_cache({"abc": {"path": "c.jpg"}, "xyz": {"path": "x.jpg"}})

    leftovers = [p for p in cover_dir.iterdir() if p.name.endswith(".tmp") or ".tmp." in p.name]
    assert leftovers == [], f"unexpected tmp leftovers: {leftovers}"


def test_persist_job_preserves_custom_priority_key(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    jobs_dir = tmp_path / ".jobs"
    jobs_dir.mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(srv, "job_manager", srv.JobManager(jobs_dir))
    monkeypatch.setattr(srv, "_recent_jobs_index", {})

    job_id = "priority-persist"
    srv.jobs[job_id] = {
        "jobId": job_id,
        "state": "queued",
        "bookTitle": "Priority Book",
        "events": [],
        "_raw_log": [],
        "priorityChapterIndex": 7,
    }

    srv._persist_job(job_id, force=True)

    reloaded = srv.job_manager.load_job(job_id)
    assert reloaded is not None
    assert reloaded["priorityChapterIndex"] == 7
