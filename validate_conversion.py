#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Complete validation of a finished conversion (EPUB → MP3) with optional auto-fix.

Checks:
1) Original text (EPUB) vs cached text (parsed.txt)
2) Cached text (parsed.txt) vs text sent to TTS (pre-tts.txt)
3) Estimated text duration vs actual MP3 duration
4) Missing/duplicate/truncated segments or files

Optional (--auto-fix):
 - Reprocesses only problematic chapters to fix missing or divergent content.
"""

import asyncio
import hashlib
import os
import re
import sys
import unicodedata
from pathlib import Path
from typing import Dict, List, Tuple

# Add project to path
sys.path.insert(0, str(Path(__file__).parent))

from python_app.src.audio_validator import AudioValidator
from python_app.src.config import ConversionConfig
from python_app.src.converter import AudioConverter
from python_app.src.ebook_reader import EbookReader
from python_app.src.utils import FileManager, resolve_cache_root


def find_cache_dir(book_path: Path) -> Path:
    """Find cache directory for a book."""
    cache_root = Path(".cache")

    # Try to find by book title
    book_name = book_path.stem

    # Search for matching cache directories
    for cache_dir in cache_root.iterdir():
        if cache_dir.is_dir() and book_name.lower() in cache_dir.name.lower():
            # Look for engine subdirectories
            for engine_dir in cache_dir.iterdir():
                if engine_dir.is_dir() and (engine_dir / "text").exists():
                    return engine_dir
            # Try nested structure
            for subdir in cache_dir.rglob("text"):
                if subdir.is_dir():
                    return subdir.parent

    raise FileNotFoundError(f"Cache directory not found for {book_path.name}")


def load_epub_chapters(epub_path: Path) -> List[Tuple[object, str, str]]:
    """Load all chapters from EPUB."""
    print(f"📖 Reading EPUB: {epub_path.name}")
    reader = EbookReader(str(epub_path))
    try:
        from python_app.main import ConverterApplication

        app = ConverterApplication()
        preview_config = app.config.create_conversion_config(
            engine="edge",
            output_dir=str(Path.cwd() / "output"),
            book_title=reader.title,
            preserve_all_chapters=True,
        )
        preview_config.footnote_mode = "inline"
        preview_config.footnote_context_words = app.FOOTNOTE_CONTEXT_WORDS
        structure_items = app._generate_structure_items(reader, filter_chapters=False)
        structure_items = app._apply_text_transforms(structure_items, preview_config, reader)
        app._apply_structure_to_reader(reader, structure_items)
    except Exception as exc:
        print(f"⚠️  Validation fallback: failed to apply structure transforms ({exc})")

    chapters = reader.get_chapter_structure(preserve_all=True)

    result = []
    for i, chapter in enumerate(chapters, 1):
        # Use structured text to match cached parsed content
        text = chapter.text or ""
        # Use chapter.index (the label used in cache filenames, e.g. "4.1", "5.3")
        # instead of sequential i, so validation matches cache file names
        label = chapter.index if chapter.index is not None else i
        result.append((label, chapter.name, text))

    print(f"   ✅ Loaded {len(result)} chapters from EPUB")
    return result


def find_text_files(text_dirs: List[Path], chapter_num) -> Dict[str, Path]:
    """Find parsed and pre-tts text files for a chapter by numeric prefix."""
    for text_dir in text_dirs:
        if not text_dir.exists():
            continue
        files: Dict[str, Path] = {}
        for txt_file in text_dir.glob(f"{chapter_num} - *"):
            if txt_file.name.endswith("-parsed.txt"):
                files["parsed"] = txt_file
            elif txt_file.name.endswith("-pre-tts.txt"):
                files["pre_tts"] = txt_file
        if files:
            return files
    return {}


def find_text_files_by_title(text_dirs: List[Path], chapter_title: str) -> Dict[str, Path]:
    """Fallback: find parsed and pre-tts text files by matching chapter title."""
    target = normalize_title_key(chapter_title)
    for text_dir in text_dirs:
        if not text_dir.exists():
            continue
        files: Dict[str, Path] = {}
        for txt_file in text_dir.glob("*.txt"):
            stem = _strip_text_suffix(_strip_numeric_prefix(txt_file.stem))
            name_norm = normalize_title_key(stem)
            if target and target[:40] in name_norm:
                if txt_file.name.endswith("-parsed.txt"):
                    files.setdefault("parsed", txt_file)
                elif txt_file.name.endswith("-pre-tts.txt"):
                    files.setdefault("pre_tts", txt_file)
            if len(files) == 2:
                break
        if files:
            return files
    return {}


def resolve_cache_dir_with_text(cache_dir: Path) -> Path:
    """
    Some cache layouts nest engine names (e.g., edge/edge/text). Walk down one level
    to find a directory that contains 'text'.
    """
    if (cache_dir / "text").exists():
        return cache_dir
    try:
        children = [p for p in cache_dir.iterdir() if p.is_dir()]
    except FileNotFoundError:
        return cache_dir
    for child in children:
        if (child / "text").exists():
            return child
    return cache_dir


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


def build_cache_index(text_dirs: List[Path]) -> Dict[str, Dict[str, Path]]:
    """
    Build an index of parsed/pre-tts files keyed by normalized title (without numeric prefix).
    Prefer parsed files that have a sibling pre-tts with the same stem.
    """
    index: Dict[str, Dict[str, Path]] = {}
    pre_tts_stems: Dict[str, set[str]] = {}

    for text_dir in text_dirs:
        if not text_dir.exists():
            continue
        for txt_file in text_dir.glob("*.txt"):
            if not txt_file.name.endswith("-pre-tts.txt"):
                continue
            stem = _strip_numeric_prefix(txt_file.stem)
            stem = _strip_text_suffix(stem)
            norm_title = normalize_title_key(stem)
            pre_tts_stems.setdefault(norm_title, set()).add(stem)
            index.setdefault(norm_title, {})["pre_tts"] = txt_file

    for text_dir in text_dirs:
        if not text_dir.exists():
            continue
        for txt_file in text_dir.glob("*.txt"):
            if not txt_file.name.endswith("-parsed.txt"):
                continue
            stem = _strip_numeric_prefix(txt_file.stem)
            stem = _strip_text_suffix(stem)
            norm_title = normalize_title_key(stem)
            index.setdefault(norm_title, {})

            prefers = stem in pre_tts_stems.get(norm_title, set())
            if prefers or "parsed" not in index[norm_title]:
                index[norm_title]["parsed"] = txt_file
    return index


def build_mp3_index(output_dir: Path) -> Dict[str, Path]:
    """Index MP3 files keyed by normalized title (without numeric prefix)."""
    index: Dict[str, Path] = {}
    if not output_dir.exists():
        return index
    for mp3 in output_dir.glob("*.mp3"):
        stem = _strip_numeric_prefix(mp3.stem)
        norm = normalize_title_key(stem)
        index[norm] = mp3
    return index


def find_mp3_by_title(output_dir: Path, chapter_title: str) -> Path | None:
    """Find MP3 file by matching normalized title (ignores numeric prefix)."""
    if not output_dir.exists():
        return None

    target = normalize_title_key(_strip_numeric_prefix(chapter_title))
    best: Path | None = None
    for mp3 in output_dir.glob("*.mp3"):
        name_norm = normalize_title_key(_strip_numeric_prefix(mp3.stem))
        if target and target[:40] in name_norm:
            best = mp3
            break
    return best


def find_mp3_file(output_dir: Path, chapter_num: int) -> Path | None:
    """Find MP3 file for a chapter by numeric prefix (legacy)."""
    if not output_dir.exists():
        return None

    # Try exact match first
    for mp3 in output_dir.glob(f"{chapter_num}.*"):
        if mp3.suffix == ".mp3":
            return mp3

    # Try fuzzy match
    for mp3 in output_dir.glob(f"{chapter_num} - *.mp3"):
        return mp3

    return None


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


def normalize_title_key(text: str, limit: int = 80) -> str:
    """Normalize and shorten titles to improve matching with truncated filenames."""
    normalized = normalize_title(text)
    if limit:
        normalized = normalized[:limit].rstrip()
    return normalized


HTML_TAG_PATTERN = re.compile(r"<[^>]+>")
HTML_ENTITY_PATTERN = re.compile(r"&[a-zA-Z]+;|&#\d+;|&#x[0-9a-fA-F]+;")


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
    stem = _strip_text_suffix(_strip_numeric_prefix(path.stem))
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


def print_chapter_detail(
    chapter_num: int,
    title: str,
    epub_text: str,
    parsed_text: str | None,
    pretts_text: str | None,
    mp3_file: Path | None,
    validator: "AudioValidator",
) -> None:
    """Print detailed start/mid/end text comparison for a chapter."""
    epub_norm = normalize_text(epub_text) if epub_text else ""
    parsed_norm = normalize_text(parsed_text) if parsed_text else ""
    pretts_norm = normalize_text(strip_formatting_cues(pretts_text)) if pretts_text else ""

    epub_samples = _extract_samples(epub_text) if epub_text else ("", "", "")
    parsed_samples = _extract_samples(parsed_text) if parsed_text else ("", "", "")
    pretts_samples = _extract_samples(pretts_text) if pretts_text else ("", "", "")

    short_title = _truncate_for_display(title, 60)
    print(f"  📖 Cap {chapter_num} ({short_title}) [{len(epub_norm):,} chars]")

    section_names = ["START", "MIDDLE", "END"]
    connectors = ["├─", "├─", "├─"]

    for i, section in enumerate(section_names):
        epub_s = epub_samples[i]
        parsed_s = parsed_samples[i]
        pretts_s = pretts_samples[i]

        connector = connectors[i]
        print(f"  {connector} {section}:")

        epub_disp = _truncate_for_display(epub_s)
        print(f'  │  EPUB:   "{epub_disp}"')

        if parsed_text:
            parsed_disp = _truncate_for_display(parsed_s)
            p_match = _samples_match(epub_s, parsed_s, parsed_norm)
            print(f'  │  Parsed: "{parsed_disp}"')
        else:
            p_match = False
            print("  │  Parsed: (not found)")

        if pretts_text:
            pretts_disp = _truncate_for_display(pretts_s)
            t_match = _samples_match(epub_s, pretts_s, pretts_norm)
            print(f'  │  PreTTS: "{pretts_disp}"')
        else:
            t_match = True  # No pre-tts to compare
            print("  │  PreTTS: (not found)")

        if p_match and t_match:
            print("  │  Result: ✅ Match")
        elif p_match:
            print("  │  Result: ⚠️  PreTTS diverges")
        elif t_match:
            print("  │  Result: ⚠️  Parsed diverges")
        else:
            print("  │  Result: ❌ Mismatch")

    # MP3 info
    if mp3_file and mp3_file.exists():
        mp3_size_mb = mp3_file.stat().st_size / (1024 * 1024)
        try:
            duration = validator.get_audio_duration(mp3_file)
        except Exception:
            duration = None
        if isinstance(duration, (int, float)) and duration > 0:
            duration_min = duration / 60
            chars_per_min = int(len(epub_norm) / duration_min) if duration_min > 0 else 0
            print(
                f"  └─ 🎵 MP3: {mp3_size_mb:.1f} MB | {duration_min:.1f} min | ~{chars_per_min} chars/min"
            )
        else:
            print(f"  └─ 🎵 MP3: {mp3_size_mb:.1f} MB | duration unavailable")
    else:
        print("  └─ 🎵 MP3: (not found)")
    print()


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


def fix_output_filenames(output_dir: Path, cache_dir: Path | None = None) -> List[str]:
    """
    Rename output and cache files that contain HTML markup or illegal characters
    in their names. Scans output_dir, output_dir/text/, and cache_dir/text/.
    Returns a list of rename action strings.
    """
    import html

    renamed = []

    def _clean_stem(stem: str) -> str:
        # Unescape HTML entities (e.g. &amp; → &)
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
            if not contains_html_markup(stem):
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


def compare_texts(original: str, cached: str) -> Tuple[bool, int, str]:
    """
    Compare two texts and return (is_equal, diff_chars, description).
    """
    norm_orig = normalize_text(original)
    norm_cached = normalize_text(cached)

    if norm_orig == norm_cached:
        return True, 0, "Identical"

    diff_chars = len(norm_orig) - len(norm_cached)

    if diff_chars == 0:
        return False, diff_chars, "Content differs (same length)"

    # Find what's different
    if len(norm_cached) < len(norm_orig):
        # Text was removed
        return False, diff_chars, f"Missing {diff_chars} chars from cached (truncation)"
    else:
        # Text was added
        return False, diff_chars, f"Added {-diff_chars} chars to cached"


def validate_book(
    epub_path: Path,
    output_dir: Path | None = None,
    cache_dir: Path | None = None,
    duration_tolerance: float | None = None,
):
    """
    Validate complete book conversion.

    Args:
        duration_tolerance: Override for MP3 duration tolerance (0.0-1.0+).
            If None, uses adaptive defaults (0.40-0.50).
    """
    print("\n" + "=" * 70)
    print("🔍 VALIDAÇÃO COMPLETA DE CONVERSÃO EPUB → MP3")
    print("=" * 70 + "\n")

    # Find cache directory
    if cache_dir is None:
        try:
            cache_dir = find_cache_dir(epub_path)
            print(f"📁 Cache directory: {cache_dir}")
        except FileNotFoundError as e:
            print(f"❌ ERROR: {e}")
            return
    else:
        print(f"📁 Cache directory (provided): {cache_dir}")

    cache_dir = resolve_cache_dir_with_text(cache_dir)

    # Find output directory
    if output_dir is None:
        # Try to find output directory
        output_base = Path("output")
        for out_dir in output_base.rglob("*"):
            if out_dir.is_dir() and any(mp3.suffix == ".mp3" for mp3 in out_dir.glob("*")):
                output_dir = out_dir
                break

        if output_dir is None:
            print("❌ ERROR: Output directory not found")
            return

    print(f"📁 Output directory: {output_dir}\n")

    output_text_dir = output_dir / "text" if output_dir else None
    text_dirs = [
        path for path in (output_text_dir, cache_dir / "text") if path is not None and path.exists()
    ]
    cache_index = build_cache_index(text_dirs)
    mp3_index = build_mp3_index(output_dir)

    # Load EPUB chapters
    epub_chapters = load_epub_chapters(epub_path)

    # Validation statistics
    stats = {
        "total_chapters": len([c for c in epub_chapters if normalize_text(c[2])]),
        "missing_cache": 0,
        "text_mismatch": 0,
        "parsed_pretts_diff": 0,
        "missing_mp3": 0,
        "duration_mismatch": 0,
        "audio_duplicate": 0,
        "completo_size_mismatch": 0,
        "perfect": 0,
    }

    issues = []
    validator = AudioValidator()
    text_hashes: Dict[str, List[int]] = {}
    chapter_text_hash: Dict[object, str] = {}
    audio_hashes: Dict[str, Dict[str, object]] = {}

    print(
        f"{'Ch':<4} {'Status':<8} {'S/M/E':<7} {'%Text':<6} {'EPUB':<7} {'Parsed':<7} {'PreTTS':<7} {'MP3':<7} {'Issue'}"
    )
    print("-" * 90)

    sequential_num = 0  # Track sequential non-empty chapter number
    for epub_index, (chapter_label, chapter_title, epub_text) in enumerate(epub_chapters, 1):
        # Skip empty chapters (e.g., cover/blank pages) but keep index
        if not epub_text or not normalize_text(epub_text):
            continue
        sequential_num += 1
        # Use chapter_label (e.g. "4.1", "5.3") which matches cache filenames
        chapter_num = chapter_label
        status = "✅"
        issue_desc = ""
        # Track start/middle/end validation
        start_ok = True
        middle_ok = True
        end_ok = True
        # Track loaded texts for detail display
        _parsed_text_for_detail: str | None = None
        _pretts_text_for_detail: str | None = None
        text_pct = 100.0
        norm_title = normalize_title_key(_strip_numeric_prefix(chapter_title))
        leading_title = normalized_leading_text(epub_text)
        expected_titles = [t for t in (norm_title, leading_title) if t]

        if contains_html_markup(chapter_title):
            stats["text_mismatch"] += 1
            status = "❌"
            issue_desc = "HTML in title"
            issues.append(
                f"Chapter {chapter_num}: Chapter title contains HTML/markup: {chapter_title}"
            )

        # Find cached text files (prefer title-based mapping to avoid index mismatch)
        text_files = cache_index.get(norm_title, {})
        if not text_files:
            text_files = find_text_files_by_title(text_dirs, chapter_title)
        if not text_files and text_dirs:
            text_files = find_text_files(text_dirs, chapter_num)

        if not text_files:
            stats["missing_cache"] += 1
            status = "⚠️ "
            issue_desc = "No cache files"
            issues.append(f"Chapter {chapter_num}: Missing cache files")
        else:
            # Validate filenames align with EPUB titles/heading text
            for label, path in text_files.items():
                file_norm = normalized_file_title(path)
                if expected_titles and not any(titles_align(t, file_norm) for t in expected_titles):
                    stats["text_mismatch"] += 1
                    status = "❌"
                    issue_desc = (issue_desc + " Filename mismatch").strip()
                    issues.append(
                        f"Chapter {chapter_num} '{chapter_title}': {label} filename '{path.name}' does not match EPUB heading"
                    )
                if contains_html_markup(path.stem):
                    stats["text_mismatch"] += 1
                    status = "❌"
                    issue_desc = (issue_desc + " HTML in filename").strip()
                    issues.append(
                        f"Chapter {chapter_num}: {label} filename has HTML-like markup: {path.name}"
                    )

            # Check parsed.txt vs EPUB
            if "parsed" in text_files:
                parsed_text = text_files["parsed"].read_text(encoding="utf-8")
                _parsed_text_for_detail = parsed_text
                parsed_norm = normalize_text(parsed_text)

                if contains_html_markup(parsed_text):
                    stats["text_mismatch"] += 1
                    status = "❌"
                    issue_desc = (issue_desc + " HTML in parsed").strip()
                    issues.append(
                        f"Chapter {chapter_num}: Parsed text still contains HTML tags or markup"
                    )

                is_equal, diff, desc = compare_texts(epub_text, parsed_text)

                # Calculate text percentage
                epub_len = len(normalize_text(epub_text))
                parsed_len = len(parsed_norm)
                if epub_len > 0:
                    text_pct = (parsed_len / epub_len) * 100.0

                # Check middle section
                if epub_len > 400:  # Only check middle for long chapters
                    epub_middle_pos = epub_len // 2
                    parsed_middle_pos = parsed_len // 2
                    epub_middle = normalize_text(epub_text)[
                        max(0, epub_middle_pos - 90) : epub_middle_pos + 90
                    ]
                    parsed_middle = parsed_norm[
                        max(0, parsed_middle_pos - 90) : parsed_middle_pos + 90
                    ]
                    # Check if at least 50% of middle section words match
                    epub_middle_words = set(epub_middle.split())
                    parsed_middle_words = set(parsed_middle.split())
                    if epub_middle_words and parsed_middle_words:
                        overlap = len(epub_middle_words & parsed_middle_words)
                        total = max(len(epub_middle_words), len(parsed_middle_words))
                        if (overlap / total) < 0.5:
                            middle_ok = False

                parsed_mismatch_recorded = False
                if not is_equal:
                    stats["text_mismatch"] += 1
                    status = "❌"
                    issue_desc = (issue_desc + f" EPUB≠Parsed ({diff:+d})").strip()
                    parsed_mismatch_recorded = True
                    issues.append(f"Chapter {chapter_num}: EPUB text differs from parsed ({desc})")

                epub_start, epub_end = _sample_edges(epub_text)
                if epub_start and epub_start not in parsed_norm:
                    start_ok = False
                    if not parsed_mismatch_recorded:
                        stats["text_mismatch"] += 1
                        parsed_mismatch_recorded = True
                    status = "❌"
                    issue_desc = (issue_desc + " EPUB≠Parsed (start mismatch)").strip()
                    issues.append(f"Chapter {chapter_num}: Parsed missing start sample from EPUB")
                if epub_end and epub_end not in parsed_norm:
                    end_ok = False
                    if not parsed_mismatch_recorded:
                        stats["text_mismatch"] += 1
                        parsed_mismatch_recorded = True
                    status = "❌"
                    issue_desc = (issue_desc + " EPUB≠Parsed (end mismatch)").strip()
                    issues.append(f"Chapter {chapter_num}: Parsed missing end sample from EPUB")

            # Check parsed.txt vs pre-tts.txt
            if "parsed" in text_files and "pre_tts" in text_files:
                parsed_text = text_files["parsed"].read_text(encoding="utf-8")
                pretts_text = text_files["pre_tts"].read_text(encoding="utf-8")
                _pretts_text_for_detail = pretts_text
                if contains_html_markup(pretts_text):
                    stats["text_mismatch"] += 1
                    status = "❌"
                    issue_desc = (issue_desc + " HTML in pre-TTS").strip()
                    issues.append(
                        f"Chapter {chapter_num}: PreTTS text still contains HTML tags or markup"
                    )

                pretts_for_compare = strip_formatting_cues(pretts_text)
                parsed_norm = normalize_text(parsed_text)
                pretts_norm = normalize_text(pretts_for_compare)
                diff = len(parsed_norm) - len(pretts_norm)
                allowed_diff = max(50, int(len(parsed_norm) * 0.05))

                if abs(diff) > allowed_diff:
                    stats["parsed_pretts_diff"] += 1
                    status = "❌" if status == "✅" else status
                    issue_desc = (issue_desc + f" Parsed≠PreTTS ({diff:+d})").strip()
                    issues.append(
                        f"Chapter {chapter_num} '{chapter_title}': Parsed differs from PreTTS by {diff} chars - TEXT WAS MODIFIED BEFORE TTS!"
                    )
                    parsed_start, parsed_end = _sample_edges(parsed_text)
                    if parsed_start and parsed_start not in pretts_norm:
                        issue_desc = (issue_desc + " Parsed≠PreTTS (start mismatch)").strip()
                        issues.append(
                            f"Chapter {chapter_num}: PreTTS missing start sample from parsed"
                        )
                    if parsed_end and parsed_end not in pretts_norm:
                        issue_desc = (issue_desc + " Parsed≠PreTTS (end mismatch)").strip()
                        issues.append(
                            f"Chapter {chapter_num}: PreTTS missing end sample from parsed"
                        )

            # Track hashes for duplication detection
            base_text = text_files.get("pre_tts") or text_files.get("parsed")
            if base_text and base_text.exists():
                h = hash_text(base_text.read_text(encoding="utf-8"))
                text_hashes.setdefault(h, []).append(chapter_num)
                chapter_text_hash[chapter_num] = h

        # Find MP3 - try multiple strategies
        mp3_file = (
            mp3_index.get(norm_title)
            or find_mp3_by_title(output_dir, chapter_title)
            or find_mp3_file(output_dir, chapter_num)
            or find_mp3_file(output_dir, sequential_num)  # Try sequential number too
        )

        if mp3_file is None:
            stats["missing_mp3"] += 1
            if status == "✅":
                status = "❌"
            issue_desc = (issue_desc + " No MP3").strip()
            issues.append(f"Chapter {chapter_num}: Missing MP3 file")
        else:
            mp3_norm_title = normalized_file_title(mp3_file)
            if expected_titles and not any(
                titles_align(t, mp3_norm_title) for t in expected_titles
            ):
                stats["text_mismatch"] += 1
                if status == "✅":
                    status = "❌"
                issue_desc = (issue_desc + " MP3 name mismatch").strip()
                issues.append(
                    f"Chapter {chapter_num} '{chapter_title}': MP3 filename '{mp3_file.name}' does not match EPUB heading"
                )
            if contains_html_markup(mp3_file.stem):
                stats["text_mismatch"] += 1
                if status == "✅":
                    status = "❌"
                issue_desc = (issue_desc + " MP3 filename has HTML").strip()
                issues.append(
                    f"Chapter {chapter_num}: MP3 filename contains HTML/markup: {mp3_file.name}"
                )

            # Validate MP3 duration
            if "pre_tts" in text_files:
                pretts_text = text_files["pre_tts"].read_text(encoding="utf-8")
                pretts_len = len(normalize_text(pretts_text))
                if pretts_len >= 5000:
                    # Increased tolerance: Edge-TTS speed varies significantly
                    # Portuguese text + formatting cues make duration estimation less accurate
                    if duration_tolerance is not None:
                        tolerance = duration_tolerance
                    else:
                        tolerance = 0.50 if pretts_len < 10000 else 0.40
                    result = validator.validate_duration(pretts_text, mp3_file, tolerance=tolerance)

                    if not result.is_valid:
                        stats["duration_mismatch"] += 1
                        if status == "✅":
                            status = "⚠️ "
                        issue_desc = (
                            issue_desc + f" Duration({result.duration_diff_percent:+.0f}%)"
                        ).strip()
                        issues.append(
                            f"Chapter {chapter_num}: Duration mismatch ({result.duration_diff_percent:+.0f}%)"
                        )

            try:
                base_hash = chapter_text_hash.get(chapter_num)
                if base_hash and len(normalize_text(epub_text)) >= 400:
                    audio_hash = hash_file(mp3_file)
                    existing = audio_hashes.get(audio_hash)
                    if existing and existing.get("text_hash") != base_hash:
                        stats["audio_duplicate"] += 1
                        stats["text_mismatch"] += 1
                        if status == "✅":
                            status = "❌"
                        issue_desc = (issue_desc + " MP3 duplicate").strip()
                        issues.append(
                            "Duplicate audio detected between chapters: "
                            f"{existing.get('chapter')} and {chapter_num}"
                        )
                    else:
                        audio_hashes[audio_hash] = {
                            "chapter": chapter_num,
                            "text_hash": base_hash,
                        }
            except Exception as exc:
                issues.append(f"Chapter {chapter_num}: audio hash check failed ({exc})")

        if status == "✅":
            stats["perfect"] += 1

        # Build I/M/F status string
        imf_status = (
            f"{'✓' if start_ok else '✗'}/{'✓' if middle_ok else '✗'}/{'✓' if end_ok else '✗'}"
        )

        # Print row
        epub_len = len(epub_text) if epub_text else 0
        parsed_len = (
            len(text_files.get("parsed", Path()).read_text(encoding="utf-8"))
            if "parsed" in text_files
            else 0
        )
        pretts_len = (
            len(text_files.get("pre_tts", Path()).read_text(encoding="utf-8"))
            if "pre_tts" in text_files
            else 0
        )
        mp3_size = mp3_file.stat().st_size // 1024 if mp3_file else 0

        print(
            f"{chapter_num:<4} {status:<8} {imf_status:<7} {text_pct:>5.1f}% {epub_len:<7} {parsed_len:<7} {pretts_len:<7} {mp3_size:<7} {issue_desc}"
        )

        # Detailed text comparison display
        print_chapter_detail(
            chapter_num,
            chapter_title,
            epub_text,
            _parsed_text_for_detail,
            _pretts_text_for_detail,
            mp3_file,
            validator,
        )

    # Summary
    print("\n" + "=" * 70)
    print("📊 VALIDATION SUMMARY")
    print("=" * 70)
    print(f"Total chapters in EPUB: {stats['total_chapters']}")
    print(f"✅ Perfect chapters: {stats['perfect']}")
    if stats["perfect"] > 0:
        print("   → All with Start/Middle/End ✓✓✓ and 100% text (no missing characters)")
    print(f"⚠️  Missing cache: {stats['missing_cache']}")
    print(f"❌ EPUB ≠ Parsed: {stats['text_mismatch']}")
    print(f"⚠️  Parsed ≠ PreTTS: {stats['parsed_pretts_diff']}")
    print(f"❌ Missing MP3: {stats['missing_mp3']}")
    print(f"⚠️  Wrong duration: {stats['duration_mismatch']}")
    print(f"❌ Duplicate audio: {stats['audio_duplicate']}")

    # Check if we should suppress error messages (during auto-fix)
    suppress_errors = os.environ.get("SUPPRESS_VALIDATION_ERRORS", "").lower() == "true"

    if issues and not suppress_errors:
        print("\n" + "=" * 70)
        print("🔥 CRITICAL ISSUES FOUND")
        print("=" * 70)
        for issue in issues:
            print(f"  • {issue}")

    # Duplicate detection
    dup_groups = [ch_list for ch_list in text_hashes.values() if len(ch_list) > 1]
    if dup_groups:
        if not suppress_errors:
            print("\n⚠️  DUPLICATE CONTENT DETECTED BETWEEN CHAPTERS")
            for group in dup_groups:
                print(f"  • Chapters: {', '.join(map(str, group))}")
        stats["text_mismatch"] += len(dup_groups)
        issues.append("Duplicate content detected between chapters")

    audio_dupes = detect_duplicate_audio_files(output_dir)
    if audio_dupes:
        if not suppress_errors:
            print("\n⚠️  DUPLICATE AUDIO DETECTED BETWEEN FILES")
            for group in audio_dupes:
                labels = ", ".join(path.name for path in group)
                print(f"  • Files: {labels}")
        stats["audio_duplicate"] += len(audio_dupes)
        issues.append("Duplicate audio files detected (hash match)")

    # Validate full book text file
    print("\n" + "=" * 70)
    print("📖 FULL BOOK TEXT VALIDATION")
    print("=" * 70)

    full_book_files = list(output_dir.glob("*_completo.txt"))
    if not full_book_files:
        print("⚠️  Complete book text file not found")
        issues.append("Missing complete book text file")
    else:
        full_book_file = full_book_files[0]
        full_text = full_book_file.read_text(encoding="utf-8")
        full_text_norm = normalize_text(full_text)

        # Parse chapter titles from completo.txt to only count converted chapters
        # Format: "CAPÍTULO 1.0: 1.0 - Chapter 1 - ..."
        converted_titles = set()
        for match in re.finditer(
            r"^CAPÍTULO\s+\d+(?:\.\d+)?\s*:\s*(.+?)$", full_text, re.MULTILINE
        ):
            title = match.group(1).strip()
            # Normalize title for matching
            converted_titles.add(normalize_title_key(title))

        # Calculate expected total ONLY from chapters that were actually converted
        if converted_titles:
            total_epub_chars = 0
            for _, chapter_title, text in epub_chapters:
                if not text:
                    continue
                # Check if this chapter's title matches any converted chapter
                norm_title = normalize_title_key(chapter_title)
                if any(
                    norm_title in conv_title or conv_title in norm_title
                    for conv_title in converted_titles
                ):
                    total_epub_chars += len(normalize_text(text))
        else:
            # Fallback if no chapter headers found - use all chapters (old behavior)
            total_epub_chars = sum(
                len(normalize_text(text)) for _, _, text in epub_chapters if text
            )

        # Strip chapter headers from completo.txt for fair comparison
        # Headers are formatting added by converter, not EPUB content
        full_text_without_headers = "\n".join(
            line
            for line in full_text.split("\n")
            if not (line.strip().startswith("===") or line.strip().startswith("CAPÍTULO"))
        )
        full_book_chars = len(normalize_text(full_text_without_headers))

        print(f"📄 File: {full_book_file.name}")
        print(f"📊 Tamanho: {len(full_text):,} caracteres ({len(full_text_norm):,} normalizados)")
        print(f"📖 EPUB total: {total_epub_chars:,} caracteres normalizados")

        # Check if full text contains HTML
        if contains_html_markup(full_text):
            print("❌ Complete book text contains HTML tags!")
            issues.append("Complete book text contains HTML markup")
            stats["text_mismatch"] += 1

        # Check if size is reasonable (should be close to total)
        size_diff = abs(full_book_chars - total_epub_chars)
        tolerance = max(500, int(total_epub_chars * 0.05))  # 5% or 500 chars
        if size_diff > tolerance:
            print(
                f"⚠️  Size difference: {size_diff:,} characters ({size_diff / total_epub_chars * 100:.1f}%)"
            )
            stats["completo_size_mismatch"] += 1
            issues.append(f"Complete book text size differs by {size_diff} chars from EPUB total")
        else:
            print("✅ Complete book text is valid and complete")

    if not suppress_errors:
        print("=" * 70)
        if stats["parsed_pretts_diff"] > 0 or stats["text_mismatch"] > 0:
            print("❌ VALIDATION FAILED: Text was modified during conversion!")
            print("   The audio does NOT contain the complete text from the original EPUB.")
        elif stats["missing_mp3"] > 0:
            print("⚠️  VALIDATION INCOMPLETE: Some MP3 files are missing")
        elif stats["completo_size_mismatch"] > 0:
            print("⚠️  VALIDATION WITH WARNINGS: Complete book text size differs from EPUB")
        elif stats["perfect"] == stats["total_chapters"]:
            print("✅ VALIDATION PASSED: All chapters are intact!")
        else:
            print("⚠️  VALIDATION WITH WARNINGS: Check the details above")
        print("=" * 70 + "\n")

    return stats, issues


def auto_fix(
    epub_path: Path,
    output_dir: Path,
    engine: str = "edge",
    voice: str | None = None,
    cache_dir: Path | None = None,
):
    """
    Reprocess the entire book with clean cache to fix missing/divergent chapters.
    """
    print("\n🔄 AUTO-FIX: clearing cache and reconverting full book...")
    if cache_dir is None:
        safe_name = FileManager.sanitize_filename(epub_path.stem) or "book"
        cache_dir = resolve_cache_root() / safe_name
    reader = EbookReader(str(epub_path))
    config = ConversionConfig(
        engine=engine,
        voice=voice or "",
        output_dir=output_dir,
        cache_dir=cache_dir,
        book_title=epub_path.stem,
        preserve_all_chapters=True,
        force_reprocess=True,
        clear_cache=True,
        auto_validate_output=False,  # prevent infinite loops
        auto_fix_output=False,  # prevent infinite loops
    )
    converter = AudioConverter()
    asyncio.run(converter.convert(reader, config))


def extract_problem_chapters(issues: List[str]) -> List[str]:
    """Extract chapter numbers from validation issues (supports decimals like 1.1, 1.2)."""
    chapters: set[str] = set()
    for issue in issues:
        # Match "Chapter 9", "Chapter 43", "Chapter 1.1", "Chapter 1.2", etc.
        for match in re.finditer(r"\bChapter\s+(\d+(?:\.\d+)?)\b", issue):
            chapters.add(match.group(1))

        # Match "Chapters: 1, 2, 3" etc.
        cap_match = re.search(r"\bChapters?:\s*([0-9.,\s]+)", issue)
        if cap_match:
            for part in cap_match.group(1).split(","):
                part = part.strip()
                # Accept integers and decimals
                if re.match(r"^\d+(?:\.\d+)?$", part):
                    chapters.add(part)

        # Match duplicates: "between chapters: 9 and 43" or "between chapters: 1.1 and 1.2"
        dup_match = re.search(r"between chapters:\s*(\d+(?:\.\d+)?)\s+and\s+(\d+(?:\.\d+)?)", issue)
        if dup_match:
            chapters.add(dup_match.group(1))
            chapters.add(dup_match.group(2))

        # Match standalone numbers in critical messages (support decimals)
        if any(keyword in issue.lower() for keyword in ["missing mp3", "duplicate"]):
            # Extract all numbers that could be chapter references (integers or decimals)
            for num_match in re.finditer(r"(?:^|\s)(\d+(?:\.\d+)?)(?:\s|:|$)", issue):
                num_str = num_match.group(1)
                try:
                    num_val = float(num_str)
                    # Only add if it's a reasonable chapter number (1-999)
                    if 1 <= num_val <= 999:
                        chapters.add(num_str)
                except ValueError:
                    pass

    # Sort by converting to float for proper ordering (1, 1.1, 1.2, 2, 2.1, etc.)
    return sorted(chapters, key=lambda x: float(x))


def auto_fix_partial(
    epub_path: Path,
    output_dir: Path,
    chapters: List[int],
    *,
    engine: str = "edge",
    voice: str | None = None,
    cache_dir: Path | None = None,
) -> None:
    """Reprocess only the specified chapters."""
    if not chapters:
        auto_fix(epub_path, output_dir, engine=engine, voice=voice, cache_dir=cache_dir)
        return

    print(f"\n🔄 AUTO-FIX: reconverting {len(chapters)} chapter(s)...")
    if cache_dir is None:
        safe_name = FileManager.sanitize_filename(epub_path.stem) or "book"
        cache_dir = resolve_cache_root() / safe_name

    # Read EPUB to map chapter numbers to indices
    reader = EbookReader(str(epub_path))
    try:
        from python_app.main import ConverterApplication

        app = ConverterApplication()
        preview_config = app.config.create_conversion_config(
            engine=engine,
            output_dir=str(output_dir),
            book_title=reader.title,
            preserve_all_chapters=True,
        )
        preview_config.footnote_mode = "inline"
        preview_config.footnote_context_words = app.FOOTNOTE_CONTEXT_WORDS
        structure_items = app._generate_structure_items(reader, filter_chapters=False)
        structure_items = app._apply_text_transforms(structure_items, preview_config, reader)
        app._apply_structure_to_reader(reader, structure_items)
    except Exception as exc:
        print(f"⚠️  Auto-fix: failed to apply structure transforms ({exc})")

    all_chapters = reader.get_chapter_structure(preserve_all=True)

    # Map epub_index (1-based position) to chapter indices
    chapter_indices = []
    sequential_num = 0
    for epub_idx, chapter in enumerate(all_chapters, 1):
        text = chapter.text or ""
        if not text or not normalize_text(text):
            continue
        sequential_num += 1
        if epub_idx in chapters:
            # Use chapter.index (structured index like "4.1") or sequential number
            idx = getattr(chapter, "index", sequential_num)
            chapter_indices.append(str(idx))
            print(f"   → Chapter {epub_idx} (index {idx}): {chapter.name[:60]}")

    if not chapter_indices:
        print("⚠️  No valid chapters found to reconvert")
        return

    config = ConversionConfig(
        engine=engine,
        voice=voice or "",
        output_dir=output_dir,
        cache_dir=cache_dir,
        book_title=epub_path.stem,
        preserve_all_chapters=True,
        force_reprocess=True,
        clear_cache=False,
        auto_validate_output=False,  # prevent infinite loops
        auto_fix_output=False,  # prevent infinite loops
    )
    config.extra["chapter_whitelist"] = ",".join(chapter_indices)
    converter = AudioConverter()
    asyncio.run(converter.convert(reader, config))


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Validate EPUB → MP3 conversion integrity")
    parser.add_argument("epub_file", type=Path, help="Path to EPUB file")
    parser.add_argument("--output-dir", type=Path, help="Output directory with MP3s")
    parser.add_argument(
        "--auto-fix", action="store_true", help="Reconvert entire book if issues found"
    )
    parser.add_argument(
        "--engine", default="edge", help="TTS engine for auto-fix (e.g.: edge, kokoro, piper)"
    )
    parser.add_argument("--voice", default=None, help="TTS voice (optional) for auto-fix")

    args = parser.parse_args()

    if not args.epub_file.exists():
        print(f"❌ ERROR: File not found: {args.epub_file}")
        sys.exit(1)

    stats, issues = validate_book(args.epub_file, args.output_dir)

    if args.auto_fix and (issues or stats["missing_mp3"] or stats["text_mismatch"]):
        out_dir = args.output_dir
        if out_dir is None:
            out_dir = Path("output") / args.epub_file.stem
        auto_fix(args.epub_file, out_dir, engine=args.engine, voice=args.voice)
        print("\n✅ Auto-fix completed. Re-running validation...\n")
        validate_book(args.epub_file, out_dir)
