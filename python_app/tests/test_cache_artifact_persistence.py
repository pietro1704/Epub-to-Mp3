"""Cache I/O extraction preserves model/chapter identity and resumable plans."""

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from src import cache_artifact_persistence as persistence
from src._cache_mixin import _CacheMixin


class _Host(_CacheMixin):
    verbose = False

    def _chapter_index_label(self, chapter, index):
        return str(chapter.index)


def _config(voice="alpha"):
    return SimpleNamespace(
        engine="piper", voice=voice, model_path=None,
        edge_chunk_chars=4000, edge_max_segment_seconds=75,
    )


def test_cached_audio_and_text_keep_chapter_label_hash_and_model_bucket(tmp_path):
    host = _Host()
    cache = tmp_path / "cache"
    audio = tmp_path / "source.mp3"
    audio.write_bytes(b"audio" * 400)
    chapter = SimpleNamespace(name="Chapter", index="7.13", text="raw text")
    host._cache_text(cache, chapter, 7, "spoken text")
    host._cache_audio(cache, audio, chapter, 7, _config())
    found = host._find_cached_audio_path(cache, _config(), chapter.name, 7)
    assert found is not None
    assert found.read_bytes() == audio.read_bytes()
    assert host._find_cached_audio_path(cache, _config("beta"), chapter.name, 7) is None
    entry = host._load_cache_index(cache)["7.13"]
    assert entry["path"] == str(found)
    assert entry["pre_tts_hash"] == host._hash_text("spoken text")


def test_segment_plan_rejects_changed_chunk_identity_without_losing_original(tmp_path):
    host = _Host()
    host._save_segment_plan(tmp_path, 7, ["first", "second"], _config())
    assert host._load_segment_plan(tmp_path, 7, chunk_chars=6000) is None
    assert host._load_segment_plan(tmp_path, 7, chunk_chars=4000) == ["first", "second"]


def test_cache_copy_failure_remains_best_effort_and_preserves_source(tmp_path, monkeypatch):
    host = _Host()
    source = tmp_path / "source.mp3"
    source.write_bytes(b"original")
    monkeypatch.setattr(persistence.shutil, "copy2", Mock(side_effect=OSError("copy failed")))
    host._cache_audio(tmp_path / "cache", source, SimpleNamespace(name="Chapter", index="1"), 1, _config())
    assert source.read_bytes() == b"original"
    assert host._load_cache_index(tmp_path / "cache") == {}


def test_segment_plan_cancellation_propagates_and_keeps_saved_plan(tmp_path, monkeypatch):
    host = _Host()
    host._save_segment_plan(tmp_path, 1, ["saved"], _config())
    path = host._segment_plan_path(tmp_path, 1)
    original = path.read_bytes()
    with monkeypatch.context() as context:
        context.setattr(Path, "read_text", Mock(side_effect=KeyboardInterrupt))
        with pytest.raises(KeyboardInterrupt):
            host._load_segment_plan(tmp_path, 1)
    assert path.read_bytes() == original
