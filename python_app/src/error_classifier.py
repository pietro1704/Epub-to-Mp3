"""
Classify TTS conversion errors into stable, machine-readable categories.

Usage:
    from .error_classifier import classify_error

    category = classify_error("429 Too Many Requests")  # → "rate_limit"
    category = classify_error("Chapter timed out")      # → "timeout"
    category = classify_error("Some novel message")     # → "unknown"

Categories (exhaustive):
    rate_limit          HTTP 429 / throttling / quota exceeded
    timeout             Timed-out synthesis / stalled engine / HTTP 503
    network             SSL, DNS, connection-refused, connection-reset errors
    engine_unavailable  No TTS engine left in fallback chain
    audio_truncation    Audio shorter than expected for character count (WPM check)
    incomplete_segments Segment-count mismatch or missing edge chunks
    invalid_audio       Empty or zero-duration audio file
    cancelled           Conversion cancelled by user
    file_not_found      Missing input file or missing audio output
    auth                HTTP 401 / 403 / authentication rejected
    unknown             Catch-all for anything else
"""

from __future__ import annotations

import re

# ── Pattern table ─────────────────────────────────────────────────────────────
# Each tuple: (category, compiled regex). Checked in order; first match wins.
_PATTERNS: list[tuple[str, re.Pattern]] = [
    # User-initiated cancellation — check before generic errors
    ("cancelled", re.compile(r"cancel", re.I)),
    # Auth errors
    ("auth", re.compile(r"401|403|unauthorized|forbidden|authentication", re.I)),
    # Rate limiting — must come before network/timeout so 429 is caught early
    (
        "rate_limit",
        re.compile(r"429|rate.?limit|throttl|quota|too many requests?", re.I),
    ),
    # Timeout / service unavailable
    (
        "timeout",
        re.compile(r"timeout|timed.?out|stall|503|service.?unavailable", re.I),
    ),
    # Network / connectivity
    (
        "network",
        re.compile(
            r"ssl|certificate|dns|name.?resolution|connection.?refused"
            r"|connection.?reset|unreachable|network|broken.?pipe|eof",
            re.I,
        ),
    ),
    # No engine in fallback chain
    (
        "engine_unavailable",
        re.compile(
            r"no (tts )?engine|engine.{0,20}unavailable" r"|no engine available|not available",
            re.I,
        ),
    ),
    # Segment-count mismatch (Edge-TTS specific)
    (
        "incomplete_segments",
        re.compile(r"incomplete.?segment|segment.{0,10}(failure|count|missing)", re.I),
    ),
    # Audio shorter than character-count implies (WPM-based validation)
    (
        "audio_truncation",
        re.compile(
            r"truncat|too short|audio incomplete|below expected"
            r"|wpm|completion ratio|audio.{0,20}short",
            re.I,
        ),
    ),
    # Empty or zero-duration audio
    (
        "invalid_audio",
        re.compile(
            r"invalid audio|audio validation|empty audio|zero.?duration"
            r"|no audio|output.{0,20}empty",
            re.I,
        ),
    ),
    # File missing on disk
    (
        "file_not_found",
        re.compile(r"file not found|no such file|filenotfound|not creat", re.I),
    ),
]

_UNKNOWN = "unknown"


def classify_error(message: str) -> str:
    """Return a stable error category string for *message*.

    Args:
        message: Any error/failure string — exception text, log message, etc.

    Returns:
        One of the category strings documented in this module's docstring.
        Never raises; returns ``"unknown"`` on any unexpected input.
    """
    if not message:
        return _UNKNOWN
    text = str(message)
    for category, pattern in _PATTERNS:
        if pattern.search(text):
            return category
    return _UNKNOWN
