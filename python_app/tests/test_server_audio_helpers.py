# -*- coding: utf-8 -*-
"""Unit tests for compute_mp3_sha256 in src/_server_audio_helpers.py.

Covers determinism, the (path, mtime, size) cache key, and LRU eviction.
SHA-256 of chapter MP3s is consumed by the iOS client to verify downloads
so behavioural regressions here would silently break post-download checks.
"""

from __future__ import annotations

import hashlib
import os
import time
from pathlib import Path

import pytest
from src import _server_audio_helpers as helpers


@pytest.fixture(autouse=True)
def _clear_sha_cache():
    """Each test starts with an empty LRU cache."""
    helpers._reset_sha256_cache()
    yield
    helpers._reset_sha256_cache()


def _write(path: Path, content: bytes) -> None:
    path.write_bytes(content)


def test_sha256_matches_hashlib_reference(tmp_path: Path) -> None:
    audio = tmp_path / "001 - Chapter.mp3"
    payload = b"ID3" + b"\x00" * 32 + b"audio bytes here" * 64
    _write(audio, payload)
    expected = hashlib.sha256(payload).hexdigest()

    assert helpers.compute_mp3_sha256(audio) == expected


def test_sha256_deterministic_across_calls(tmp_path: Path) -> None:
    audio = tmp_path / "chapter.mp3"
    _write(audio, b"some deterministic bytes")
    first = helpers.compute_mp3_sha256(audio)
    second = helpers.compute_mp3_sha256(audio)
    assert first == second


def test_sha256_cache_hit_skips_disk_read(tmp_path: Path, monkeypatch) -> None:
    audio = tmp_path / "ch.mp3"
    _write(audio, b"cacheable")
    helpers.compute_mp3_sha256(audio)

    # Once cached, subsequent calls must not re-open the file.
    real_open = Path.open
    open_calls = {"count": 0}

    def _spy_open(self, *args, **kwargs):  # type: ignore[no-untyped-def]
        open_calls["count"] += 1
        return real_open(self, *args, **kwargs)

    monkeypatch.setattr(Path, "open", _spy_open)
    helpers.compute_mp3_sha256(audio)
    assert open_calls["count"] == 0


def test_sha256_cache_invalidates_on_mtime_change(tmp_path: Path) -> None:
    audio = tmp_path / "ch.mp3"
    _write(audio, b"initial bytes")
    first = helpers.compute_mp3_sha256(audio)

    # Wait a tick so mtime_ns guarantees a different value, rewrite with
    # identical-length payload but different content.
    time.sleep(0.01)
    _write(audio, b"changed bytes")
    # Force mtime to advance even on filesystems with coarse resolution.
    future = time.time() + 1.0
    os.utime(audio, (future, future))

    second = helpers.compute_mp3_sha256(audio)
    assert first != second


def test_sha256_cache_invalidates_on_size_change(tmp_path: Path) -> None:
    audio = tmp_path / "ch.mp3"
    _write(audio, b"short")
    first = helpers.compute_mp3_sha256(audio)

    _write(audio, b"this payload is noticeably longer than before")
    second = helpers.compute_mp3_sha256(audio)
    assert first != second


def test_sha256_lru_evicts_oldest(tmp_path: Path) -> None:
    original_max = helpers._SHA256_CACHE_MAX
    helpers._SHA256_CACHE_MAX = 3
    try:
        paths = []
        for i in range(5):
            p = tmp_path / f"{i:03d}.mp3"
            _write(p, f"payload-{i}".encode())
            helpers.compute_mp3_sha256(p)
            paths.append(p)
        # Cache should be capped at 3 — earliest two entries evicted.
        assert len(helpers._sha256_cache) == 3
    finally:
        helpers._SHA256_CACHE_MAX = original_max


def test_sha256_large_file_streamed(tmp_path: Path) -> None:
    """Hashing must work on files larger than the 8 KB read chunk."""
    audio = tmp_path / "big.mp3"
    payload = b"X" * (8192 * 4 + 17)
    _write(audio, payload)
    assert helpers.compute_mp3_sha256(audio) == hashlib.sha256(payload).hexdigest()


def test_sha256_missing_file_raises(tmp_path: Path) -> None:
    missing = tmp_path / "ghost.mp3"
    with pytest.raises(FileNotFoundError):
        helpers.compute_mp3_sha256(missing)
