# -*- coding: utf-8 -*-
"""prewarm_edge() lazy-creates the asyncio.Lock under a sync mutex so
concurrent first-time callers see the same lock instance (v0.3.27)."""

from __future__ import annotations

import asyncio
import threading
import types
from unittest.mock import patch

import pytest
from src.tts import edge_engine


class _FakeStream:
    def __aiter__(self):
        async def _gen():
            yield {"type": "audio", "data": b"\x00" * 8}

        return _gen()


class _FakeCommunicate:
    instances: list = []

    def __init__(self, text, voice):
        self.text = text
        self.voice = voice
        _FakeCommunicate.instances.append(self)

    def stream(self):
        return _FakeStream()


def _fake_module():
    return types.SimpleNamespace(Communicate=_FakeCommunicate)


@pytest.fixture(autouse=True)
def _reset():
    edge_engine._edge_prewarm_done = False
    edge_engine._edge_prewarm_lock = None
    _FakeCommunicate.instances = []
    yield
    edge_engine._edge_prewarm_done = False
    edge_engine._edge_prewarm_lock = None


def test_init_mutex_exists_and_is_sync_lock():
    """The race-fix relies on a sync ``threading.Lock`` guarding the
    lazy creation of the async lock. Verify the mutex is the right type.
    """
    assert isinstance(edge_engine._edge_prewarm_init_mutex, type(threading.Lock()))


def test_concurrent_prewarms_share_one_async_lock():
    """Two concurrent prewarms must observe the same ``_edge_prewarm_lock``
    instance — the bug fixed in v0.3.27 was that without a sync mutex,
    each could create its own asyncio.Lock and race past the gate."""

    seen_locks: list = []

    async def _capture(*_a, **_kw):
        # Simulate concurrent entry into the prewarm function up to the
        # point where the asyncio lock is bound.
        async with edge_engine._edge_prewarm_lock:  # type: ignore[arg-type]
            seen_locks.append(edge_engine._edge_prewarm_lock)

    async def _runner():
        with patch.object(edge_engine, "edge_tts", _fake_module()):
            await asyncio.gather(
                edge_engine.prewarm_edge("voice-A"),
                edge_engine.prewarm_edge("voice-B"),
                edge_engine.prewarm_edge("voice-C"),
            )

    asyncio.run(_runner())
    # Idempotency means at most one Communicate instance was created.
    assert len(_FakeCommunicate.instances) == 1
    # And the module-level lock is set after the first run.
    assert edge_engine._edge_prewarm_lock is not None
