# -*- coding: utf-8 -*-
"""Periodic cleanup of stale .cache/<book>/text/*.txt files (v0.3.26)."""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest
from src.cache_manager import CacheManager


def _touch(path: Path, age_days: float, content: bytes = b"x") -> None:
    path.write_bytes(content)
    target = time.time() - age_days * 86400
    os.utime(path, (target, target))


@pytest.fixture
def cache_with_text_dirs(tmp_path):
    cache_root = tmp_path / "cache"
    cache_root.mkdir()
    book_a = cache_root / "Book_A" / "text"
    book_a.mkdir(parents=True)
    book_b = cache_root / "Book_B" / "text"
    book_b.mkdir(parents=True)
    # Protected: must never be touched.
    protected = cache_root / "telemetry"
    protected.mkdir()
    (protected / "data.json").write_text("{}", encoding="utf-8")
    return cache_root, book_a, book_b, protected


def test_cleanup_drops_old_text_files(cache_with_text_dirs):
    cache_root, book_a, book_b, protected = cache_with_text_dirs
    old = book_a / "ch1-pre-tts.txt"
    fresh = book_a / "ch2-pre-tts.txt"
    _touch(old, age_days=45)
    _touch(fresh, age_days=2)
    # Reset the once-per-process gate.
    CacheManager._TEXT_CACHE_CLEANED = False
    cm = CacheManager(cache_dir=cache_root)
    removed = cm.cleanup_old_text_files(max_age_days=30)
    assert removed == 1
    assert not old.exists()
    assert fresh.exists()


def test_cleanup_skips_protected_dirs(cache_with_text_dirs):
    cache_root, _, _, protected = cache_with_text_dirs
    # Plant an old file inside a protected dir's text/ — but the protected
    # check fires BEFORE the text/ probe so it should be untouched even
    # if a malformed structure exists.
    text_dir_in_protected = protected / "text"
    text_dir_in_protected.mkdir()
    bait = text_dir_in_protected / "old.txt"
    _touch(bait, age_days=100)
    CacheManager._TEXT_CACHE_CLEANED = False
    cm = CacheManager(cache_dir=cache_root)
    cm.cleanup_old_text_files(max_age_days=30)
    assert bait.exists()


def test_cleanup_idempotent_within_process(cache_with_text_dirs):
    cache_root, book_a, _, _ = cache_with_text_dirs
    _touch(book_a / "ch1-pre-tts.txt", age_days=45)
    CacheManager._TEXT_CACHE_CLEANED = False
    cm = CacheManager(cache_dir=cache_root)
    first = cm.cleanup_old_text_files(max_age_days=30)
    assert first == 1
    # Plant another stale file; second call must short-circuit.
    _touch(book_a / "ch2-pre-tts.txt", age_days=60)
    second = cm.cleanup_old_text_files(max_age_days=30)
    assert second == 0
    assert (book_a / "ch2-pre-tts.txt").exists()


def test_cleanup_keeps_non_txt_files(cache_with_text_dirs):
    cache_root, book_a, _, _ = cache_with_text_dirs
    metadata = book_a / "metadata.json"
    _touch(metadata, age_days=100)  # old, but not .txt
    CacheManager._TEXT_CACHE_CLEANED = False
    cm = CacheManager(cache_dir=cache_root)
    cm.cleanup_old_text_files(max_age_days=30)
    assert metadata.exists()
