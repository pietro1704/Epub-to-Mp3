"""Tests for the pluggable Piper TTS transport seam.

These tests prove:
  * ``_piper_transport.synthesize_chunk`` raises a clear, actionable
    ``RuntimeError`` until a transport is installed (the stub-only
    state slice 1b ships in).
  * ``set_transport(fn)`` installs ``fn`` so subsequent calls route
    through it; the bytes returned by the transport pass through
    verbatim.
  * ``reset_transport`` and ``set_transport(None)`` both clear the
    installed transport (mirrors ``_edge_transport`` semantics).
  * Installing twice replaces the previous transport (last-writer-
    wins, deterministic for Swift install + tests).

No network, no real Piper. The stub seam means the iOS Swift bridge
swaps in a real callback at app boot -- here we swap in fake
callbacks instead.
"""

from __future__ import annotations

import pytest

from python_app.src.tts import _piper_transport


@pytest.fixture(autouse=True)
def _reset_piper_transport():
    """Restore the no-transport-installed default between tests so a
    failed test can't leak a fake transport into adjacent tests in the
    full suite (the very issue ``feedback_test_isolation`` guards
    against on the Edge side).
    """
    yield
    _piper_transport.reset_transport()


def test_synthesize_chunk_raises_clear_error_when_no_transport():
    """Stub-only slice contract: without ``set_transport``, every call
    raises ``RuntimeError`` with a pointer at the bring-up doc.
    """
    assert _piper_transport.get_transport() is None
    with pytest.raises(RuntimeError, match="piper transport not installed"):
        _piper_transport.synthesize_chunk("hello", "pt-BR")
    # The error message includes the doc path so operators know where to look.
    with pytest.raises(RuntimeError, match=r"ios/PIPER-EMBED\.md"):
        _piper_transport.synthesize_chunk("hello", "pt-BR")


def test_set_transport_routes_through_installed_callable():
    calls: list[tuple[str, str]] = []

    def fake(text: str, lang: str) -> bytes:
        calls.append((text, lang))
        return b"FAKEPIPER-" + text.encode() + b"-" + lang.encode()

    _piper_transport.set_transport(fake)
    assert _piper_transport.get_transport() is fake

    result = _piper_transport.synthesize_chunk("hello world", "pt-BR")
    assert result == b"FAKEPIPER-hello world-pt-BR"
    assert calls == [("hello world", "pt-BR")]


def test_reset_transport_returns_to_no_transport_state():
    _piper_transport.set_transport(lambda t, lang: b"x")
    assert _piper_transport.get_transport() is not None

    _piper_transport.reset_transport()
    assert _piper_transport.get_transport() is None
    with pytest.raises(RuntimeError, match="piper transport not installed"):
        _piper_transport.synthesize_chunk("hi", "en-US")


def test_set_transport_none_also_resets():
    _piper_transport.set_transport(lambda t, lang: b"x")
    _piper_transport.set_transport(None)
    assert _piper_transport.get_transport() is None


def test_installing_a_second_transport_replaces_the_first():
    first_calls: list[tuple[str, str]] = []
    second_calls: list[tuple[str, str]] = []

    def first(text: str, lang: str) -> bytes:
        first_calls.append((text, lang))
        return b"FIRST"

    def second(text: str, lang: str) -> bytes:
        second_calls.append((text, lang))
        return b"SECOND"

    _piper_transport.set_transport(first)
    _piper_transport.set_transport(second)

    result = _piper_transport.synthesize_chunk("text", "pt-BR")
    assert result == b"SECOND"
    assert first_calls == []
    assert second_calls == [("text", "pt-BR")]


def test_transport_can_raise_and_caller_observes_it():
    """A transport that raises should surface the exception
    untouched -- the seam does not swallow errors, ``ios_entrypoints``
    is responsible for chaining onto the next engine.
    """

    class TransportFailure(RuntimeError):
        pass

    def boom(text: str, lang: str) -> bytes:
        raise TransportFailure("synth failed: model not loaded")

    _piper_transport.set_transport(boom)
    with pytest.raises(TransportFailure, match="model not loaded"):
        _piper_transport.synthesize_chunk("text", "en-US")
