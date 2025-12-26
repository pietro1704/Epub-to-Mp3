from __future__ import annotations

import hashlib
import logging
from typing import Any, Iterable, List, Tuple

logger = logging.getLogger(__name__)

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
    chapters_list = list(chapters)
    total_chapters = len(chapters_list)
    deduplicated: List[Any] = []
    seen_hashes: set[str] = set()
    seen_prefixes: dict[str, int] = {}
    removed = 0
    removed_details: List[Tuple[str, str]] = []  # (chapter_name, reason)

    for idx, chapter in enumerate(chapters_list, 1):
        chapter_name = getattr(chapter, "name", None) or getattr(chapter, "display_name", None) or f"Chapter {idx}"
        payload = _extract_text_payload(chapter)
        normalized_len = len(payload)

        if normalized_len < max(0, min_chars):
            deduplicated.append(chapter)
            continue

        prefix = payload[:_PREFIX_SLICE]
        mark_duplicate = False
        duplicate_reason = ""

        if prefix:
            existing_len = seen_prefixes.get(prefix)
            if existing_len is not None and abs(existing_len - normalized_len) <= _LENGTH_TOLERANCE:
                mark_duplicate = True
                duplicate_reason = f"similar prefix ({normalized_len} vs {existing_len} chars)"

        digest = None
        if not mark_duplicate:
            digest = hashlib.sha1(payload.encode("utf-8", "ignore")).hexdigest()
            if digest in seen_hashes:
                mark_duplicate = True
                duplicate_reason = "identical content hash"

        if mark_duplicate:
            removed += 1
            removed_details.append((chapter_name, duplicate_reason))
            logger.info(f"Removing duplicate chapter '{chapter_name}': {duplicate_reason}")
            continue

        if digest is None:
            digest = hashlib.sha1(payload.encode("utf-8", "ignore")).hexdigest()
        seen_hashes.add(digest)
        if prefix:
            seen_prefixes[prefix] = normalized_len
        deduplicated.append(chapter)

    # Log summary and warn if too many chapters were removed
    if removed > 0:
        logger.info(f"Deduplication: {removed}/{total_chapters} chapters removed as duplicates")
        removal_rate = (removed / total_chapters) * 100 if total_chapters > 0 else 0
        if removal_rate > 20:  # Warn if more than 20% were removed
            logger.warning(
                f"⚠️  HIGH REMOVAL RATE: {removal_rate:.1f}% of chapters were removed! "
                f"This might indicate a problem. Removed chapters: {removed_details}"
            )

    return deduplicated, removed


__all__ = ["deduplicate_chapters_by_content", "MIN_DUPLICATE_CHARS"]
