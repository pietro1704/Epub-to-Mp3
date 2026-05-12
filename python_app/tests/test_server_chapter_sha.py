# -*- coding: utf-8 -*-
"""SHA-256 propagation tests for the server conversion pipeline.

Covers three observable surfaces consumed by the iOS client:
  * ``complete_chapter_progress`` attaches ``sha256`` to the matching
    chapterProgress entry when given an output_path.
  * The restore-from-disk path in ``server._restore_job_from_outputs``
    publishes ``sha256`` for both ``outputs[]`` and ``chapterProgress[]``.
  * ``compute_mp3_sha256`` is missing-file-tolerant inside the helper
    that the conversion pipeline calls (errors must not abort the job).
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import pytest
from src import _server_audio_helpers as audio_helpers
from src._server_conversion_helpers import (
    _attach_chapter_sha256,
    complete_chapter_progress,
)


@pytest.fixture(autouse=True)
def _clear_sha_cache():
    audio_helpers._reset_sha256_cache()
    yield
    audio_helpers._reset_sha256_cache()


def _make_job(chapters: int = 1) -> dict:
    return {
        "jobId": "job-test",
        "chapterProgress": [
            {
                "index": idx,
                "name": f"Chapter {idx}",
                "status": "processing",
            }
            for idx in range(1, chapters + 1)
        ],
        "_chapterCharTotals": {idx: 500 for idx in range(1, chapters + 1)},
        "_chapterCharProcessed": {},
        "totalChars": 500 * chapters,
        "processedChars": 0,
    }


def test_complete_chapter_progress_attaches_sha256(tmp_path: Path) -> None:
    job = _make_job(chapters=2)
    audio = tmp_path / "001 - Chapter 1.mp3"
    audio.write_bytes(b"deterministic audio bytes" * 8)
    expected = hashlib.sha256(audio.read_bytes()).hexdigest()

    complete_chapter_progress(
        job,
        chapter_index=1,
        chapters_count=2,
        broadcast=False,
        output_path=audio,
    )

    entry = job["chapterProgress"][0]
    assert entry["sha256"] == expected
    # Untouched chapter must not gain an SHA.
    assert "sha256" not in job["chapterProgress"][1]


def test_complete_chapter_progress_without_output_path_omits_sha256() -> None:
    job = _make_job(chapters=1)
    complete_chapter_progress(
        job,
        chapter_index=1,
        chapters_count=1,
        broadcast=False,
    )
    assert "sha256" not in job["chapterProgress"][0]


def test_attach_sha256_missing_file_is_silent(tmp_path: Path, caplog) -> None:
    job = _make_job(chapters=1)
    ghost = tmp_path / "missing.mp3"
    # Must not raise — SHA is optional.
    _attach_chapter_sha256(job, 1, ghost)
    assert "sha256" not in job["chapterProgress"][0]


def test_attach_sha256_zero_byte_file_is_skipped(tmp_path: Path) -> None:
    job = _make_job(chapters=1)
    empty = tmp_path / "empty.mp3"
    empty.write_bytes(b"")
    _attach_chapter_sha256(job, 1, empty)
    assert "sha256" not in job["chapterProgress"][0]


def test_attach_sha256_uses_positional_fallback(tmp_path: Path) -> None:
    """If chapterProgress entries lack an ``index`` field, fall back to position."""
    job = {
        "jobId": "job-test",
        "chapterProgress": [
            {"name": "Chapter 1", "status": "completed"},
            {"name": "Chapter 2", "status": "completed"},
        ],
    }
    audio = tmp_path / "002.mp3"
    audio.write_bytes(b"chapter two bytes")
    _attach_chapter_sha256(job, 2, audio)
    assert job["chapterProgress"][1]["sha256"] == hashlib.sha256(audio.read_bytes()).hexdigest()


def test_restore_job_from_outputs_publishes_sha256(tmp_path: Path, monkeypatch) -> None:
    """End-to-end: restore path emits SHA in both outputs[] and chapterProgress[]."""
    import python_app.server as srv

    job_id = "restored-job"
    job_output_dir = tmp_path / "OutputsRoot" / job_id
    job_output_dir.mkdir(parents=True)

    payloads = [b"chapter one audio data", b"chapter two audio data"]
    expected_digests = []
    mp3_paths = []
    for idx, payload in enumerate(payloads, 1):
        mp3 = job_output_dir / f"{idx:03d} - Chapter.mp3"
        mp3.write_bytes(payload)
        expected_digests.append(hashlib.sha256(payload).hexdigest())
        mp3_paths.append(mp3)

    # Redirect the recovery scan to our temp dir.
    monkeypatch.setattr(srv, "output_dir", tmp_path / "OutputsRoot")
    monkeypatch.setattr(
        srv,
        "_locate_job_output_dir_for_recovery",
        lambda _job_id: job_output_dir,
    )

    job_data = srv._restore_job_from_outputs(job_id)
    assert job_data is not None

    mp3_outputs = [o for o in job_data["outputs"] if o["name"].endswith(".mp3")]
    assert len(mp3_outputs) == 2
    for asset, digest in zip(sorted(mp3_outputs, key=lambda e: e["name"]), expected_digests):
        assert asset["sha256"] == digest

    chapter_progress = job_data["chapterProgress"]
    assert len(chapter_progress) == 2
    for entry, digest in zip(chapter_progress, expected_digests):
        assert entry["sha256"] == digest


def test_restore_asset_entry_skips_sha_for_non_mp3(tmp_path: Path, monkeypatch) -> None:
    """ZIP / log assets must not carry an SHA — clients only verify MP3s."""
    import python_app.server as srv

    job_id = "zip-only-job"
    job_output_dir = tmp_path / "OutputsRoot" / job_id
    job_output_dir.mkdir(parents=True)

    mp3 = job_output_dir / "001 - Ch.mp3"
    mp3.write_bytes(b"mp3 bytes")
    zip_file = job_output_dir / "book.zip"
    zip_file.write_bytes(b"PK\x03\x04 fake zip")
    log_file = job_output_dir / "conversion.log"
    log_file.write_text("log line", encoding="utf-8")

    monkeypatch.setattr(srv, "output_dir", tmp_path / "OutputsRoot")
    monkeypatch.setattr(
        srv,
        "_locate_job_output_dir_for_recovery",
        lambda _job_id: job_output_dir,
    )

    job_data = srv._restore_job_from_outputs(job_id)
    assert job_data is not None

    by_name = {o["name"]: o for o in job_data["outputs"]}
    assert "sha256" in by_name["001 - Ch.mp3"]
    assert "sha256" not in by_name["book.zip"]
    assert "sha256" not in by_name["conversion.log"]
