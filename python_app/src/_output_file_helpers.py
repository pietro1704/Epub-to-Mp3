# -*- coding: utf-8 -*-
"""Pure helpers extracted from _OutputFileMixin for standalone testing."""

from __future__ import annotations

import re
from pathlib import Path


def coerce_chapter_index(raw: object, fallback: int) -> int:
    if raw is None:
        return fallback
    try:
        if isinstance(raw, str):
            text = raw.strip()
            if not text:
                return fallback
            if text.replace(".", "", 1).isdigit():
                raw = float(text) if "." in text else int(text)
            else:
                return fallback
        value = int(raw)
    except Exception:
        try:
            value = int(float(raw))  # type: ignore[arg-type]
        except Exception:
            return fallback
    return value if value > 0 else fallback


def sample_edges(text: str, size: int = 180) -> tuple[str, str]:
    normalized = re.sub(r"\s+", " ", text or "").strip()
    if len(normalized) <= size * 2:
        return normalized, normalized
    return normalized[:size], normalized[-size:]


def title_from_filename(mp3_path: Path) -> str:
    stem = mp3_path.stem
    candidate = stem
    if " - " in stem:
        parts = stem.split(" - ", 1)
        if len(parts) == 2 and parts[0].isdigit():
            candidate = parts[1]
    else:
        parts = stem.split("_", 1)
        if len(parts) == 2 and parts[0].isdigit():
            candidate = parts[1]
        candidate = candidate.replace("_", " ")
    candidate = candidate.strip()
    return candidate or mp3_path.name
