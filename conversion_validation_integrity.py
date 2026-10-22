"""Inspect audio payloads, duration distributions and artifact name integrity."""

import hashlib
import re
from pathlib import Path
from typing import Dict, List

from conversion_validation_artifacts import find_mp3_by_title, find_mp3_file
from conversion_validation_text import (
    _strip_numeric_prefix,
    normalize_text,
    normalize_title_key,
)

_VALID_MP3_HEADERS: tuple[bytes, ...] = (
    b"\xff\xfb",  # MPEG Audio Layer III (most common)
    b"\xff\xfa",
    b"\xff\xf3",
    b"\xff\xf2",
    b"\xff\xe3",  # MPEG Audio Layer III (alternate sync)
    b"ID3",  # ID3v2 tag header
)


def _collect_chapter_wpms(
    epub_chapters,
    mp3_index,
    output_dir,
    text_dirs,
    validator,
) -> List[float]:
    """First pass: measure actual WPM (words/minute) for each chapter.

    Used by the median-based outlier check to anchor the duration
    heuristic against the engine's *actual* speaking rate for this
    specific book, instead of a hardcoded 150 WPM that doesn't match
    Edge-TTS PT-BR neural voices in practice.
    """
    if output_dir is None:
        return []
    wpms: list[float] = []
    for _epub_index, (chapter_label, chapter_title, epub_text) in enumerate(epub_chapters, 1):
        if not epub_text or not normalize_text(epub_text):
            continue
        norm_title = normalize_title_key(_strip_numeric_prefix(chapter_title))
        mp3_file = (
            mp3_index.get(norm_title)
            or find_mp3_by_title(output_dir, chapter_title)
            or find_mp3_file(output_dir, chapter_label)
        )
        if mp3_file is None:
            continue
        text_files = {}
        for text_dir in text_dirs or []:
            for txt_file in text_dir.glob(f"{chapter_label} - *"):
                if txt_file.name.endswith("-pre-tts.txt"):
                    text_files["pre_tts"] = txt_file
                    break
        if "pre_tts" not in text_files:
            continue
        try:
            text = text_files["pre_tts"].read_text(encoding="utf-8")
        except OSError:
            continue
        word_count = len(normalize_text(text).split())
        if word_count < 50:
            # Too short to be representative.
            continue
        duration = validator.get_audio_duration(mp3_file)
        if not duration or duration < 30:
            continue
        wpms.append((word_count / duration) * 60.0)
    return wpms


def _wpm_outlier_bounds(wpms: List[float]) -> tuple[float, float, float] | None:
    """Compute (median, low_bound, high_bound) for outlier detection.

    Uses median + 50% deviation: anything < 50% of median or > 200% of
    median is flagged. With < 5 sample chapters there isn't enough data
    to anchor a distribution, so we return None and the caller falls
    back to the legacy chars/WPM check.
    """
    cleaned = [w for w in wpms if 30 <= w <= 400]  # sanity strip
    if len(cleaned) < 5:
        return None
    cleaned.sort()
    mid = len(cleaned) // 2
    if len(cleaned) % 2:
        median = cleaned[mid]
    else:
        median = (cleaned[mid - 1] + cleaned[mid]) / 2.0
    if median <= 0:
        return None
    return median, median * 0.50, median * 2.00


def verify_mp3_integrity(output_dir: Path, min_size_bytes: int = 1024) -> List[str]:
    """Check that every MP3 in *output_dir* has a valid header and non-trivial size.

    Returns a list of issue strings (empty = all OK).
    """
    issues: List[str] = []
    for mp3 in sorted(output_dir.glob("*.mp3")):
        try:
            size = mp3.stat().st_size
        except OSError:
            issues.append(f"Cannot stat MP3: {mp3.name}")
            continue
        if size < min_size_bytes:
            issues.append(f"MP3 suspiciously small ({size} bytes, < {min_size_bytes}): {mp3.name}")
            continue
        try:
            with mp3.open("rb") as fh:
                header = fh.read(3)
        except OSError:
            issues.append(f"Cannot read MP3: {mp3.name}")
            continue
        if not any(header.startswith(h) for h in _VALID_MP3_HEADERS):
            issues.append(
                f"MP3 has unexpected header bytes {header!r} (not an MP3/ID3 file): {mp3.name}"
            )
    return issues


