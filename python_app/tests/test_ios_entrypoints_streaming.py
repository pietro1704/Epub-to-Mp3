"""Tests for ``ios_entrypoints.synthesize_chapter_streaming``.

Streaming contract:
  * ``on_segment(mp3_bytes, segment_index, total)`` is called once per
    chunk that produces audio, in order, before the function returns.
  * The first chunk uses ``EDGE_FIRST_CHUNK_CHARS`` (default 500), the
    rest use ``IOS_EDGE_CHUNK_CHARS`` (default 10 000).
  * The concatenation of all segment bytes equals the content of the
    output file.
  * For short text (fits in first chunk) exactly one segment is emitted.
  * Piper fallback works per-segment (same as ``synthesize_chapter_via_transport``).
  * Empty input raises ``RuntimeError``.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import List, Tuple

import pytest

from python_app.src import ios_entrypoints
from python_app.src import paths as paths_module
from python_app.src.tts import _edge_transport, _piper_transport

_PATHS_SNAPSHOT_ATTRS = (
    "PERSISTENT_ROOT",
    "CACHE_DIR",
    "OUTPUT_DIR",
    "JOBS_DIR",
    "UPLOADS_DIR",
    "JOB_INPUTS_DIR",
    "SOURCE_BACKUPS_DIR",
    "LOGS_DIR",
    "TELEMETRY_DIR",
)
_ENV_SNAPSHOT_KEYS = (
    "CACHE_DIR",
    "OUTPUT_DIR",
    "PERSISTENT_ROOT",
    "MAX_CHAPTER_CHARS",
    "EDGE_FIRST_CHUNK_CHARS",
    "IOS_EDGE_CHUNK_CHARS",
)


@pytest.fixture(autouse=True)
def _isolate_streaming_state():
    """Restore transport + env after every test."""
    env_snap = {k: os.environ.get(k) for k in _ENV_SNAPSHOT_KEYS}
    paths_snap = {a: getattr(paths_module, a, None) for a in _PATHS_SNAPSHOT_ATTRS}
    try:
        yield
    finally:
        _edge_transport.reset_transport()
        _piper_transport.reset_transport()
        for key, val in env_snap.items():
            if val is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = val
        for attr, val in paths_snap.items():
            if val is None:
                if hasattr(paths_module, attr):
                    delattr(paths_module, attr)
            else:
                setattr(paths_module, attr, val)


@pytest.fixture
def _counting_transport():
    """Install a transport that records calls and returns distinct bytes."""
    calls: List[Tuple[str, str]] = []

    def fake(text: str, voice: str) -> bytes:
        calls.append((text, voice))
        return b"FAKEMP3:" + b"X" * 200 + f":{len(calls)}".encode()

    _edge_transport.set_transport(fake)
    return calls


# ---------------------------------------------------------------------------
# Basic callback contract
# ---------------------------------------------------------------------------


def test_streaming_emits_one_segment_for_short_text(tmp_path: Path, _counting_transport):
    """Short text (< first-chunk size) → exactly one ``on_segment`` call."""
    segments: List[Tuple[bytes, int, int]] = []

    def on_seg(data: bytes, seg_idx: int, total: int) -> None:
        segments.append((data, seg_idx, total))

    out = tmp_path / "ch.mp3"
    ios_entrypoints.synthesize_chapter_streaming(
        "Hello world.",
        "en-US-AriaNeural",
        str(out),
        on_segment=on_seg,
    )

    assert len(segments) == 1, f"expected 1 segment, got {len(segments)}"
    assert segments[0][1] == 0, "first segment must have index 0"
    assert out.exists()


def test_streaming_segment_bytes_match_output_file(tmp_path: Path, _counting_transport):
    """Concatenation of all segment bytes equals the written MP3 file."""
    segments: List[bytes] = []

    def on_seg(data: bytes, seg_idx: int, total: int) -> None:
        segments.append(data)

    out = tmp_path / "ch.mp3"
    ios_entrypoints.synthesize_chapter_streaming(
        "Short chapter text.",
        "en-US-AriaNeural",
        str(out),
        on_segment=on_seg,
    )

    assert out.read_bytes() == b"".join(
        segments
    ), "File content must equal the concatenation of segment callbacks"


def test_streaming_emits_multiple_segments_for_long_text(tmp_path: Path, _counting_transport):
    """Text long enough to produce multiple chunks → N ``on_segment`` calls."""
    os.environ["EDGE_FIRST_CHUNK_CHARS"] = "20"
    os.environ["IOS_EDGE_CHUNK_CHARS"] = "20"

    segments: List[Tuple[bytes, int, int]] = []

    def on_seg(data: bytes, seg_idx: int, total: int) -> None:
        segments.append((data, seg_idx, total))

    # 120 chars → should produce at least 3 chunks with 20-char limit.
    text = ("abcdefghij " * 12).strip()  # 132 chars
    out = tmp_path / "ch.mp3"
    ios_entrypoints.synthesize_chapter_streaming(
        text,
        "en-US-AriaNeural",
        str(out),
        on_segment=on_seg,
    )

    assert len(segments) > 1, "long text must produce multiple segment callbacks"
    # Indices must be consecutive starting from 0.
    indices = [s[1] for s in segments]
    assert indices == list(range(len(segments))), f"non-consecutive indices: {indices}"


def test_streaming_first_chunk_uses_small_size(tmp_path: Path, _counting_transport):
    """First chunk is bounded by ``EDGE_FIRST_CHUNK_CHARS`` (default 500).
    Subsequent chunks use ``IOS_EDGE_CHUNK_CHARS``. We override both to
    small values and verify the first chunk text length.
    """
    os.environ["EDGE_FIRST_CHUNK_CHARS"] = "30"
    os.environ["IOS_EDGE_CHUNK_CHARS"] = "200"

    # 300-char text → first chunk ≤30 chars, rest in larger chunk.
    text = "a" * 300
    segments: List[Tuple[bytes, int, int]] = []

    def on_seg(data: bytes, seg_idx: int, total: int) -> None:
        segments.append((data, seg_idx, total))

    ios_entrypoints.synthesize_chapter_streaming(
        text, "en-US-AriaNeural", str(tmp_path / "ch.mp3"), on_segment=on_seg
    )

    # First transport call text length must be ≤30.
    first_text, _ = _counting_transport[0]
    assert (
        len(first_text) <= 30
    ), f"first chunk must be ≤ EDGE_FIRST_CHUNK_CHARS=30, got {len(first_text)}"
    # At least two segments since 300 > 30.
    assert len(segments) >= 2


def test_streaming_empty_input_raises(tmp_path: Path, _counting_transport):
    """Empty text must raise ``RuntimeError`` without calling ``on_segment``."""
    called = []

    def on_seg(data: bytes, seg_idx: int, total: int) -> None:
        called.append(data)

    with pytest.raises(RuntimeError, match="empty input"):
        ios_entrypoints.synthesize_chapter_streaming(
            "", "en-US-AriaNeural", str(tmp_path / "ch.mp3"), on_segment=on_seg
        )
    assert not called, "on_segment must not be called for empty input"


def test_streaming_no_audio_raises(tmp_path: Path):
    """If every chunk returns empty bytes, RuntimeError is raised."""
    _edge_transport.set_transport(lambda t, v: b"")
    called = []

    def on_seg(data: bytes, seg_idx: int, total: int) -> None:
        called.append(data)

    with pytest.raises(RuntimeError, match="no audio"):
        ios_entrypoints.synthesize_chapter_streaming(
            "Some text here.",
            "en-US-AriaNeural",
            str(tmp_path / "ch.mp3"),
            on_segment=on_seg,
        )
    assert not called


def test_streaming_on_segment_indices_are_zero_based(tmp_path: Path, _counting_transport):
    """Segment indices start from 0 regardless of chunk count."""
    os.environ["EDGE_FIRST_CHUNK_CHARS"] = "10"
    os.environ["IOS_EDGE_CHUNK_CHARS"] = "10"

    indices = []

    def on_seg(data: bytes, seg_idx: int, total: int) -> None:
        indices.append(seg_idx)

    text = "word " * 20  # 100 chars, 10-char chunks → ~10 segments
    ios_entrypoints.synthesize_chapter_streaming(
        text, "en-US-AriaNeural", str(tmp_path / "ch.mp3"), on_segment=on_seg
    )

    assert indices[0] == 0
    assert indices == list(range(len(indices)))


# ---------------------------------------------------------------------------
# Piper fallback per-segment
# ---------------------------------------------------------------------------


def test_streaming_piper_fallback_per_segment(tmp_path: Path):
    """Edge fails → Piper is called per chunk when fallback is configured."""
    edge_calls: List[str] = []
    piper_calls: List[str] = []

    def failing_edge(text: str, voice: str) -> bytes:
        edge_calls.append(text)
        raise RuntimeError("edge down")

    def piper(text: str, lang: str) -> bytes:
        piper_calls.append(text)
        return b"PIPERMP3:" + text[:4].encode()

    _edge_transport.set_transport(failing_edge)
    _piper_transport.set_transport(piper)

    segments = []

    def on_seg(data: bytes, seg_idx: int, total: int) -> None:
        segments.append(data)

    out = tmp_path / "ch.mp3"
    ios_entrypoints.synthesize_chapter_streaming(
        "Hello world.",
        "en-US-AriaNeural",
        str(out),
        on_segment=on_seg,
        piper_fallback_lang="en-US",
    )

    assert piper_calls, "Piper should have been invoked as fallback"
    assert segments, "segment callback must still fire via Piper"
    assert out.exists()


# ---------------------------------------------------------------------------
# Env-var configuration
# ---------------------------------------------------------------------------


def test_first_chunk_chars_default(tmp_path: Path, _counting_transport):
    """Default ``EDGE_FIRST_CHUNK_CHARS`` is 500 chars."""
    # Produce text > 500 chars to force split.
    text = "word " * 120  # 600 chars
    segments = []

    def on_seg(data: bytes, seg_idx: int, total: int) -> None:
        segments.append(seg_idx)

    ios_entrypoints.synthesize_chapter_streaming(
        text, "en-US-AriaNeural", str(tmp_path / "ch.mp3"), on_segment=on_seg
    )

    first_text, _ = _counting_transport[0]
    assert len(first_text) <= 500, f"default first-chunk must be ≤500 chars, got {len(first_text)}"
    assert len(segments) >= 2, "600-char text with 500-char first chunk must produce ≥2 segments"


def test_edge_first_chunk_chars_env_override(tmp_path: Path, _counting_transport):
    """``EDGE_FIRST_CHUNK_CHARS=100`` shrinks the first chunk."""
    os.environ["EDGE_FIRST_CHUNK_CHARS"] = "100"
    text = "a" * 400

    segments = []

    def on_seg(data: bytes, seg_idx: int, total: int) -> None:
        segments.append(seg_idx)

    ios_entrypoints.synthesize_chapter_streaming(
        text, "en-US-AriaNeural", str(tmp_path / "ch.mp3"), on_segment=on_seg
    )

    first_text, _ = _counting_transport[0]
    assert len(first_text) <= 100
    assert len(segments) >= 2
