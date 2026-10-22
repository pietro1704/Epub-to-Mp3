"""Checkpoint storage honors host path overrides and preserves chapter identities."""

import json
from pathlib import Path
from unittest.mock import Mock

import pytest
from src._retry_mixin import _RetryMixin


class _Host(_RetryMixin):
    verbose = False

    def __init__(self, path):
        self.path = path

    def _failure_checkpoint_path(self, output_dir):
        return self.path


def test_checkpoint_roundtrip_keeps_decimal_labels_and_partial_manifest(tmp_path):
    path = tmp_path / "overridden-checkpoint.json"
    host = _Host(path)
    chapter = tmp_path / "chunks" / "chapter_7.13"
    chapter.mkdir(parents=True)
    (chapter / "chunk_001.mp3").write_bytes(b"audio")
    (chapter / "manifest.json").write_text(json.dumps([{"index": 1}]))
    host._save_failure_checkpoint(tmp_path, failed_chapters=["7.13", "7.13", "2"], edge_blocked_chapters=["7.13"])
    restored = host._load_failure_checkpoint(tmp_path)
    assert restored["failed_chapters"] == ["2", "7.13"]
    assert restored["edge_blocked_chapters"] == ["7.13"]
    assert restored["resume_chunks"]["chapter_7.13"] == {"chunk_files": 1, "manifest_entries": 1}
    host._clear_failure_checkpoint(tmp_path)
    assert not path.exists()


def test_invalid_checkpoint_is_best_effort_but_cancellation_propagates(tmp_path, monkeypatch):
    path = tmp_path / "checkpoint.json"
    path.write_text("not-json")
    host = _Host(path)
    assert host._load_failure_checkpoint(tmp_path) == {}
    monkeypatch.setattr(Path, "read_text", Mock(side_effect=KeyboardInterrupt))
    with pytest.raises(KeyboardInterrupt):
        host._load_failure_checkpoint(tmp_path)
