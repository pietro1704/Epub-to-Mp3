"""iOS-only entrypoints into the Python pipeline.

The macOS sidecar / CLI / HF Spaces backend drive ``converter.py``'s
``AudioConverter`` directly. iOS cannot: aiohttp / ``_socket`` /
``_ssl`` won't ``dlopen`` outside ``.framework`` bundles, so the
``EdgeTTS`` class -- which sits on top of those -- is dead weight on
iOS.

This module is the seam that lets Swift's ``PythonBridge`` reach into
the Python pipeline while letting Swift own the network. The flow:

1. Swift wires its ``EdgeTTSBridge`` (URLSessionWebSocketTask) into
   ``python_app.src.tts._edge_transport.set_transport(...)`` once at
   app boot.
2. Swift calls ``synthesize_chapter_via_transport(text, voice, out)``
   per chapter.
3. We chunk ``text`` here (paragraph-aware, char-bounded), invoke the
   transport once per chunk -- which on iOS dispatches to Swift, on
   any other host dispatches to ``edge_tts.Communicate`` -- concat
   the MP3 bytes, write the file, validate non-empty output.

Why a separate entrypoint instead of editing ``converter.py``: the
1637-test suite covers ``AudioConverter`` end-to-end with mocked
``edge_tts``; rerouting its TTS call site would require either
ripping out the ``EdgeTTS`` class wiring or duplicating its retry
loop here. Both are larger than the iOS use case justifies today.
This adapter shares the most important guarantees (chunking,
transport seam, file-write validation) with the main path and stays
small enough to audit at a glance.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Iterable, List

from .tts import _edge_transport

# Mirror ``EdgeTTS._DEFAULT_CHUNK_SIZE`` (12_000) but cap a touch lower
# so paragraph-boundary chunking has slack to land on whitespace
# instead of mid-word. Configurable via env for parity with the rest
# of the Edge tuning surface.
_DEFAULT_IOS_CHUNK_CHARS = 10_000


def _chunk_chars() -> int:
    raw = os.environ.get("IOS_EDGE_CHUNK_CHARS")
    if not raw:
        return _DEFAULT_IOS_CHUNK_CHARS
    try:
        value = int(raw)
    except ValueError:
        return _DEFAULT_IOS_CHUNK_CHARS
    return max(1_000, min(value, 15_000))


def _split_into_chunks(text: str, max_chars: int) -> List[str]:
    """Paragraph-aware char-bounded chunker. Splits on double newlines
    first, then on sentence boundaries, then hard-wraps as a last
    resort. Never returns an empty list for non-empty input.

    Deliberately simple: ``EdgeTTS._chunk_text`` does dialogue-voice
    routing + SSML prosody wrapping that depends on configuration we
    don't surface to iOS yet. Keeping iOS on plain-text chunks matches
    what ``EdgeTTSBridge.swift`` currently emits.
    """
    text = (text or "").strip()
    if not text:
        return []
    if len(text) <= max_chars:
        return [text]

    chunks: List[str] = []
    buffer = ""
    for paragraph in re.split(r"\n\s*\n", text):
        paragraph = paragraph.strip()
        if not paragraph:
            continue
        # If the paragraph itself exceeds max_chars, fall back to
        # sentence-level splitting so we don't emit a giant chunk.
        candidates: Iterable[str]
        if len(paragraph) > max_chars:
            candidates = re.split(r"(?<=[.!?])\s+", paragraph)
        else:
            candidates = [paragraph]
        for piece in candidates:
            piece = piece.strip()
            if not piece:
                continue
            # Hard-wrap any remaining oversize piece.
            while len(piece) > max_chars:
                head, piece = piece[:max_chars], piece[max_chars:].lstrip()
                if buffer:
                    chunks.append(buffer)
                    buffer = ""
                chunks.append(head)
            if not piece:
                continue
            if len(buffer) + len(piece) + 2 <= max_chars:
                buffer = f"{buffer}\n\n{piece}" if buffer else piece
            else:
                if buffer:
                    chunks.append(buffer)
                buffer = piece
    if buffer:
        chunks.append(buffer)
    return chunks


def synthesize_chapter_via_transport(text: str, voice: str, out_path: str) -> str:
    """iOS entrypoint. Chunks ``text``, synthesizes each chunk via the
    currently-installed transport in
    ``python_app.src.tts._edge_transport``, concatenates the MP3 bytes,
    writes to ``out_path``.

    Returns the resolved string path on success. Raises ``RuntimeError``
    if the transport produced no audio at all (every chunk empty) --
    matches what ``EdgeTTSBridge.swift`` does on
    ``EdgeTTSBridgeError.noAudioReceived`` so the Swift caller can
    surface a single error type regardless of which side failed.

    NB: MP3 concatenation by raw byte append is the same trick
    ``EdgeTTS._synthesize_parallel`` uses (Edge emits ID3-less MP3
    frames; concatenation produces a valid playable file). If we ever
    need true container-level concat we can swap to ``ffmpeg -f
    concat`` here without touching the Swift side.
    """
    chunks = _split_into_chunks(text, _chunk_chars())
    if not chunks:
        raise RuntimeError("ios_entrypoints: empty input text")

    audio = bytearray()
    for chunk in chunks:
        mp3 = _edge_transport.synthesize_chunk(chunk, voice)
        if mp3:
            audio.extend(mp3)

    if not audio:
        raise RuntimeError("ios_entrypoints: transport produced no audio")

    destination = Path(out_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(bytes(audio))
    return str(destination)


__all__ = ["synthesize_chapter_via_transport"]
