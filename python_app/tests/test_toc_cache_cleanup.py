# -*- coding: utf-8 -*-
"""Periodic cleanup of stale .cache/_toc/ entries (v0.3.25)."""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest
import src.ebook_reader as ebook_reader


@pytest.fixture
def isolated_toc_dir(tmp_path, monkeypatch):
    """Redirect CACHE_DIR so the test never touches the real cache."""
    fake_cache = tmp_path / "cache"
    fake_cache.mkdir()
    monkeypatch.setattr("src.paths.CACHE_DIR", fake_cache, raising=False)
    # Reset the once-per-process gate so the cleanup runs in the test.
    monkeypatch.setattr(ebook_reader, "_TOC_DISK_CACHE_CLEANED", False, raising=False)
    toc_dir = fake_cache / "_toc"
    toc_dir.mkdir()
    return toc_dir


def _touch(path: Path, age_days: float) -> None:
    path.write_text("{}", encoding="utf-8")
    target = time.time() - age_days * 86400
    os.utime(path, (target, target))


def test_cleanup_drops_old_entries_keeps_fresh(isolated_toc_dir):
    old = isolated_toc_dir / "old.json"
    fresh = isolated_toc_dir / "fresh.json"
    _touch(old, age_days=45)
    _touch(fresh, age_days=2)
    removed = ebook_reader._toc_disk_cache_cleanup(max_age_days=30)
    assert removed == 1
    assert not old.exists()
    assert fresh.exists()


def test_cleanup_is_idempotent_within_process(isolated_toc_dir, monkeypatch):
    old = isolated_toc_dir / "old.json"
    _touch(old, age_days=45)
    first = ebook_reader._toc_disk_cache_cleanup(max_age_days=30)
    assert first == 1
    # Second call within the same process should be a no-op even if
    # another stale entry shows up.
    older = isolated_toc_dir / "older.json"
    _touch(older, age_days=60)
    second = ebook_reader._toc_disk_cache_cleanup(max_age_days=30)
    assert second == 0
    assert older.exists()  # not swept this run


def test_cleanup_handles_missing_dir(tmp_path, monkeypatch):
    fake_cache = tmp_path / "missing"
    monkeypatch.setattr("src.paths.CACHE_DIR", fake_cache, raising=False)
    monkeypatch.setattr(ebook_reader, "_TOC_DISK_CACHE_CLEANED", False, raising=False)
    assert ebook_reader._toc_disk_cache_cleanup() == 0
