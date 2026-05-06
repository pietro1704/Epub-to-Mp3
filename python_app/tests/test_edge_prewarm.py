# -*- coding: utf-8 -*-
"""Tests for the Edge-TTS prewarm helper introduced in v0.3.24."""

from __future__ import annotations

import asyncio
import types
from unittest.mock import patch

import pytest
from src.tts import edge_engine


class _FakeStream:
    def __init__(self, chunks):
        self._chunks = chunks

    def __aiter__(self):
        async def _gen():
            for c in self._chunks:
                yield c

        return _gen()


class _FakeCommunicate:
    instances: list = []

    def __init__(self, text, voice):
        self.text = text
        self.voice = voice
        _FakeCommunicate.instances.append(self)

    def stream(self):
        return _FakeStream([{"type": "audio", "data": b"\x00" * 16}])


@pytest.fixture(autouse=True)
def _reset_prewarm_state():
    edge_engine._edge_prewarm_done = False
    edge_engine._edge_prewarm_lock = None
    _FakeCommunicate.instances = []
    yield
    edge_engine._edge_prewarm_done = False
    edge_engine._edge_prewarm_lock = None


def _fake_module(communicate_cls):
    """Build a real (non-Mock) module-like object so prewarm_edge does not
    trigger its ``isinstance(edge_tts, Mock)`` re-import branch."""
    module = types.SimpleNamespace()
    module.Communicate = communicate_cls
    return module


def test_prewarm_edge_drains_stream_and_marks_done():
    with patch.object(edge_engine, "edge_tts", _fake_module(_FakeCommunicate)):
        ok = asyncio.run(edge_engine.prewarm_edge("en-US-AriaNeural"))
    assert ok is True
    assert edge_engine._edge_prewarm_done is True
    assert len(_FakeCommunicate.instances) == 1
    assert _FakeCommunicate.instances[0].voice == "en-US-AriaNeural"


def test_prewarm_edge_is_idempotent():
    with patch.object(edge_engine, "edge_tts", _fake_module(_FakeCommunicate)):
        asyncio.run(edge_engine.prewarm_edge("en-US-AriaNeural"))
        asyncio.run(edge_engine.prewarm_edge("en-US-AriaNeural"))
    assert len(_FakeCommunicate.instances) == 1


def test_prewarm_edge_swallows_failures():
    class _BoomCommunicate:
        def __init__(self, text, voice):
            raise RuntimeError("network down")

    with patch.object(edge_engine, "edge_tts", _fake_module(_BoomCommunicate)):
        ok = asyncio.run(edge_engine.prewarm_edge("en-US-AriaNeural"))
    assert ok is False
    # Failure must not flip the done flag — a future call should retry.
    assert edge_engine._edge_prewarm_done is False


def test_prewarm_edge_force_reruns():
    with patch.object(edge_engine, "edge_tts", _fake_module(_FakeCommunicate)):
        asyncio.run(edge_engine.prewarm_edge("voice-A"))
        asyncio.run(edge_engine.prewarm_edge("voice-B", force=True))
    assert len(_FakeCommunicate.instances) == 2
    assert _FakeCommunicate.instances[1].voice == "voice-B"
