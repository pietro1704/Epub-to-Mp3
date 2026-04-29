"""Split narrative text into narrator/character spans for multi-voice TTS.

The splitter recognises three kinds of dialogue markers commonly found in
EPUB/PDF books:

1. Curly double quotes (`"..."`) — most modern PT-BR/EN books.
2. Straight double quotes (`"..."`) — older books, Project Gutenberg.
3. Em-dash dialogue lines (`— Olá!` at the start of a line) — the
   canonical PT-BR convention.
4. French/European angle quotes (`«...»`) — some PT-PT and FR books.

Out-of-scope (deliberately): single quotes (`'...'`), apostrophes,
nested-quote disambiguation, named-character voice attribution. Those
require NER/coreference and are far beyond what a simple splitter should
attempt — false positives there are worse than missing variation.

The output is a stable list of ``DialogueSpan`` chunks tagged
``narrator`` or ``character``; the caller is responsible for mapping
tags to TTS voices.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, List, Literal

SpanRole = Literal["narrator", "character"]


@dataclass(frozen=True)
class DialogueSpan:
    """A contiguous chunk of text routed to one of the two voices."""

    text: str
    role: SpanRole


# Paired quote markers: (open, close). Order matters — longer/specific
# pairs come first so we never split a curly closer as a straight one.
_PAIRED_QUOTES: tuple[tuple[str, str], ...] = (
    ("\u201c", "\u201d"),  # “ ... ” curly double quotes
    ("\u201e", "\u201c"),  # „ ... “ German low/high
    ("\u00ab", "\u00bb"),  # « ... » French/PT-PT
    ('"', '"'),
)

# An em-dash line is "— text" or "– text" (en-dash) at the very start of a
# line, optionally after leading whitespace. Used for PT-BR dialogue.
_EM_DASH_LINE_RE = re.compile(
    r"^[ \t]*[\u2014\u2013][ \t]+(?P<body>.+?)$",
    re.MULTILINE,
)


def _split_quoted(text: str) -> List[DialogueSpan]:
    """Split ``text`` on the first paired-quote style that matches.

    We pick a single style per chapter so we don't double-tag the same
    region (e.g. straight quotes nested inside curly ones).
    """
    if not text:
        return []

    chosen_open: str | None = None
    chosen_close: str | None = None
    for open_q, close_q in _PAIRED_QUOTES:
        if open_q in text and close_q in text:
            chosen_open = open_q
            chosen_close = close_q
            break

    if chosen_open is None or chosen_close is None:
        return [DialogueSpan(text=text, role="narrator")] if text.strip() else []

    spans: List[DialogueSpan] = []
    cursor = 0
    while cursor < len(text):
        open_idx = text.find(chosen_open, cursor)
        if open_idx < 0:
            tail = text[cursor:]
            if tail:
                spans.append(DialogueSpan(text=tail, role="narrator"))
            break
        # Narration before the quote.
        if open_idx > cursor:
            spans.append(DialogueSpan(text=text[cursor:open_idx], role="narrator"))
        close_idx = text.find(chosen_close, open_idx + len(chosen_open))
        if close_idx < 0:
            # Unbalanced — keep the rest as narrator, don't synthesise a
            # half-open quote with the wrong voice.
            spans.append(DialogueSpan(text=text[open_idx:], role="narrator"))
            break
        # Quoted body INCLUDING the punctuation. Listening tests showed
        # that swallowing the quote marks themselves produces a smoother
        # read because the character voice doesn't pronounce "aspas".
        spans.append(
            DialogueSpan(
                text=text[open_idx + len(chosen_open) : close_idx],
                role="character",
            )
        )
        cursor = close_idx + len(chosen_close)
    return spans


def _split_em_dash_lines(spans: Iterable[DialogueSpan]) -> List[DialogueSpan]:
    """Within each existing narrator span, route em-dash dialogue lines to
    the character voice. We do this *after* quote splitting so a quoted
    paragraph that happens to start with an em-dash isn't double-counted.
    """
    refined: List[DialogueSpan] = []
    for span in spans:
        if span.role == "character":
            refined.append(span)
            continue
        body = span.text
        cursor = 0
        for match in _EM_DASH_LINE_RE.finditer(body):
            start, end = match.span()
            body_text = match.group("body")
            # Body may continue past the match end; the regex stops at $
            # of the line, so only that line becomes character voice.
            if start > cursor:
                refined.append(
                    DialogueSpan(text=body[cursor:start], role="narrator"),
                )
            refined.append(DialogueSpan(text=body_text, role="character"))
            cursor = end
        if cursor < len(body):
            refined.append(DialogueSpan(text=body[cursor:], role="narrator"))
    return refined


def _coalesce(spans: Iterable[DialogueSpan]) -> List[DialogueSpan]:
    """Drop empty spans and merge adjacent ones that share a role.

    Coalescing matters: two narrator chunks back-to-back force two TTS
    requests with a tiny silence between them, which the listener hears
    as a stutter.
    """
    out: List[DialogueSpan] = []
    for span in spans:
        if not span.text.strip():
            continue
        if out and out[-1].role == span.role:
            merged = out[-1].text + span.text
            out[-1] = DialogueSpan(text=merged, role=span.role)
        else:
            out.append(span)
    return out


def split_into_dialogue_spans(text: str) -> List[DialogueSpan]:
    """Route ``text`` into ``narrator``/``character`` spans.

    The function is total — even malformed input (lone quotes, only
    narration, only dialogue) returns a non-empty list whose concatenated
    text recovers the original up to whitespace inside coalesced spans.
    Callers that want the original text byte-for-byte should not rely on
    this — only on role assignment.
    """
    if not text:
        return []
    quoted = _split_quoted(text)
    refined = _split_em_dash_lines(quoted)
    return _coalesce(refined)
