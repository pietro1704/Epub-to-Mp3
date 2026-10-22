"""Prepare legacy iOS speech text, voice selection and duration-bounded chunks."""

from __future__ import annotations

import os
import re
from typing import Any, Dict, Iterable, List

# Match ``EdgeTTS._DEFAULT_CHUNK_SIZE`` (12_000). The paragraph-boundary
# chunker backs up to whitespace so mid-word splits are already avoided.
# Configurable via env for parity with the rest of the Edge tuning surface.
_DEFAULT_IOS_CHUNK_CHARS = 12_000

# First-chunk burst size for segment streaming. A small first chunk
# lets the Swift player queue audio in ~500 ms instead of waiting
# for the entire chapter. Subsequent chunks use ``_chunk_chars()``
# for throughput. Configurable via ``EDGE_FIRST_CHUNK_CHARS`` env var.
# Default: 500 chars (~1–2 sentences, typically 4–8 s of audio at
# 200 WPM neural voice). Range: [100, 2000].
_DEFAULT_FIRST_CHUNK_CHARS = 500
_DEFAULT_MAX_SEGMENT_SECONDS = 85.0
_DEFAULT_EXPECTED_WPM = 200.0


def _chunk_chars() -> int:
    raw = os.environ.get("IOS_EDGE_CHUNK_CHARS")
    if not raw:
        return _DEFAULT_IOS_CHUNK_CHARS
    try:
        value = int(raw)
    except ValueError:
        return _DEFAULT_IOS_CHUNK_CHARS
    return max(1_000, min(value, 15_000))


def _first_chunk_chars() -> int:
    """Size of the burst-first chunk used in segment streaming.

    Kept intentionally small so the Swift player can queue the first
    ``AVPlayerItem`` within ~500 ms of synthesis start, satisfying the
    HIG < 3 s time-to-first-byte requirement.
    """
    raw = os.environ.get("EDGE_FIRST_CHUNK_CHARS")
    if not raw:
        return _DEFAULT_FIRST_CHUNK_CHARS
    try:
        value = int(raw)
    except ValueError:
        return _DEFAULT_FIRST_CHUNK_CHARS
    return max(10, min(value, 2_000))


def _expected_wpm() -> float:
    try:
        return max(1.0, float(os.environ.get("EXPECTED_WPM", _DEFAULT_EXPECTED_WPM)))
    except ValueError:
        return _DEFAULT_EXPECTED_WPM


def _max_segment_seconds() -> float:
    try:
        return max(
            1.0, float(os.environ.get("EDGE_MAX_SEGMENT_SECONDS", _DEFAULT_MAX_SEGMENT_SECONDS))
        )
    except ValueError:
        return _DEFAULT_MAX_SEGMENT_SECONDS


def _estimated_seconds(text: str) -> float:
    return len(re.findall(r"\S+", text or "")) / _expected_wpm() * 60.0


def _split_duration_bound(text: str, max_seconds: float) -> List[str]:
    """Split text at sentence/word boundaries to match EdgeTTS duration caps."""
    sentences = [part.strip() for part in re.split(r"(?<=[.!?])\s+", text) if part.strip()]
    if not sentences:
        return []
    segments: List[str] = []
    buffer: List[str] = []
    for sentence in sentences:
        candidate = " ".join(buffer + [sentence])
        if buffer and _estimated_seconds(candidate) > max_seconds:
            segments.append(" ".join(buffer))
            buffer = [sentence]
        else:
            buffer.append(sentence)
    if buffer:
        segments.append(" ".join(buffer))

    result: List[str] = []
    max_words = max(1, int(max_seconds / 60.0 * _expected_wpm()))
    for segment in segments:
        words = segment.split()
        if len(words) <= max_words:
            result.append(segment)
            continue
        result.extend(
            " ".join(words[start : start + max_words]) for start in range(0, len(words), max_words)
        )
    return [segment for segment in result if segment]


