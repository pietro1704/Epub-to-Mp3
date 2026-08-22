"""Tests for the pluggable Edge-TTS transport seam + iOS entrypoint.

These tests prove:
  * ``_edge_transport.set_transport`` actually swaps the function used by
    ``synthesize_chunk`` (the seam works).
  * ``synthesize_chapter_via_transport`` chunks input, calls the
    transport per chunk, concatenates MP3 bytes, writes to disk.
  * The default transport is restored after a test that swapped it
    (no leakage across files in the suite).

Importantly we do NOT exercise the default ``edge_tts.Communicate``
path -- that's covered by the existing ``test_edge_engine`` /
``test_edge_truncation`` suites and requires network.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from python_app.src import ios_entrypoints
from python_app.src.tts import _edge_transport


@pytest.fixture(autouse=True)
def _reset_transport():
    """Every test in this file gets a clean default transport. Without
    this, a failure mid-test could leak a fake transport into the rest
    of the suite (the very issue ``test_isolation`` guards against).
    """
    yield
    _edge_transport.reset_transport()


def test_set_transport_swaps_the_active_callable():
    def fake(text: str, voice: str) -> bytes:
        return b"FAKE-" + text.encode() + b"-" + voice.encode()

    _edge_transport.set_transport(fake)
    assert _edge_transport.get_transport() is fake
    assert _edge_transport.synthesize_chunk("hi", "en-US-AriaNeural") == (
        b"FAKE-hi-en-US-AriaNeural"
    )


def test_reset_transport_restores_default():
    _edge_transport.set_transport(lambda t, v: b"x")
    assert _edge_transport.get_transport() is not _edge_transport._default_transport

    _edge_transport.reset_transport()
    assert _edge_transport.get_transport() is _edge_transport._default_transport


def test_set_transport_none_also_resets():
    _edge_transport.set_transport(lambda t, v: b"x")
    _edge_transport.set_transport(None)
    assert _edge_transport.get_transport() is _edge_transport._default_transport


def test_chunker_keeps_short_text_intact():
    chunks = ios_entrypoints._split_into_chunks("short paragraph.", 1000)
    assert chunks == ["short paragraph."]


def test_chunker_splits_on_paragraph_boundaries():
    text = "first paragraph.\n\nsecond paragraph.\n\nthird."
    chunks = ios_entrypoints._split_into_chunks(text, 25)
    assert all(len(c) <= 25 for c in chunks)
    assert "first paragraph." in " ".join(chunks)
    assert "third." in " ".join(chunks)


def test_chunker_hard_wraps_oversize_paragraph():
    text = "a" * 5000
    chunks = ios_entrypoints._split_into_chunks(text, 1000)
    assert all(len(c) <= 1000 for c in chunks)
    assert sum(len(c) for c in chunks) == 5000


def test_chunker_returns_empty_for_empty_input():
    assert ios_entrypoints._split_into_chunks("", 1000) == []
    assert ios_entrypoints._split_into_chunks("   \n\n  ", 1000) == []


def test_synthesize_chapter_via_transport_writes_concatenated_bytes(tmp_path: Path):
    calls: list[tuple[str, str]] = []

    def fake(text: str, voice: str) -> bytes:
        calls.append((text, voice))
        return b"MP3:" + text[:10].encode()

    _edge_transport.set_transport(fake)

    out = tmp_path / "chapter.mp3"
    long_text = (("paragraph. " * 50) + "\n\n") * 5  # forces > 1 chunk
    result = ios_entrypoints.synthesize_chapter_via_transport(
        long_text, "en-US-AriaNeural", str(out)
    )

    assert result == str(out)
    assert out.exists()
    assert out.stat().st_size > 0
    # Every call should have used our voice + a non-empty text body.
    assert calls, "transport never invoked"
    assert all(v == "en-US-AriaNeural" for _, v in calls)
    assert all(t.strip() for t, _ in calls)
    # File bytes = concatenation of all transport returns, in order.
    expected = b"".join(b"MP3:" + t[:10].encode() for t, _ in calls)
    assert out.read_bytes() == expected


def test_synthesize_chapter_via_transport_raises_on_empty_input(tmp_path: Path):
    _edge_transport.set_transport(lambda t, v: b"never")
    with pytest.raises(RuntimeError, match="empty input"):
        ios_entrypoints.synthesize_chapter_via_transport(
            "", "en-US-AriaNeural", str(tmp_path / "x.mp3")
        )


def test_synthesize_chapter_via_transport_raises_when_no_audio(tmp_path: Path):
    _edge_transport.set_transport(lambda t, v: b"")
    out = tmp_path / "silent.mp3"
    with pytest.raises(RuntimeError, match="no audio"):
        ios_entrypoints.synthesize_chapter_via_transport("some text", "en-US-AriaNeural", str(out))
    assert not out.exists()


def test_chunk_chars_env_override(monkeypatch):
    monkeypatch.setenv("IOS_EDGE_CHUNK_CHARS", "2500")
    assert ios_entrypoints._chunk_chars() == 2500


def test_chunk_chars_env_invalid_falls_back(monkeypatch):
    monkeypatch.setenv("IOS_EDGE_CHUNK_CHARS", "not-a-number")
    assert ios_entrypoints._chunk_chars() == ios_entrypoints._DEFAULT_IOS_CHUNK_CHARS


def test_ios_defaults_match_the_measured_edge_throughput_profile(monkeypatch):
    monkeypatch.delenv("IOS_EDGE_CHUNK_CHARS", raising=False)
    monkeypatch.delenv("EDGE_MAX_SEGMENT_SECONDS", raising=False)

    assert ios_entrypoints._chunk_chars() == 15_000
    assert ios_entrypoints._max_segment_seconds() == 75


def test_chunk_chars_env_clamped(monkeypatch):
    monkeypatch.setenv("IOS_EDGE_CHUNK_CHARS", "999999")
    assert ios_entrypoints._chunk_chars() == 15_000
    monkeypatch.setenv("IOS_EDGE_CHUNK_CHARS", "10")
    assert ios_entrypoints._chunk_chars() == 1_000


def test_synthesize_chunk_rejects_non_bytes_return():
    """Regression: a Swift PythonFunction once *returned* a RuntimeError
    instance instead of raising it, so the Python pipeline received an
    exception object where it expected bytes and stalled silently. The
    seam now type-checks the transport result.
    """
    _edge_transport.set_transport(lambda t, v: RuntimeError("simulated bridge regression"))
    with pytest.raises(TypeError, match="expected bytes"):
        _edge_transport.synthesize_chunk("hi", "en-US-AriaNeural")


def test_synthesize_chunk_accepts_bytearray():
    """``bytearray`` is morally equivalent to ``bytes`` for our pipeline;
    accept it and normalise to ``bytes`` so downstream ``audio.extend``
    behaves identically regardless of which the transport happened to
    return.
    """
    _edge_transport.set_transport(lambda t, v: bytearray(b"raw"))
    assert _edge_transport.synthesize_chunk("hi", "en-US-AriaNeural") == b"raw"
