"""Text comparison rules shared by conversion integrity checks."""

import hashlib
import re
import unicodedata
from pathlib import Path
from typing import Tuple

_FILENAME_HASH_SUFFIX_RE = re.compile(r"\s*\[[0-9a-f]{8,16}\]\s*$", re.IGNORECASE)
HTML_TAG_PATTERN = re.compile(r"<[^>]+>")
HTML_ENTITY_PATTERN = re.compile(r"&[a-zA-Z]+;|&#\d+;|&#x[0-9a-fA-F]+;")


def _strip_numeric_prefix(name: str) -> str:
    """Remove leading numeric prefix like '001 - ' or '3.0 - ' from filenames."""
    pattern = re.compile(r"^\d+(?:\.\d+)?[\s._-]+")
    cleaned = name
    while True:
        updated = pattern.sub("", cleaned)
        if updated == cleaned:
            return cleaned
        cleaned = updated


def _strip_text_suffix(name: str) -> str:
    """Remove trailing '-parsed' or '-pre-tts' suffix from text filenames."""
    return re.sub(r"-(parsed|pre-tts)$", "", name, flags=re.IGNORECASE).strip()


def _strip_hash_marker(name: str) -> str:
    return _FILENAME_HASH_SUFFIX_RE.sub("", name).strip()


def normalize_text(text: str) -> str:
    """Normalize text for comparison."""
    # Remove extra whitespace
    text = re.sub(r"\s+", " ", text)
    # Remove leading/trailing whitespace
    text = text.strip()
    return text


def normalize_title(text: str) -> str:
    """Normalize a title or filename for matching across cache/output variations."""
    text = normalize_text(text)
    text = text.replace("_", " ")
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)
    text = "".join(
        ch for ch in unicodedata.normalize("NFKD", text) if not unicodedata.combining(ch)
    )
    text = re.sub(r"\s+", " ", text).strip().lower()
    return text


def normalize_title_key(text: str, limit: int = 160) -> str:
    """Normalize and shorten titles to improve matching with truncated filenames.

    The limit was raised from 80 to 160 because hierarchical chapter prefixes
    (e.g. ``9.11 - Parte 7: Matthew Rose Sorensen - ...``) can push the EPUB
    title past 80 chars in the converted filename, breaking substring match
    in ``validate_book`` and producing spurious "Missing cache files" alerts.
    """
    normalized = normalize_title(text)
    if limit:
        normalized = normalized[:limit].rstrip()
    return normalized


def contains_html_markup(text: str | None) -> bool:
    """Detect if text still contains HTML tags or markup."""
    if not text:
        return False
    # Check for HTML tags
    if HTML_TAG_PATTERN.search(text):
        return True
    # Check for HTML entities (except common safe ones)
    entities = HTML_ENTITY_PATTERN.findall(text)
    # Allow common safe entities that might be intentional
    safe_entities = {"&amp;", "&lt;", "&gt;", "&quot;", "&apos;", "&#39;", "&#34;"}
    for entity in entities:
        if entity not in safe_entities:
            return True
    return False


def normalized_file_title(path: Path) -> str:
    """Normalize a filename (mp3/txt) to compare with chapter titles."""
    stem = _strip_hash_marker(_strip_text_suffix(_strip_numeric_prefix(path.stem)))
    return normalize_title_key(stem)


def normalized_leading_text(text: str, limit: int = 120) -> str:
    """Normalize the leading portion of chapter text to validate filename alignment."""
    cleaned = HTML_TAG_PATTERN.sub(" ", text or "")
    cleaned = normalize_text(cleaned)
    if not cleaned:
        return ""
    return normalize_title_key(cleaned[:limit])


def titles_align(expected: str, candidate: str) -> bool:
    """Check if two normalized title fragments refer to the same chapter."""
    if not expected or not candidate:
        return False
    return (
        expected.startswith(candidate)
        or candidate.startswith(expected)
        or expected in candidate
        or candidate in expected
    )


def _sample_edges(text: str, size: int = 180) -> Tuple[str, str]:
    """Return normalized start/end samples for integrity checks."""
    normalized = normalize_text(text)
    if len(normalized) <= size * 2:
        return normalized, normalized
    return normalized[:size], normalized[-size:]


def _extract_samples(text: str, sample_size: int = 200) -> Tuple[str, str, str]:
    """Extract start, middle, end samples from normalized text."""
    norm = normalize_text(text)
    if not norm:
        return "", "", ""
    start = norm[:sample_size]
    mid_pos = len(norm) // 2
    middle = norm[max(0, mid_pos - sample_size // 2) : mid_pos + sample_size // 2]
    end = norm[-sample_size:]
    return start, middle, end


def _truncate_for_display(text: str, max_len: int = 78) -> str:
    """Truncate text for display with ellipsis."""
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."


def _samples_match(epub_sample: str, other_sample: str, other_full: str) -> bool:
    """Check if epub sample matches: positional word overlap or containment."""
    if not epub_sample:
        return True
    epub_words = set(epub_sample.lower().split())
    other_words = set(other_sample.lower().split())
    if epub_words and other_words:
        overlap = len(epub_words & other_words) / max(len(epub_words), len(other_words))
        if overlap >= 0.8:
            return True
    # Containment fallback
    return epub_sample.lower() in other_full.lower()


def strip_formatting_cues(text: str) -> str:
    """Remove audible formatting cue phrases from pre-TTS text."""
    if not text:
        return ""
    try:
        from python_app.src.text_formatting import TextFormattingProcessor

        phrases: set[str] = set()
        for locale_map in TextFormattingProcessor.CUE_LABELS.values():
            for start, end in locale_map.values():
                phrases.add(start)
                phrases.add(end)
        phrases.update(TextFormattingProcessor.FOOTNOTE_END_PHRASES)
    except Exception:
        return text

    cleaned = text
    for phrase in sorted(phrases, key=len, reverse=True):
        cleaned = re.sub(re.escape(phrase), "", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned


def hash_text(text: str) -> str:
    """Return stable hash for duplicate detection."""
    return hashlib.md5(normalize_text(text).encode("utf-8")).hexdigest()


def compare_texts(original: str, cached: str) -> Tuple[bool, int, str]:
    """
    Compare two texts and return (is_equal, diff_chars, description).

    Treats a per-chapter divergence under 1% (or 200 chars, whichever is
    larger) as equivalent. This absorbs noise from footnote rendering,
    whitespace collapsing, and structural-cue prepends — none of which
    indicate audio loss.
    """
    norm_orig = normalize_text(original)
    norm_cached = normalize_text(cached)

    if norm_orig == norm_cached:
        return True, 0, "Identical"

    diff_chars = len(norm_orig) - len(norm_cached)

    if diff_chars == 0:
        return False, diff_chars, "Content differs (same length)"

    tolerance = max(200, int(len(norm_orig) * 0.01))
    if abs(diff_chars) <= tolerance:
        return True, diff_chars, f"≈Match (Δ {diff_chars:+d} chars within {tolerance})"

    # Find what's different
    if len(norm_cached) < len(norm_orig):
        # Text was removed
        return False, diff_chars, f"Missing {diff_chars} chars from cached (truncation)"
    else:
        # Text was added
        return False, diff_chars, f"Added {-diff_chars} chars to cached"