def _resolve_auto_voice(text: str) -> str:
    """Map ``"auto"`` to a concrete Edge-TTS voice name based on the text
    language. Mirrors the logic in ``convert_epub`` (line ~710) but works
    per-chunk without access to the EbookReader.
    """
    sample = text[:2000].lower()
    pt_markers = sum(
        1
        for w in (
            "não",
            "são",
            "está",
            "também",
            "então",
            "já",
            "você",
            "isso",
            "mais",
            "como",
            "para",
            "quando",
            "sobre",
            "ele",
            "ela",
            "muito",
            "onde",
            "ainda",
            "depois",
        )
        if w in sample
    )
    if pt_markers >= 3:
        return "pt-BR-FranciscaNeural"
    return "en-US-AriaNeural"


def prepare_audible_speech_text(speech_text: str) -> str:
    """Return the final TTS payload for parser-prepared ``speech_text``.

    This deliberately mirrors ``AudioConverter._prepare_payload``'s
    populated-``speech_text`` branch.  The parser has already applied
    formatting cues and structural chapter-title pauses, so this function
    must not rebuild the text from raw formatting segments.  It only resolves
    any residual ``[[fmt:...]]`` markers or removes inline Markdown before
    handing the text to the Swift-owned Edge transport.

    The formatter import stays local: basic iOS synthesis must retain its
    existing import safety and avoid importing optional pipeline modules until
    the caller explicitly prepares text for speech.
    """
    raw_speech = speech_text or ""
    if not raw_speech:
        return ""

    try:
        from .text_formatting import TextFormattingProcessor
    except ImportError:
        return raw_speech

    formatter = TextFormattingProcessor()
    if "[[fmt" in raw_speech:
        return formatter.to_audible_text(raw_speech, None) or ""
    return formatter.strip_inline_markdown(raw_speech) or ""


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
        if _estimated_seconds(text) <= _max_segment_seconds():
            return [text]
        return _split_duration_bound(text, _max_segment_seconds())

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
    bounded: List[str] = []
    for chunk in chunks:
        if _estimated_seconds(chunk) <= _max_segment_seconds():
            bounded.append(chunk)
        else:
            bounded.extend(_split_duration_bound(chunk, _max_segment_seconds()))
    return bounded


def prepare_chunks(
    text: str,
    voice: str = "auto",
    streaming: bool = False,
) -> Dict[str, Any]:
    """Return pre-split text chunks WITHOUT synthesizing.

    Swift calls this to get the chunk list, then fires parallel
    ``EdgeTTSBridge`` WebSocket connections — one per chunk — achieving
    the same chunk-level concurrency the desktop path gets via
    ``EDGE_MAX_CONCURRENCY=12``.

    Args:
        text: Full chapter text.
        voice: Edge voice id or ``"auto"``.
        streaming: If ``True``, uses the first-chunk-burst strategy
            (small first chunk for fast time-to-first-byte).

    Returns:
        ``{"chunks": [str, ...], "voice": str}`` — resolved voice +
        ordered chunk list ready for parallel TTS.
    """
    text = (text or "").strip()
    if not text:
        return {"chunks": [], "voice": voice}

    if (voice or "auto").strip().lower() == "auto":
        voice = _resolve_auto_voice(text)

    if streaming:
        first_size = _first_chunk_chars()
        normal_size = _chunk_chars()
        if len(text) <= first_size:
            chunks: List[str] = [text]
        else:
            first_chunk = text[:first_size]
            last_space = first_chunk.rfind(" ")
            if last_space > first_size // 2:
                first_chunk = first_chunk[:last_space]
            remainder = text[len(first_chunk) :].lstrip()
            rest_chunks = _split_into_chunks(remainder, normal_size) if remainder else []
            chunks = [first_chunk] + rest_chunks
    else:
        chunks = _split_into_chunks(text, _chunk_chars())

    return {"chunks": chunks, "voice": voice}
