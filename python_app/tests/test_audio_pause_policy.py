"""Offline policy regressions; no provider, ffmpeg or audio generation is invoked."""

from __future__ import annotations

import asyncio
import runpy
import socket
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest


@pytest.fixture
def audio_module(monkeypatch):
    monkeypatch.delenv("RUN_LIVE_EDGE_AUDIO_TESTS", raising=False)
    monkeypatch.delenv("SKIP_NETWORK_TESTS", raising=False)
    with patch.object(socket, "create_connection", side_effect=AssertionError("unexpected network")):
        return runpy.run_path(str(Path(__file__).with_name("test_audio_pause_integration.py")))


def test_default_collection_never_probes_a_provider(audio_module):
    assert audio_module["TestEdgeOutputAudioProperties"].__unittest_skip__ is True
    assert audio_module["TestEdgeFingerprintIsConsistent"].__unittest_skip__ is True
    assert audio_module["_live_edge_enabled"]() is False


def test_live_policy_requires_literal_opt_in_and_respects_network_denial(audio_module, monkeypatch):
    for value in ("", "0", "true", "yes"):
        monkeypatch.setenv("RUN_LIVE_EDGE_AUDIO_TESTS", value)
        assert audio_module["_live_edge_enabled"]() is False
    monkeypatch.setenv("RUN_LIVE_EDGE_AUDIO_TESTS", "1")
    assert audio_module["_live_edge_enabled"]() is True
    monkeypatch.setenv("SKIP_NETWORK_TESTS", "1")
    assert audio_module["_live_edge_enabled"]() is False


def test_disabled_synthesis_never_imports_or_calls_the_provider(audio_module, tmp_path):
    with patch.dict(sys.modules, {"edge_tts": None}):
        with pytest.raises(RuntimeError, match="requires RUN_LIVE_EDGE_AUDIO_TESTS=1"):
            asyncio.run(audio_module["_synth_edge"]("fixture", tmp_path / "out.mp3"))


@pytest.mark.parametrize("failure", [RuntimeError("HTTP 403"), asyncio.TimeoutError()])
def test_explicit_provider_failures_remain_fatal(audio_module, monkeypatch, tmp_path, failure):
    monkeypatch.setenv("RUN_LIVE_EDGE_AUDIO_TESTS", "1")
    save = AsyncMock(side_effect=failure)
    provider = SimpleNamespace(Communicate=lambda *_args: SimpleNamespace(save=save))
    with patch.dict(sys.modules, {"edge_tts": provider}):
        with pytest.raises(type(failure)) as raised:
            asyncio.run(audio_module["_synth_edge"]("fixture", tmp_path / "out.mp3"))
    assert raised.value is failure
    save.assert_awaited_once()


def test_explicit_empty_provider_payload_fails_instead_of_skipping(audio_module, monkeypatch, tmp_path):
    monkeypatch.setenv("RUN_LIVE_EDGE_AUDIO_TESTS", "1")
    provider = SimpleNamespace(Communicate=lambda *_args: SimpleNamespace(save=AsyncMock()))
    with patch.dict(sys.modules, {"edge_tts": provider}):
        with pytest.raises(AssertionError, match="empty or incomplete"):
            asyncio.run(audio_module["_synth_edge"]("fixture", tmp_path / "out.mp3"))
