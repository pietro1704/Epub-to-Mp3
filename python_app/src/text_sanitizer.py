"""Aggressive text cleanup for Edge-TTS recovery.

Edge-TTS occasionally returns ``NoAudioReceived`` for a specific text+voice
combination because the payload contains invisible Unicode that confuses
Microsoft's tokeniser. The 2026-04-29 conversion of "Carl, o Explorador
de Masmorras" exposed two ~25-minute chapters where 1 of ~45 segments
deterministically returned no audio across three retry rounds — strict
backoff didn't help because the input itself was the problem.

This module is the *recovery* sanitiser. It is deliberately more
aggressive than ``TextFormattingProcessor.clean_tts_text`` (which has to
preserve markup like ``[[lang:pt-BR]]``): we strip everything that is
invisible to a listener but might trip the TTS parser, and we normalise
the codepoint encoding so a precomposed ``é`` and a decomposed ``e + ́``
render the same text. The result is plain UTF-8 with no exotic glyphs.

The general-purpose pre-processor stays intact — this module is only
called from the Edge engine's recovery path so the regular happy path
keeps the same input it always had.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Final

# Unicode codepoints that are silent to a listener but routinely trigger
# Edge-TTS rejection. We strip them outright rather than replace with a
# space because most appear inside words (zero-width joiners, soft
# hyphens, BOM in mid-string) where a space would mangle pronunciation.
_INVISIBLE_CODEPOINTS: Final[frozenset[str]] = frozenset(
    {
        "\u00ad",  # SOFT HYPHEN
        "\u200b",  # ZERO WIDTH SPACE
        "\u200c",  # ZERO WIDTH NON-JOINER
        "\u200d",  # ZERO WIDTH JOINER
        "\u200e",  # LEFT-TO-RIGHT MARK
        "\u200f",  # RIGHT-TO-LEFT MARK
        "\u2028",  # LINE SEPARATOR
        "\u2029",  # PARAGRAPH SEPARATOR
        "\u202a",  # LEFT-TO-RIGHT EMBEDDING
        "\u202b",  # RIGHT-TO-LEFT EMBEDDING
        "\u202c",  # POP DIRECTIONAL FORMATTING
        "\u202d",  # LEFT-TO-RIGHT OVERRIDE
        "\u202e",  # RIGHT-TO-LEFT OVERRIDE
        "\u2060",  # WORD JOINER
        "\u2061",  # FUNCTION APPLICATION
        "\u2062",  # INVISIBLE TIMES
        "\u2063",  # INVISIBLE SEPARATOR
        "\u2064",  # INVISIBLE PLUS
        "\u206a",  # INHIBIT SYMMETRIC SWAPPING
        "\u206b",  # ACTIVATE SYMMETRIC SWAPPING
        "\u206c",  # INHIBIT ARABIC FORM SHAPING
        "\u206d",  # ACTIVATE ARABIC FORM SHAPING
        "\u206e",  # NATIONAL DIGIT SHAPES
        "\u206f",  # NOMINAL DIGIT SHAPES
        "\ufeff",  # ZERO WIDTH NO-BREAK SPACE / BOM
        "\ufff9",  # INTERLINEAR ANNOTATION ANCHOR
        "\ufffa",  # INTERLINEAR ANNOTATION SEPARATOR
        "\ufffb",  # INTERLINEAR ANNOTATION TERMINATOR
        "\ufffc",  # OBJECT REPLACEMENT CHARACTER
    }
)

# Whitespace-class characters that should collapse to a single ASCII
# space — preserves rhythm without leaving exotic glyphs in the payload.
_WEIRD_WHITESPACE_RE: Final[re.Pattern[str]] = re.compile(
    r"[\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]"
)

# Control characters except tab/newline/carriage-return — those three are
# preserved because the Edge tokeniser handles them and downstream code
# depends on line breaks for sentence detection.
_CONTROL_RE: Final[re.Pattern[str]] = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

# Sentence boundary regex: keeps the trailing punctuation with the
# sentence so the listener hears the natural pause. The lookbehind makes
# sure a period that's part of an abbreviation ("Sr.", "etc.") doesn't
# split. We err on the side of *more* splits because a short orphan
# sentence is fine for TTS but a too-long unsplittable string is what
# made the original chunk fail in the first place.
_SENTENCE_SPLIT_RE: Final[re.Pattern[str]] = re.compile(
    # Sentence break only when followed by an upper-case letter — keeps
    # "etc. continuou" together (common abbreviation pattern), splits
    # "Frase. Outra" cleanly. PT-BR opening words almost always start with
    # a capital, so the false-negative rate is acceptable.
    r"(?<=[.!?\u2026])\s+(?=[A-ZÁÀÂÃÉÊÍÓÔÕÚÇ\u00c0-\u00dc])"
)


def sanitize_for_edge_recovery(text: str) -> str:
    """Strip invisibles, normalise NFKC, collapse weird whitespace.

    Returns the cleaned string. Empty/whitespace-only input returns the
    empty string. The function is total — never raises.
    """
    if not text:
        return ""
    # NFKC unifies compatibility forms (full-width, ligatures, etc.) and
    # composes combining marks into precomposed codepoints. Edge handles
    # the precomposed forms reliably; the decomposed form is one of the
    # known triggers.
    cleaned = unicodedata.normalize("NFKC", text)
    cleaned = "".join(ch for ch in cleaned if ch not in _INVISIBLE_CODEPOINTS)
    cleaned = _CONTROL_RE.sub(" ", cleaned)
    cleaned = _WEIRD_WHITESPACE_RE.sub(" ", cleaned)
    # Collapse runs of spaces produced by the substitutions above.
    cleaned = re.sub(r"[ \t]+", " ", cleaned)
    # Strip per-line so we keep paragraph structure but drop trailing
    # whitespace that might confuse the parser.
    cleaned = "\n".join(line.strip() for line in cleaned.splitlines())
    return cleaned.strip()


def split_into_sentences(text: str, *, max_chars: int = 1500) -> list[str]:
    """Split ``text`` into sentence-sized fragments suitable for re-synthesis.

    Two-pass strategy:

    1. Split on sentence-final punctuation followed by capital letters.
    2. Any fragment longer than ``max_chars`` is force-split on the
       nearest comma, em-dash, semicolon, or — last resort — on a
       whitespace boundary. Edge tolerates short fragments far better
       than long ones, so over-splitting here is preferable to leaving a
       monster fragment that will fail again.

    Returns a non-empty list when ``text`` has content; ``[]`` otherwise.
    """
    cleaned = (text or "").strip()
    if not cleaned:
        return []

    sentences = [s.strip() for s in _SENTENCE_SPLIT_RE.split(cleaned) if s.strip()]
    if not sentences:
        sentences = [cleaned]

    out: list[str] = []
    for sentence in sentences:
        if len(sentence) <= max_chars:
            out.append(sentence)
            continue
        out.extend(_force_split(sentence, max_chars=max_chars))
    return out


def _force_split(sentence: str, *, max_chars: int) -> list[str]:
    """Last-resort splitter for sentences too long for Edge to swallow."""
    if len(sentence) <= max_chars:
        return [sentence]
    # Try comma/dash/semicolon first — natural pause points.
    for separator in ("; ", " — ", " – ", ", "):
        parts = sentence.split(separator)
        if len(parts) > 1:
            rebuilt = []
            buffer = ""
            for part in parts:
                candidate = f"{buffer}{separator}{part}".strip(separator) if buffer else part
                if len(candidate) > max_chars and buffer:
                    rebuilt.append(buffer.strip())
                    buffer = part
                else:
                    buffer = candidate
            if buffer:
                rebuilt.append(buffer.strip())
            if all(len(r) <= max_chars for r in rebuilt):
                return rebuilt
    # Hard cut on whitespace at the boundary — never break inside a word.
    chunks: list[str] = []
    remaining = sentence
    while len(remaining) > max_chars:
        cut = remaining.rfind(" ", 0, max_chars)
        if cut <= 0:
            cut = max_chars
        chunks.append(remaining[:cut].strip())
        remaining = remaining[cut:].strip()
    if remaining:
        chunks.append(remaining)
    return chunks
