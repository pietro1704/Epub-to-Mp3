from __future__ import annotations

import hashlib
from typing import Any, Iterable, List, Tuple

MIN_DUPLICATE_CHARS = 400
_PREFIX_SLICE = 2000
_LENGTH_TOLERANCE = 120


def _extract_text_payload(candidate: Any) -> str:
    """Return a normalized text payload for any chapter-like object."""
    for attr in ("speech_text", "text_override", "text"):
        value = getattr(candidate, attr, None)
        if value:
            return " ".join(str(value).split())
    chapter = getattr(candidate, "chapter", None)
    if chapter is not None:
        for attr in ("speech_text", "text"):
            value = getattr(chapter, attr, None)
            if value:
                return " ".join(str(value).split())
    return ""


def deduplicate_chapters_by_content(
    chapters: Iterable[Any],
    *,
    min_chars: int = MIN_DUPLICATE_CHARS,
) -> Tuple[List[Any], int]:
    """Remove chapters with identical long-form text content."""
    deduplicated: List[Any] = []
    seen_hashes: set[str] = set()
    seen_prefixes: dict[str, int] = {}
    removed = 0
    for chapter in chapters:
        payload = _extract_text_payload(chapter)
        normalized_len = len(payload)
        if normalized_len < max(0, min_chars):
            deduplicated.append(chapter)
            continue
        prefix = payload[:_PREFIX_SLICE]
        mark_duplicate = False
        if prefix:
            existing_len = seen_prefixes.get(prefix)
            if existing_len is not None and abs(existing_len - normalized_len) <= _LENGTH_TOLERANCE:
                mark_duplicate = True
        digest = None
        if not mark_duplicate:
            digest = hashlib.sha1(payload.encode("utf-8", "ignore")).hexdigest()
            if digest in seen_hashes:
                mark_duplicate = True
        if mark_duplicate:
            removed += 1
            continue
        if digest is None:
            digest = hashlib.sha1(payload.encode("utf-8", "ignore")).hexdigest()
        seen_hashes.add(digest)
        if prefix:
            seen_prefixes[prefix] = normalized_len
        deduplicated.append(chapter)
    return deduplicated, removed


__all__ = ["deduplicate_chapters_by_content", "MIN_DUPLICATE_CHARS"]
