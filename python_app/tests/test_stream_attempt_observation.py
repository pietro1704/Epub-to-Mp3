import asyncio
import json
import os
from uuid import UUID

import pytest
from src.stream_attempt_observation import StreamAttempt, atomic_write_manifest, observe_synthesis


def test_ready_and_atomic_artifact_publication_have_distinct_monotonic_boundaries(tmp_path):
    clock = iter([100, 110, 150])
    attempt = StreamAttempt(clock=lambda: next(clock))
    source, target = tmp_path / "source", tmp_path / "target"
    source.write_bytes(b"unchanged audio")
    os.utime(source, ns=(1_000_000_000, 2_000_000_000))
    source.chmod(0o640)
    captured = []
    callback = attempt.wrap(lambda index, path, text, *, observation:
                            captured.append(observation.publish_audio(path, target)))
    callback(2, source, "Private words")
    assert target.read_bytes() == source.read_bytes()
    assert target.stat().st_mtime_ns == source.stat().st_mtime_ns
    assert target.stat().st_mode & 0o777 == source.stat().st_mode & 0o777
    assert captured == [{"version": 1, "attemptId": attempt.identifier,
                         "segmentReadyElapsedNanoseconds": 10,
                         "artifactPublishedElapsedNanoseconds": 50}]
    assert str(UUID(attempt.identifier)) == attempt.identifier
    assert "Private" not in json.dumps(captured)


@pytest.mark.asyncio
async def test_retry_uses_new_attempt_and_old_callback_cannot_publish(tmp_path):
    source = tmp_path / "source"
    target = tmp_path / "audio"
    published = []
    callbacks = []

    def consumer(index, path, text, *, observation):
        published.append(observation.publish_audio(path, target))

    async def failed(callback):
        callbacks.append(callback)
        source.write_bytes(b"first")
        callback(0, source)
        raise RuntimeError("retry")

    with pytest.raises(RuntimeError):
        await observe_synthesis(failed, consumer)

    async def retry(callback):
        source.write_bytes(b"second")
        callback(0, source)
        source.write_bytes(b"late stale data")
        callbacks[0](0, source)
        return target

    assert await observe_synthesis(retry, consumer) == target
    assert target.read_bytes() == b"second"
    assert len(published) == 2
    assert published[0]["attemptId"] != published[1]["attemptId"]


@pytest.mark.asyncio
async def test_cancelled_engine_cannot_publish_even_if_it_swallows_cancellation(tmp_path):
    entered = asyncio.Event()
    source = tmp_path / "source"
    source.write_bytes(b"audio")
    calls = []

    async def engine(callback):
        entered.set()
        try:
            await asyncio.Future()
        except asyncio.CancelledError:
            callback(0, source)

    task = asyncio.create_task(observe_synthesis(engine, lambda *args, **kwargs: calls.append(args)))
    await entered.wait()
    task.cancel()
    await task
    assert calls == []


def test_failed_audio_replace_preserves_previous_bytes_and_emits_no_observation(tmp_path, monkeypatch):
    source, target = tmp_path / "source", tmp_path / "audio"
    source.write_bytes(b"new")
    target.write_bytes(b"old")
    attempt = StreamAttempt()
    captured = []

    def fail(*args):
        raise OSError("storage failure")

    monkeypatch.setattr("src.stream_attempt_observation.os.replace", fail)
    callback = attempt.wrap(lambda index, path, text, *, observation:
                            captured.append(observation.publish_audio(path, target)))
    with pytest.raises(OSError):
        callback(0, source)
    assert target.read_bytes() == b"old"
    assert captured == []
    assert sorted(p.name for p in tmp_path.iterdir()) == ["audio", "source"]


def test_atomic_manifest_failure_preserves_previous_document(tmp_path, monkeypatch):
    manifest = tmp_path / "manifest.json"
    atomic_write_manifest(manifest, {"chunks": [0]})
    previous = manifest.read_bytes()

    def fail(*args):
        raise OSError("storage failure")

    monkeypatch.setattr("src.stream_attempt_observation.os.replace", fail)
    with pytest.raises(OSError):
        atomic_write_manifest(manifest, {"chunks": [1]})
    assert manifest.read_bytes() == previous
    assert list(tmp_path.iterdir()) == [manifest]


def test_cached_same_path_audio_can_be_atomically_republished(tmp_path):
    target = tmp_path / "cached.mp3"
    target.write_bytes(b"cached audio")
    observations = []
    callback = StreamAttempt().wrap(lambda index, path, text, *, observation:
                                    observations.append(observation.publish_audio(path, path)))
    callback(0, target)
    assert target.read_bytes() == b"cached audio"
    assert len(observations) == 1
