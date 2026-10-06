"""Local producer observations at segment readiness and atomic audio publication.

Readiness includes cached engine callbacks and ordered callback delivery. It is
not a claim about synthesis completion, manifest commit, or HTTP delivery.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Awaitable, Callable


def atomic_write_manifest(path: Path, payload: dict) -> None:
    """Replace a complete manifest while preserving its previous bytes on failure."""
    descriptor, name = tempfile.mkstemp(prefix=".manifest-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(payload, output, ensure_ascii=False, indent=2)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class SegmentPublication:
    """A readiness observation scoped to one accepted callback."""

    def __init__(self, attempt: StreamAttempt, ready: int):
        self._attempt = attempt
        self._ready = ready

    def publish_audio(self, source: Path, target: Path) -> dict[str, Any]:
        atomic_copy_audio(source, target)
        return {
            "version": 1,
            "attemptId": self._attempt.identifier,
            "segmentReadyElapsedNanoseconds": self._ready,
            "artifactPublishedElapsedNanoseconds": max(self._ready, self._attempt.elapsed()),
        }


def atomic_copy_audio(source: Path, target: Path) -> None:
    """Publish complete bytes with the source cache timestamps preserved."""
    descriptor, name = tempfile.mkstemp(prefix=".segment-", dir=target.parent)
    os.close(descriptor)
    temporary = Path(name)
    try:
        shutil.copy2(source, temporary)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


class StreamAttempt:
    """Fence callbacks after their actual synthesis invocation exits or cancels."""

    def __init__(self, clock: Callable[[], int] = time.monotonic_ns):
        self.identifier = str(uuid.uuid4())
        self._clock = clock
        self._started = clock()
        self._lock = threading.RLock()
        self._active = True
        self.cancelled: Callable[[], bool] = lambda: False

    def elapsed(self) -> int:
        return max(0, self._clock() - self._started)

    def wrap(self, callback: Callable[..., Any]) -> Callable[..., Any]:
        def ready(index: int, path: Path, text: str = "") -> Any:
            with self._lock:
                if not self._active or self.cancelled():
                    return None
                return callback(index, path, text, observation=SegmentPublication(self, self.elapsed()))
        return ready

    def close(self) -> None:
        with self._lock:
            self._active = False


async def observe_synthesis(
    invoke: Callable[[Callable[..., Any]], Awaitable[Any]], callback: Callable[..., Any]
) -> Any:
    """Each invocation gets its own clock and callback lifetime, including retries."""
    attempt = StreamAttempt()
    task = asyncio.current_task()
    if task is not None:
        attempt.cancelled = lambda: task.cancelling() > 0
    try:
        return await invoke(attempt.wrap(callback))
    finally:
        attempt.close()
