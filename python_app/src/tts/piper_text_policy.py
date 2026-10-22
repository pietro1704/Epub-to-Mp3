"""Sentence chunking, reference-heavy planning and Piper text sanitation."""

from __future__ import annotations

import re
import unicodedata
from typing import List


def _split_text_into_chunks(text: str, max_chars: int) -> List[str]:
    """Split text into chunks at sentence boundaries, respecting max_chars."""
    if len(text) <= max_chars:
        return [text]

    chunks: List[str] = []
    remaining = text

    while remaining:
        if len(remaining) <= max_chars:
            chunks.append(remaining)
            break

        # Find the best split point near max_chars
        candidate = remaining[:max_chars]
        # Prefer splitting at sentence end (.!?\n)
        split_pos = -1
        for pattern in (r"[.!?]\s", r"\n"):
            for m in re.finditer(pattern, candidate):
                split_pos = m.end()
        # Fallback: split at last space
        if split_pos < max_chars // 2:
            last_space = candidate.rfind(" ")
            if last_space > max_chars // 2:
                split_pos = last_space + 1
        # Last resort: hard split
        if split_pos < max_chars // 2:
            split_pos = max_chars

        chunk = remaining[:split_pos].rstrip()
        if chunk:
            chunks.append(chunk)
        remaining = remaining[split_pos:].lstrip()

    return chunks


def _merge_small_chunks(chunks: List[str], max_chars: int, min_chars: int) -> List[str]:
    """Merge tiny adjacent chunks to reduce Piper process startup overhead."""
    if len(chunks) <= 1:
        return chunks

    merged: List[str] = []
    current = ""
    min_chars = max(1, min(min_chars, max_chars))

    for raw_chunk in chunks:
        chunk = raw_chunk.strip()
        if not chunk:
            continue
        candidate = f"{current} {chunk}".strip() if current else chunk
        if current and len(candidate) > max_chars:
            merged.append(current)
            current = chunk
            continue
        current = candidate
        if len(current) >= min_chars:
            merged.append(current)
            current = ""

    if current:
        if merged and len(current) < min_chars:
            tail = f"{merged[-1]} {current}".strip()
            if len(tail) <= max_chars:
                merged[-1] = tail
            else:
                merged.append(current)
        else:
            merged.append(current)

    return merged or chunks


def _is_reference_heavy_text(text: str) -> bool:
    """Detect end-matter style text that performs poorly with many tiny chunks."""
    if not text:
        return False
    lowered = text.lower()
    end_matter_keywords = (
        "bibliografia",
        "bibliography",
        "referências",
        "references",
        "créditos",
        "creditos",
        "credits",
        "notas",
        "notes",
        "posfácio",
        "posfacio",
        "afterword",
        "sobre o autor",
        "about the author",
    )
    if any(keyword in lowered for keyword in end_matter_keywords):
        return True

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) >= 8:
        short_lines = sum(1 for line in lines if len(line) <= 140)
        if short_lines / len(lines) >= 0.6:
            return True

    years = len(re.findall(r"\b(?:1[6-9]\d{2}|20\d{2})\b", text))
    semicolons = text.count(";")
    if years >= 8 and semicolons >= 6:
        return True

    return False


def _planned_piper_chunk_chars(text: str, base_chars: int) -> int:
    """Use larger chunks for reference-heavy end matter to avoid chunk explosion."""
    base_chars = max(1200, int(base_chars))
    if _is_reference_heavy_text(text):
        return min(6000, max(base_chars, int(base_chars * 1.75)))
    return base_chars


def _sanitize_text_for_piper(text: str) -> str:
    """Normalize text and drop problematic combining marks before Piper."""
    if not text:
        return ""
    normalized = unicodedata.normalize("NFC", text)
    # After NFC, most Latin accents are precomposed. Remaining isolated combining
    # marks tend to trigger Piper "missing phoneme" warnings and add heavy overhead.
    cleaned = "".join(ch for ch in normalized if unicodedata.category(ch) != "Mn")
    cleaned = re.sub(r"[ \t]{2,}", " ", cleaned)
    return cleaned.strip()
