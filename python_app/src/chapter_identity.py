"""Deterministic chapter identity helpers for conversion telemetry."""

from __future__ import annotations

import hashlib
import unicodedata
from collections import defaultdict
from typing import Any, Iterable


def _normalized(value: object) -> str:
    text = unicodedata.normalize("NFKC", str(value or ""))
    return " ".join(text.split()).strip()


def chapter_label(chapter: Any, fallback_index: int) -> str:
    """Return the original hierarchical TOC label without numeric coercion."""
    raw = getattr(chapter, "index", None)
    label = _normalized(raw)
    return label or str(fallback_index)


def chapter_name(chapter: Any, fallback_index: int) -> str:
    """Return a stable human-readable chapter name."""
    name = _normalized(getattr(chapter, "name", None))
    return name or f"Chapter {chapter_label(chapter, fallback_index)}"


def chapter_source_path(chapter: Any) -> str:
    """Return the source document/fragment used to distinguish chapters."""
    return _normalized(getattr(chapter, "source_path", None))


def _identity_seed(chapter: Any, fallback_index: int) -> str:
    return "\x1f".join(
        (
            chapter_source_path(chapter),
            chapter_label(chapter, fallback_index),
            chapter_name(chapter, fallback_index),
        )
    )


def build_chapter_id(chapter: Any, fallback_index: int, occurrence: int = 1) -> str:
    """Build a deterministic ID independent of worker/queue order."""
    seed = _identity_seed(chapter, fallback_index)
    digest = hashlib.sha256(f"{seed}\x1f{max(1, occurrence)}".encode("utf-8")).hexdigest()[:16]
    return f"ch-{digest}-{max(1, occurrence)}"


def assign_chapter_identities(chapters: Iterable[Any]) -> list[Any]:
    """Attach deterministic ``stable_id`` values to chapter objects in place."""
    assigned = chapters if isinstance(chapters, list) else list(chapters)
    occurrences: defaultdict[str, int] = defaultdict(int)
    for fallback_index, chapter in enumerate(assigned, 1):
        existing = _normalized(getattr(chapter, "stable_id", None))
        if existing:
            continue
        seed = _identity_seed(chapter, fallback_index)
        occurrences[seed] += 1
        setattr(chapter, "stable_id", build_chapter_id(chapter, fallback_index, occurrences[seed]))
    return assigned


def chapter_identity_fields(chapter: Any, fallback_index: int) -> dict[str, str]:
    """Return common telemetry fields for one chapter."""
    identity = _normalized(getattr(chapter, "stable_id", None))
    if not identity:
        identity = build_chapter_id(chapter, fallback_index)
    return {
        "chapter_id": identity,
        "chapter_label": chapter_label(chapter, fallback_index),
        "chapter_name": chapter_name(chapter, fallback_index),
        "chapter_source_path": chapter_source_path(chapter),
    }