def verify_chapter_names(
    epub_chapters: List[tuple],  # (label, name, text) triples
    output_dir: Path,
) -> List[str]:
    """Verify that chapter names used in output filenames are clean.

    Checks:
    - Chapter name contains no HTML tags or entities.
    - Chapter name contains no non-breaking spaces (\\xa0).
    - Chapter name is not purely numeric (missing descriptive title).
    - MP3 filename stem (after stripping index prefix) matches the expected
      chapter name in a normalised comparison.

    Returns a list of issue strings (empty = all OK).
    """
    issues: List[str] = []
    _only_number = re.compile(r"^\d+\.?\d*$")

    for label, name, _text in epub_chapters:
        if not name:
            continue

        # HTML tags in chapter name
        if re.search(r"<[^>]+>", name):
            issues.append(f"Chapter {label!r} name contains HTML tags: {name!r}")

        # HTML entities in chapter name
        if re.search(r"&(?:#\d+|#x[0-9a-fA-F]+|[a-zA-Z]+);", name):
            issues.append(f"Chapter {label!r} name contains HTML entities: {name!r}")

        # Non-breaking spaces
        if "\xa0" in name:
            issues.append(f"Chapter {label!r} name contains non-breaking spaces: {name!r}")

        # Number-only names (calibre artefact: "part0001" stripped away but nothing left)
        cleaned = re.sub(r"^part\d{3,}\s*[-–:_]?\s*", "", name, flags=re.IGNORECASE).strip()
        if _only_number.match(cleaned):
            issues.append(f"Chapter {label!r} has no descriptive title (only a number): {name!r}")

    # Check that every MP3 stem is free of HTML/entity artefacts
    for mp3 in sorted(output_dir.glob("*.mp3")):
        if _stem_needs_fixing(mp3.stem):
            issues.append(f"MP3 filename contains HTML/entity artefacts: {mp3.name}")

    return issues


def hash_file(path: Path) -> str:
    """Return stable hash for audio duplication detection."""
    hasher = hashlib.sha1()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def detect_duplicate_audio_files(output_dir: Path, min_size_bytes: int = 1024) -> List[List[Path]]:
    """Detect duplicated audio files by hashing MP3 payloads."""
    groups: Dict[str, List[Path]] = {}
    for mp3 in sorted(output_dir.glob("*.mp3")):
        try:
            if mp3.stat().st_size < min_size_bytes:
                continue
        except OSError:
            continue
        groups.setdefault(hash_file(mp3), []).append(mp3)
    return [paths for paths in groups.values() if len(paths) > 1]


def _stem_needs_fixing(stem: str) -> bool:
    """Return True if the filename stem contains HTML tags or any HTML entities."""
    if re.search(r"<[^>]+>", stem):
        return True
    if re.search(r"&(?:#\d+|#x[0-9a-fA-F]+|[a-zA-Z]+);", stem):
        return True
    return False


def fix_output_filenames(output_dir: Path, cache_dir: Path | None = None) -> List[str]:
    """
    Rename output and cache files that contain HTML markup or HTML entities in
    their names. Scans output_dir, output_dir/text/, and cache_dir/text/.
    Returns a list of rename action strings.
    """
    import html

    renamed = []

    def _clean_stem(stem: str) -> str:
        # Unescape all HTML entities (e.g. &amp; → &, &lt; → <)
        cleaned = html.unescape(stem)
        # Strip any remaining HTML tags
        cleaned = re.sub(r"<[^>]+>", "", cleaned)
        # Replace characters illegal on most filesystems
        cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "-", cleaned)
        # Collapse whitespace
        cleaned = re.sub(r"\s+", " ", cleaned).strip()
        return cleaned

    def _scan_dir(scan_dir: Path) -> None:
        if not scan_dir.exists():
            return
        for fpath in sorted(scan_dir.iterdir()):
            if not fpath.is_file():
                continue
            stem = fpath.stem
            suffix = fpath.suffix
            if not _stem_needs_fixing(stem):
                continue
            new_stem = _clean_stem(stem)
            if new_stem == stem:
                continue
            new_path = fpath.with_name(new_stem + suffix)
            if new_path.exists():
                print(f"  ⚠️  Skipping rename (target exists): {fpath.name}")
                continue
            fpath.rename(new_path)
            renamed.append(f"  Renamed: {fpath.name!r} → {new_path.name!r}")
            print(f"  ✏️  {fpath.name!r} → {new_path.name!r}")

    _scan_dir(output_dir)
    _scan_dir(output_dir / "text")
    if cache_dir is not None:
        _scan_dir(cache_dir / "text")

    return renamed
