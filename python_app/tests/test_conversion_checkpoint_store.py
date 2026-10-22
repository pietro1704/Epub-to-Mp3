"""Checkpoint API preserves book/config identity across the cache-manager seam."""

import builtins
from unittest.mock import Mock

import pytest
from src.cache_manager import CacheManager, ConversionCheckpoint
from src.conversion_checkpoint_store import ConversionCheckpoint as StoredCheckpoint


def _save(manager, book, root):
    return manager.save_checkpoint(
        book, "Fixture", root, root, 2, [1], 2, {"engine": "piper"}
    )


def test_checkpoint_roundtrip_keeps_model_book_and_engine_identity(tmp_path):
    manager = CacheManager(tmp_path / "cache")
    book = tmp_path / "book.epub"
    (tmp_path / "001 - First.mp3").write_bytes(b"audio")
    assert _save(manager, book, tmp_path)
    checkpoint = manager.load_checkpoint(book)
    assert ConversionCheckpoint is StoredCheckpoint
    assert isinstance(checkpoint, ConversionCheckpoint)
    assert checkpoint.book_path == str(book.absolute())
    assert checkpoint.completed_chapters == [1]
    assert manager.validate_checkpoint(checkpoint, tmp_path, {"engine": "piper"})
    assert not manager.validate_checkpoint(checkpoint, tmp_path, {"engine": "edge"})
    assert manager.get_resume_info(checkpoint)["progress_percentage"] == 50.0
    assert manager.clear_checkpoint(book)
    assert not manager.has_checkpoint(book)


def test_same_filename_in_different_directories_has_distinct_checkpoint(tmp_path):
    manager = CacheManager(tmp_path / "cache")
    first = tmp_path / "first" / "book.epub"
    second = tmp_path / "second" / "book.epub"
    assert _save(manager, first, tmp_path)
    assert _save(manager, second, tmp_path)
    assert manager._get_checkpoint_path(first) != manager._get_checkpoint_path(second)
    assert manager.load_checkpoint(first).book_path != manager.load_checkpoint(second).book_path


def test_malformed_checkpoint_and_write_failure_remain_best_effort(tmp_path, monkeypatch):
    manager = CacheManager(tmp_path / "cache")
    book = tmp_path / "book.epub"
    manager._get_checkpoint_path(book).write_text("not-json")
    assert manager.load_checkpoint(book) is None
    with monkeypatch.context() as context:
        context.setattr(builtins, "open", Mock(side_effect=OSError("write failed")))
        assert not _save(manager, book, tmp_path)


def test_checkpoint_cancellation_propagates_without_deleting_existing_state(tmp_path, monkeypatch):
    manager = CacheManager(tmp_path / "cache")
    book = tmp_path / "book.epub"
    assert _save(manager, book, tmp_path)
    path = manager._get_checkpoint_path(book)
    original = path.read_bytes()
    with monkeypatch.context() as context:
        context.setattr(builtins, "open", Mock(side_effect=KeyboardInterrupt))
        with pytest.raises(KeyboardInterrupt):
            manager.load_checkpoint(book)
    assert path.read_bytes() == original
