"""Identity boundary regressions for the legacy server's extracted audio helpers."""

import hashlib
from pathlib import Path

import pytest
from src import _server_audio_helpers as facade
from src.audio_identity import AudioDuplicateTracker, Mp3DigestCache
from src.chapter_utils import MIN_DUPLICATE_CHARS


def test_facade_owns_same_duplicate_tracker_and_cache_state(tmp_path, monkeypatch):
    audio = tmp_path / "chapter.mp3"
    audio.write_bytes(b"payload")
    facade._reset_sha256_cache()
    monkeypatch.setattr(facade, "_SHA256_CACHE_MAX", 1)
    try:
        assert facade.AudioDuplicateTracker is AudioDuplicateTracker
        assert facade._sha256_cache is facade._sha256_digests.entries
        assert facade.compute_mp3_sha256(audio) == hashlib.sha256(b"payload").hexdigest()
        other = tmp_path / "other.mp3"
        other.write_bytes(b"different")
        facade.compute_mp3_sha256(other)
        assert len(facade._sha256_cache) == 1
    finally:
        facade._reset_sha256_cache()


def test_digest_read_failure_and_cancellation_do_not_cache_partial_results(tmp_path, monkeypatch):
    audio = tmp_path / "chapter.mp3"
    audio.write_bytes(b"payload")
    cache = Mp3DigestCache()
    for exception in (OSError("read failed"), KeyboardInterrupt()):
        with monkeypatch.context() as context:
            def fail_open(*args, **kwargs):
                raise exception

            context.setattr(Path, "open", fail_open)
            with pytest.raises(type(exception)):
                cache.compute(audio, 3)
        assert cache.entries == {}
    assert cache.compute(audio, 3) == hashlib.sha256(b"payload").hexdigest()


@pytest.mark.asyncio
async def test_same_audio_and_same_text_preserve_identity_without_false_duplicate(tmp_path):
    tracker = AudioDuplicateTracker()
    audio = tmp_path / "chapter.mp3"
    audio.write_bytes(b"same audio")
    text = "a" * (MIN_DUPLICATE_CHARS + 10)
    assert await tracker.check_duplicate(audio, text, 1, "First") is None
    assert await tracker.check_duplicate(audio, text, 2, "Second") is None
    duplicate = await tracker.check_duplicate(audio, "b" * len(text), 3, "Third")
    assert duplicate["index"] == 2
    assert duplicate["name"] == "Second"


@pytest.mark.asyncio
async def test_duplicate_hash_failure_leaves_tracker_reusable(tmp_path):
    tracker = AudioDuplicateTracker()
    missing = tmp_path / "missing.mp3"
    text = "a" * (MIN_DUPLICATE_CHARS + 10)
    with pytest.raises(FileNotFoundError):
        await tracker.check_duplicate(missing, text, 1, "Missing")
    assert tracker._hashes == {}
    missing.write_bytes(b"recovered")
    assert await tracker.check_duplicate(missing, text, 1, "Recovered") is None
