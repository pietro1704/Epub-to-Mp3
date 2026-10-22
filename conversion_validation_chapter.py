"""Validate one chapter against the conversion artifacts and shared book state."""

import os
from dataclasses import dataclass, field
from pathlib import Path

from conversion_validation_artifacts import (
    find_mp3_by_title,
    find_mp3_file,
    find_text_files,
    find_text_files_by_title,
)
from conversion_validation_integrity import hash_file
from conversion_validation_report import print_chapter_detail
from conversion_validation_text import (
    _sample_edges,
    _strip_numeric_prefix,
    compare_texts,
    contains_html_markup,
    hash_text,
    normalize_text,
    normalize_title_key,
    normalized_file_title,
    normalized_leading_text,
    strip_formatting_cues,
    titles_align,
)

from python_app.src.audio_validator import AudioValidator


@dataclass
class BookValidationRun:
    """Artifacts and cumulative findings shared by a single validation run."""

    output_dir: Path
    text_dirs: list[Path]
    cache_index: dict
    mp3_index: dict
    validator: AudioValidator
    duration_tolerance: float | None
    book_wpm_stats: tuple[float, float, float] | None
    stats: dict[str, int]
    issues: list[str]
    text_hashes: dict[str, list[object]] = field(default_factory=dict)
    chapter_text_hash: dict[object, str] = field(default_factory=dict)
    audio_hashes: dict[str, dict[str, object]] = field(default_factory=dict)


def validate_chapter(chapter, sequential_num, run: BookValidationRun):
    """Check and display one non-empty chapter, accumulating book findings."""
    chapter_label, chapter_title, epub_text = chapter
    output_dir = run.output_dir
    text_dirs = run.text_dirs
    cache_index = run.cache_index
    mp3_index = run.mp3_index
    validator = run.validator
    duration_tolerance = run.duration_tolerance
    book_wpm_stats = run.book_wpm_stats
    stats = run.stats
    issues = run.issues
    text_hashes = run.text_hashes
    chapter_text_hash = run.chapter_text_hash
    audio_hashes = run.audio_hashes
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

            # Skip start/end sample checks when the per-chapter diff is
            # already within the tolerance band (compare_texts returned
            # is_equal=True). Footnote rendering and structural cues can
            # legitimately shift the last 180 chars without dropping
            # audible content.
            if not is_equal:
                epub_start, epub_end = _sample_edges(epub_text)
                if epub_start and epub_start not in parsed_norm:
                    start_ok = False
                    if not parsed_mismatch_recorded:
                        stats["text_mismatch"] += 1
                        parsed_mismatch_recorded = True
                    status = "❌"
                    issue_desc = (issue_desc + " EPUB≠Parsed (start mismatch)").strip()
                    issues.append(
                        f"Chapter {chapter_num}: Parsed missing start sample from EPUB"
                    )
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
                duration_flag: tuple[bool, str] | None = None

                # Preferred path: use the book's own median WPM as the
                # anchor when we have ≥5 chapters to compare against.
                if book_wpm_stats is not None:
                    median_wpm, low_bound, high_bound = book_wpm_stats
                    word_count = len(normalize_text(pretts_text).split())
                    actual_duration = validator.get_audio_duration(mp3_file)
                    if word_count >= 50 and actual_duration and actual_duration > 0:
                        chapter_wpm = (word_count / actual_duration) * 60.0
                        if chapter_wpm < low_bound or chapter_wpm > high_bound:
                            deviation = ((chapter_wpm - median_wpm) / median_wpm) * 100
                            duration_flag = (
                                True,
                                f"Duration outlier ({chapter_wpm:.0f} WPM vs "
                                f"median {median_wpm:.0f}, {deviation:+.0f}%)",
                            )
                        else:
                            duration_flag = (False, "")

                # Fallback path (small books, missing data): use the
                # static chars/WPM heuristic with the v0.3.12 tolerance.
                if duration_flag is None:
                    if duration_tolerance is not None:
                        tolerance = duration_tolerance
                    else:
                        try:
                            env_tol = float(
                                os.getenv("VALIDATION_DURATION_TOLERANCE", "") or "0"
                            )
                        except (TypeError, ValueError):
                            env_tol = 0.0
                        if env_tol > 0:
                            tolerance = max(0.10, min(env_tol, 0.95))
                        else:
                            tolerance = 0.70 if pretts_len < 10000 else 0.60
                    legacy_result = validator.validate_duration(
                        pretts_text, mp3_file, tolerance=tolerance
                    )
                    duration_flag = (
                        not legacy_result.is_valid,
                        f"Duration mismatch ({legacy_result.duration_diff_percent:+.0f}%)"
                        if not legacy_result.is_valid
                        else "",
                    )

                is_outlier, message = duration_flag
                if is_outlier:
                    stats["duration_mismatch"] += 1
                    if status == "✅":
                        status = "⚠️ "
                    issue_desc = (issue_desc + f" {message}").strip()
                    issues.append(f"Chapter {chapter_num}: {message}")

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
