from __future__ import annotations

import hashlib
import logging
from typing import Any, Iterable, List, Tuple

logger = logging.getLogger(__name__)

# Conservative deduplication: only removes chapters with EXACT identical content
# Prefix-based fuzzy matching is disabled to prevent false positives
MIN_DUPLICATE_CHARS = 400  # Only check chapters with 400+ chars
_PREFIX_SLICE = 2000  # Not used anymore
_LENGTH_TOLERANCE = 5  # Not used anymore


def _extract_text_payload(candidate: Any) -> str:
    """Return a normalized text payload for any chapter-like object.

    Prefers text_override > text > speech_text to avoid false positives
    from shared speech_text between parent/child chapters.
    """
    # First try text_override and text (more specific)
    for attr in ("text_override", "text"):
        value = getattr(candidate, attr, None)
        if value:
            return " ".join(str(value).split())

    # Fall back to speech_text only if nothing else available
    value = getattr(candidate, "speech_text", None)
    if value:
        return " ".join(str(value).split())

    # Try nested chapter object
    chapter = getattr(candidate, "chapter", None)
    if chapter is not None:
        for attr in ("text_override", "text", "speech_text"):
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
    deduplicated: List[Any] = []
    seen_hashes: set[str] = set()
    removed = 0
    removed_details: List[Tuple[str, str]] = []  # (chapter_name, reason)

    for idx, chapter in enumerate(chapters_list, 1):
        chapter_name = (
            getattr(chapter, "name", None)
            or getattr(chapter, "display_name", None)
            or f"Chapter {idx}"
        )
        payload = _extract_text_payload(chapter)
        normalized_len = len(payload)

        # Skip deduplication for chapters below threshold
        if normalized_len < max(0, min_chars):
            deduplicated.append(chapter)
            continue

        # ONLY check for exact content hash duplicates (no prefix checking)
        # This prevents false positives from similar but different chapters
        digest = hashlib.sha1(payload.encode("utf-8", "ignore")).hexdigest()
        if digest in seen_hashes:
            # Exact duplicate found
            removed += 1
            removed_details.append((chapter_name, "identical content"))
            # Silently skip - no logging to avoid noise
            continue

        # Not a duplicate - keep it
        seen_hashes.add(digest)
        deduplicated.append(chapter)

    # No logging - deduplication happens silently
    return deduplicated, removed


__all__ = ["deduplicate_chapters_by_content", "MIN_DUPLICATE_CHARS"]
