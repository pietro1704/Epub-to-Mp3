# -*- coding: utf-8 -*-
"""Piper prewarm helper tests (v0.3.24+)."""

from __future__ import annotations

from unittest.mock import patch

import pytest
from src.tts import piper_engine


@pytest.fixture(autouse=True)
def _reset_piper_prewarm():
    piper_engine._piper_prewarm_done = False
    yield
    piper_engine._piper_prewarm_done = False


def test_prewarm_piper_returns_false_when_binary_missing():
    with patch.object(piper_engine, "_find_piper_binary", return_value="piper"):
        assert piper_engine.prewarm_piper("pt") is False


def test_prewarm_piper_succeeds_when_binary_resolved():
    with patch.object(piper_engine, "_find_piper_binary", return_value="/opt/piper/piper"):
        # No language → skips model probe, but binary lookup is enough.
        assert piper_engine.prewarm_piper(None) is True
    assert piper_engine._piper_prewarm_done is True


def test_prewarm_piper_is_idempotent():
    with patch.object(piper_engine, "_find_piper_binary", return_value="/opt/piper/piper") as f:
        piper_engine.prewarm_piper("pt")
        piper_engine.prewarm_piper("pt")
    # Second call short-circuits — binary lookup happens once.
    assert f.call_count == 1


def test_prewarm_piper_swallows_exceptions():
    with patch.object(piper_engine, "_find_piper_binary", side_effect=RuntimeError("boom")):
        assert piper_engine.prewarm_piper("pt") is False
