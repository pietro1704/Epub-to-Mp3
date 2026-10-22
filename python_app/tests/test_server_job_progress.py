"""Public progress helpers preserve counters, identity and optional digest failure."""

from types import SimpleNamespace
from unittest.mock import Mock

import pytest
import python_app
from src import _server_audio_helpers as audio
from src import _server_conversion_helpers as facade
from src import server_job_progress as progress


def _job():
    return {
        "jobId": "identity-test", "totalChars": 100, "processedChars": 0,
        "_chapterCharTotals": {9: 100}, "_chapterCharProcessed": {},
        "chapterProgress": [{"index": 9, "status": "processing"}, {"index": 2}],
    }


@pytest.fixture
def broadcaster(monkeypatch):
    callback = Mock()
    monkeypatch.setattr(
        python_app, "server", SimpleNamespace(_schedule_job_broadcast=callback), raising=False
    )
    monkeypatch.setattr(progress.time, "time", lambda: 1000.0)
    return callback


def test_progress_facade_preserves_identity_monotonicity_and_completion(broadcaster):
    assert facade.advance_chapter_progress is progress.advance_chapter_progress
    job = _job()
    target = job["chapterProgress"][0]
    facade.advance_chapter_progress(job, 9, "a" * 40, 2)
    assert target["charsProcessed"] == 40
    assert target["progressRatio"] == 0.4
    assert job["progressPercent"] == 40.0
    facade.update_estimated_chapter_progress(job, 9, 0.20, 2)
    assert job["processedChars"] == 40
    facade.complete_chapter_progress(job, 9, 2, broadcast=False)
    assert job["processedChars"] == 100
    assert target["progressRatio"] == 1.0
    assert "charsProcessed" not in job["chapterProgress"][1]
    broadcaster.assert_called_once_with("identity-test", job)


def test_estimated_progress_leaves_final_three_percent_for_completion(broadcaster):
    job = _job()
    facade.update_estimated_chapter_progress(job, 9, 5.0, 2)
    assert job["processedChars"] == 97
    facade.complete_chapter_progress(job, 9, 2, broadcast=False)
    assert job["processedChars"] == 100


def test_digest_failure_does_not_block_completed_progress(tmp_path, monkeypatch, broadcaster):
    job = _job()
    output = tmp_path / "chapter.mp3"
    output.write_bytes(b"audio")
    monkeypatch.setattr(audio, "compute_mp3_sha256", Mock(side_effect=OSError("read failed")))
    facade.complete_chapter_progress(job, 9, 2, output_path=output)
    assert job["processedChars"] == 100
    assert job["progressPercent"] == 100.0
    assert "sha256" not in job["chapterProgress"][0]
    broadcaster.assert_called_once_with("identity-test", job)


def test_digest_cancellation_propagates_without_broadcast(tmp_path, monkeypatch, broadcaster):
    job = _job()
    output = tmp_path / "chapter.mp3"
    output.write_bytes(b"audio")
    monkeypatch.setattr(audio, "compute_mp3_sha256", Mock(side_effect=KeyboardInterrupt))
    with pytest.raises(KeyboardInterrupt):
        facade.complete_chapter_progress(job, 9, 2, output_path=output)
    assert "sha256" not in job["chapterProgress"][0]
    broadcaster.assert_not_called()
