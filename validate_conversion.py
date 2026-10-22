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
import re
import sys
from pathlib import Path
from typing import List, Tuple

# Add project to path independently of the caller's working directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from conversion_validation_artifacts import (
    build_cache_index as build_cache_index,
    build_mp3_index as build_mp3_index,
    find_cache_dir as find_cache_dir,
    find_mp3_by_title as find_mp3_by_title,
    find_mp3_file as find_mp3_file,
    find_text_files as find_text_files,
    find_text_files_by_title as find_text_files_by_title,
    resolve_cache_dir_with_text as resolve_cache_dir_with_text,
)
from conversion_validation_chapter import BookValidationRun, validate_chapter
from conversion_validation_integrity import (
    _VALID_MP3_HEADERS as _VALID_MP3_HEADERS,
    _collect_chapter_wpms as _collect_wpms,
    _stem_needs_fixing as _stem_needs_fixing,
    _wpm_outlier_bounds as _wpm_outlier_bounds,
    detect_duplicate_audio_files as detect_duplicate_audio_files,
    fix_output_filenames as fix_output_filenames,
    hash_file as hash_file,
    verify_chapter_names as verify_chapter_names,
    verify_mp3_integrity as verify_mp3_integrity,
)
from conversion_validation_report import (
    print_book_report,
    print_chapter_detail as print_chapter_detail,
)
from conversion_validation_text import (
    HTML_ENTITY_PATTERN as HTML_ENTITY_PATTERN,
    HTML_TAG_PATTERN as HTML_TAG_PATTERN,
    _FILENAME_HASH_SUFFIX_RE as _FILENAME_HASH_SUFFIX_RE,
    _extract_samples as _extract_samples,
    _sample_edges as _sample_edges,
    _samples_match as _samples_match,
    _strip_hash_marker as _strip_hash_marker,
    _strip_numeric_prefix as _strip_numeric_prefix,
    _strip_text_suffix as _strip_text_suffix,
    _truncate_for_display as _truncate_for_display,
    compare_texts as compare_texts,
    contains_html_markup as contains_html_markup,
    hash_text as hash_text,
    normalize_text as normalize_text,
    normalize_title as normalize_title,
    normalize_title_key as normalize_title_key,
    normalized_file_title as normalized_file_title,
    normalized_leading_text as normalized_leading_text,
    strip_formatting_cues as strip_formatting_cues,
    titles_align as titles_align,
)
from python_app.src.audio_validator import AudioValidator
from python_app.src.config import ConversionConfig
from python_app.src.converter import AudioConverter
from python_app.src.ebook_reader import EbookReader
from python_app.src.utils import FileManager, resolve_cache_root


def _collect_chapter_wpms(epub_chapters, mp3_index, output_dir, text_dirs) -> List[float]:
    """Collect duration samples using the facade's replaceable audio validator."""
    if output_dir is None:
        return []
    return _collect_wpms(epub_chapters, mp3_index, output_dir, text_dirs, AudioValidator())


def load_epub_chapters(epub_path: Path) -> List[Tuple[object, str, str]]:
    """Load all chapters from EPUB matching what the converter actually iterates.

    Mirrors the converter's structure pipeline exactly: ``_generate_structure_items``
    + ``_apply_text_transforms``. The transforms include the duplicate-index
    sub-splitter (lines main.py:1485-1514) which assigns ``X.Y.Z`` labels to
    chapters that share an index — without this step the validator and
    converter disagree on the chapter count for hierarchical-TOC EPUBs.
    """
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
        result: List[Tuple[object, str, str]] = []
        for i, item in enumerate(structure_items, 1):
            label = getattr(item, "index", None) or i
            name = getattr(item, "display_name", None) or ""
            text = getattr(item, "text_override", None) or ""
            result.append((label, name, text))
        print(f"   ✅ Loaded {len(result)} chapters from EPUB")
        return result
    except Exception as exc:
        print(f"⚠️  Validation fallback: failed to use structure pipeline ({exc})")

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
    print("🔍 FULL EPUB → MP3 CONVERSION VALIDATION")
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

    # First pass: measure the actual WPM the engine produced on the
    # already-converted chapters in this book. Edge-TTS PT-BR neural
    # voices vary wildly — observed range during the Carl conversion
    # was 55-191 WPM depending on dialogue density and formatting cues —
    # so the static `chars/WPM=150` estimator triggers either false
    # positives (long chapter rejected for "+60% duration") or false
    # negatives (a 55-WPM chapter that's audibly bloated slips through
    # because the absolute tolerance window is wide enough to swallow
    # both). The median + MAD approach below flags only true outliers
    # against the rest of the book's distribution. See
    # `feedback_validate_book_median.md`.
    book_chapter_wpms = _collect_chapter_wpms(epub_chapters, mp3_index, output_dir, text_dirs)
    book_wpm_stats = _wpm_outlier_bounds(book_chapter_wpms)
    if book_wpm_stats and (output_dir is not None):
        median, low_bound, high_bound = book_wpm_stats
        print(
            f"📐 Median WPM across {len(book_chapter_wpms)} chapter(s): {median:.0f} "
            f"(outlier bounds: {low_bound:.0f}–{high_bound:.0f})"
        )

    print(
        f"{'Ch':<4} {'Status':<8} {'S/M/E':<7} {'%Text':<6} {'EPUB':<7} {'Parsed':<7} {'PreTTS':<7} {'MP3':<7} {'Issue'}"
    )
    print("-" * 90)

    run = BookValidationRun(
        output_dir=output_dir,
        text_dirs=text_dirs,
        cache_index=cache_index,
        mp3_index=mp3_index,
        validator=validator,
        duration_tolerance=duration_tolerance,
        book_wpm_stats=book_wpm_stats,
        stats=stats,
        issues=issues,
    )
    sequential_num = 0
    for chapter in epub_chapters:
        if not chapter[2] or not normalize_text(chapter[2]):
            continue
        sequential_num += 1
        validate_chapter(chapter, sequential_num, run)

    print_book_report(stats, issues, run.text_hashes, epub_chapters, output_dir)
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
        # Match "Chapter 9", "Chapter 1.1", etc.
        for match in re.finditer(r"\bChapter\s+(\d+(?:\.\d+)?)\b", issue):
            chapters.add(match.group(1))

        # Match duplicate audio: "between chapters: 9 and 43" or "1.1 and 1.2"
        dup_match = re.search(r"between chapters:\s*(\d+(?:\.\d+)?)\s+and\s+(\d+(?:\.\d+)?)", issue)
        if dup_match:
            chapters.add(dup_match.group(1))
            chapters.add(dup_match.group(2))

        # Match standalone numbers in missing-MP3 or duplicate messages
        if any(keyword in issue.lower() for keyword in ["missing mp3", "duplicate"]):
            for num_match in re.finditer(r"(?:^|\s)(\d+(?:\.\d+)?)(?:\s|:|$)", issue):
                num_str = num_match.group(1)
                try:
                    num_val = float(num_str)
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
